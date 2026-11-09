# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "websockets>=14"]
# ///
"""Delta-cleaning check: a mock LLM records every request the server makes.

    # terminal 1 — the server must point at the mock:
    TUTI_LLM_BASE_URL=http://127.0.0.1:8899/v1 TUTI_LLM_MODEL=mock TUTI_LLM_API_KEY=x \
      uv run --offline server.py --port 8766
    # terminal 2:
    URI=ws://127.0.0.1:8766 uv run test_cut_request.py

Starts a fake OpenAI-style API on :8899 that answers "MOCKn" and records request bodies,
then drives one recording over the socket. Pins the stage-2 promise: cleaned text is never
sent again (only the new speech, with the cleaned text as context).
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
    clean_alls: list[tuple[bool, str]] = []

    async with websockets.connect(URI) as ws:
        async def read() -> None:
            async for msg in ws:
                m = json.loads(msg)
                if m["type"] == "clean_all":
                    clean_alls.append((m.get("final", False), m["text"]))

        reader = asyncio.create_task(read())
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "start", "sample_rate": RATE}))
        await stream(ws, first)
        await asyncio.sleep(0.2)
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "cut"}))
        await asyncio.sleep(1.0)
        await stream(ws, second)
        await asyncio.sleep(0.5)
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "cut"}))
        await asyncio.sleep(1.0)
        await ws.send(json.dumps({"v": 1, "type": "control", "action": "stop"}))
        await asyncio.sleep(3)
        reader.cancel()

    texts = [r["text"] for r in requests_seen]

    def user_texts(r: dict) -> list[str]:
        return [m["content"] for m in r["messages"] if m["role"] == "user"]

    print(f"api requests: {len(texts)}")
    for i, t in enumerate(texts):
        print(f"  req {i}: {t!r}")
    for f, t in clean_alls:
        print(f"clean_all{' (final)' if f else ''}: {t!r}")

    def fail(msg: str) -> int:
        print("FAIL:", msg)
        return 1

    if len(texts) < 2:
        return fail("expected at least 2 API requests (two deltas)")
    # a cut can land mid-word on the ASR timeline ("تستینگ" -> "تست" + "ینگ"): timing, not a bug
    if "تست" not in texts[0]:
        return fail("request 0 should carry the first speech")
    # a delta request carries the locked text as a context user message; its own text is only
    # the NEW speech — the locked text must never be sent again as the text to clean
    with_ctx = [r for r in requests_seen if len(user_texts(r)) > 1]
    if any("تستینگ" in r["text"] for r in with_ctx):
        return fail("cleaned text was sent again as a delta")
    if not with_ctx or "MOCK1" not in user_texts(with_ctx[0])[0]:
        return fail("second delta should carry the cleaned text as context")
    # display text only grows by appending
    plain = [t for _, t in clean_alls]
    for a, b in zip(plain, plain[1:]):
        if not (b.startswith(a) or "MOCK" in b and b.count("MOCK") <= a.count("MOCK") + 1):
            return fail(f"cleaned text not kept/appended: {a!r} -> {b!r}")
    if not any(f for f, _ in clean_alls):
        return fail("no final clean_all after stop")
    # the intent pass fires once after the final clean, on the full transcript, no context
    final_text = [t for f, t in clean_alls if f][-1]
    if texts[-1] != f"<t>{final_text}</t>":
        return fail("the intent pass should send the whole final transcript once")
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
