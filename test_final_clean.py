# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "websockets>=14"]
# ///
"""Final-clean check: a mock LLM records every request the server makes.

    # terminal 1 — the server must point at the mock:
    TUTI_LLM_BASE_URL=http://127.0.0.1:8899/v1 TUTI_LLM_MODEL=mock TUTI_LLM_API_KEY=x \
      uv run --offline server.py --port 8766
    # terminal 2:
    URI=ws://127.0.0.1:8766 uv run test_final_clean.py

Starts a fake OpenAI-style API on :8899 that answers "MOCKn" and records request bodies,
then drives one recording over the socket. Pins the stage-4 promise: no LLM call before
stop, even across a speech pause; after stop exactly one clean of the whole raw transcript
(no context message), then one intent pass on its result.
"""

import asyncio
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import websockets

from test_ws_client import make_audio, stream, RATE

URI = os.environ.get("URI", "ws://127.0.0.1:8765")
requests_seen: list[dict] = []  # one {"messages": [...], "text": last user content} per API call
counter = [0]


class Mock(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        counter[0] += 1
        requests_seen.append({"messages": body["messages"],
                              "text": body["messages"][-1]["content"]})
        out = json.dumps({"choices": [{"message": {"content": f"MOCK{counter[0]}"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args) -> None:
        pass


async def main() -> int:
    first = make_audio("Hello, this is a test of the live streaming pipeline.")
    second = make_audio("Another sentence follows the pause here.")
    clean_alls: list[str] = []
    final = None

    async with websockets.connect(URI) as ws:
        async def read() -> None:
            nonlocal final
            async for msg in ws:
                m = json.loads(msg)
                if m["type"] == "clean_all":
                    clean_alls.append(m["text"])
                elif m["type"] == "asr_final":
                    final = m["text"]

        reader = asyncio.create_task(read())
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "start", "sample_rate": RATE}))
        await stream(ws, first)
        await asyncio.sleep(0.8)  # a pause long enough that stage 2 would have cut here
        await stream(ws, second)
        await asyncio.sleep(0.5)  # let the decode settle so the whole text is in
        mid_calls = len(requests_seen)
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "stop"}))
        for _ in range(100):  # the final clean + intent arrive after asr_final
            if final is not None and len(requests_seen) >= 2 and clean_alls:
                break
            await asyncio.sleep(0.1)
        reader.cancel()

    texts = [r["text"] for r in requests_seen]

    def user_texts(r: dict) -> list[str]:
        return [m["content"] for m in r["messages"] if m["role"] == "user"]

    print(f"api requests: {len(texts)}  (before stop: {mid_calls})")
    for i, t in enumerate(texts):
        print(f"  req {i}: {t!r}")
    for t in clean_alls:
        print(f"clean_all: {t!r}")

    def fail(msg: str) -> int:
        print("FAIL:", msg)
        return 1

    if mid_calls != 0:
        return fail("no LLM call may happen before stop, even across a pause")
    if len(texts) != 2:
        return fail("expected exactly 2 API requests after stop (clean + intent)")
    if not final:
        return fail("no asr_final arrived")
    if texts[0] != f"<t>{final}</t>":
        return fail("the clean should send the whole raw transcript, once")
    if len(user_texts(requests_seen[0])) != 1:
        return fail("the clean carries no context message anymore")
    if clean_alls != ["MOCK1"]:
        return fail(f"expected exactly one clean_all == MOCK1, got {clean_alls}")
    if texts[1] != "<t>MOCK1</t>":
        return fail("the intent pass should run once, on the cleaned transcript")
    print("PASS")
    return 0


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8899), Mock)
    import threading
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        sys.exit(asyncio.run(main()))
    finally:
        server.shutdown()
