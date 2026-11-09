# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "websockets>=14"]
# ///
"""Smoke test for server.py: stream 48 kHz audio over the socket the way the Swift app does.

    uv run server.py &          # wait for "tuti server ready"
    uv run test_ws_client.py    # exit 0 = partials, cut segments and a final transcript line up

The audio is English from macOS `say` (it has no Persian voice), so the text is Persian-ish
nonsense; this checks the pipe, not accuracy.
"""

import asyncio
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import websockets

URI = os.environ.get("URI", "ws://127.0.0.1:8765")
RATE = 48000  # a typical Mac mic rate; exercises the server's resampler
CHUNK = RATE // 10  # 100 ms per frame


def make_audio(text: str) -> np.ndarray:
    with tempfile.TemporaryDirectory() as d:
        aiff = f"{d}/t.aiff"
        subprocess.run(["say", "-o", aiff, text], check=True)
        raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", aiff, "-ac", "1", "-ar", str(RATE),
                              "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


async def stream(ws, audio: np.ndarray) -> None:
    for i in range(0, len(audio), CHUNK):
        await ws.send(audio[i:i + CHUNK].tobytes())
        await asyncio.sleep(0.03)


async def main() -> int:
    first = make_audio("Hello, this is a test of the live streaming pipeline.")
    second = make_audio("Another sentence follows the pause here.")
    async with websockets.connect(URI) as ws:
        partials, partials_after_cut, errors, clean_alls, clean_fails, final = [], [], [], [], [], None
        sent_cut = [False]  # mutable so read() sees when the first cut went out
        clean_started = [False]

        async def read() -> None:
            nonlocal final
            async for msg in ws:
                m = json.loads(msg)
                t = m["type"]
                if t == "asr_partial":
                    (partials_after_cut if sent_cut[0] else partials).append(m["text"])
                elif t == "clean_all":
                    clean_alls.append((m.get("final", False), m["text"]))
                elif t == "clean_state":
                    if m.get("on"):
                        clean_started[0] = True
                    elif clean_started[0]:
                        clean_fails.append(True)  # a clean started and failed; the raw text stays
                elif t == "error":
                    errors.append(m["message"])
                elif t == "asr_final":
                    final = m["text"]  # keep reading: the final clean arrives after it

        reader = asyncio.create_task(read())
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "start", "sample_rate": RATE}))
        # a second start while recording must be refused
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "start", "sample_rate": RATE}))
        await stream(ws, first)
        await asyncio.sleep(0.2)
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "cut"}))  # speech pause
        sent_cut[0] = True
        await stream(ws, second)
        await asyncio.sleep(0.5)  # let the decode settle so the whole tail is in the text
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "cut"}))
        await asyncio.sleep(0.05)
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "cut"}))  # nothing new: no new request work
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "stop"}))
        await ws.send(first[:CHUNK].tobytes())  # a late chunk after stop must be dropped
        after_final = 0.0
        while True:  # wait for the final; then for its clean (or the failure), unless cleaning is off
            done = final is not None and (any(f for f, _ in clean_alls) or clean_fails
                                          or (after_final > 1.0 and not clean_started[0]))
            if done or after_final > 12:
                break
            if final is not None:
                after_final += 0.1
            await asyncio.sleep(0.1)
        reader.cancel()

    print(f"audio: {(len(first) + len(second)) / RATE:.1f} s at {RATE} Hz")
    print(f"partials: {len(partials)} before the cuts, {len(partials_after_cut)} after")
    for p in partials[-2:] + partials_after_cut[-2:]:
        print("  ...", p)
    for f, t in clean_alls:
        print(f"clean_all{' (final)' if f else ''}: {t}")
    if clean_fails:
        print(f"clean failures: {len(clean_fails)}")
    print("final:", final)
    print("errors:", errors)
    frozen = max(partials, key=len, default="")  # the full first sentence, before the cut
    ok = (bool(partials) and bool(partials_after_cut) and bool(final)
          and all(frozen not in p for p in partials_after_cut if p)  # tails only: no frozen text back
          and (not clean_started[0] or any(f for f, _ in clean_alls) or clean_fails)
          and not (clean_alls and clean_fails)  # a configured key either works or fails, not both
          and errors == ["another recording is still running or finishing; try again in a moment"])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
