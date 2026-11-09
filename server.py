# /// script
# requires-python = ">=3.11"
# dependencies = ["transformers==5.18.0", "torch", "librosa", "numpy", "soxr", "websockets>=14"]
# ///
"""Tuti server: live Persian ASR over WebSocket, the Python side of the macOS app.

    uv run server.py          # loads the model (~10 s on MPS), then listens on ws://127.0.0.1:8765

Protocol v1 -- JSON text frames (real unicode), binary audio frames:
  app -> server   {"v":1,"type":"control","action":"start","sample_rate":48000,"style":"spoken"}
                  binary: float32 mono PCM at that sample rate (resampled here)
                  {"v":1,"type":"control","action":"cut"}    a speech pause: clean the new speech now
                  {"v":1,"type":"control","action":"reclean"}  the Re-clean button: one request for the
                                                                   WHOLE raw transcript; replaces the text
                  {"v":1,"type":"control","action":"stop"}
  server -> app   {"v":1,"type":"asr_partial","text":"..."}   raw text since the last cut (the tail)
                  {"v":1,"type":"clean_state","on":true}      a whole-text clean started ("Editing...")
                                                               {"on":false} = it failed; raw text stays
                  {"v":1,"type":"clean_all","text":"...","final":bool}
                                                               the WHOLE transcript, cleaned — replaces
                                                               all text in the app; "final":true on the
                                                               one sent after stop. Only when .env is
                                                               filled in.
                  {"v":1,"type":"asr_final","text":"..."}     the whole raw recording, once, after
                                                               stop; a terminator, not a line
                  {"v":1,"type":"error","message":"..."}
Reserved for later stages: agent_reply, tool_request, tool_result.
The socket only opens once the model is loaded, so "connected" means "ready".
Connections that send an Origin header (web pages in a browser) are refused with HTTP 403.
"""

import argparse
import asyncio
import json
import os
import queue
import threading
import time
import warnings
from threading import Thread

warnings.filterwarnings("ignore", message=".*max_length.*")  # generate's length warning; RNN-T stops by itself

import numpy as np
import soxr
import torch
from transformers import AutoModelForRNNT, AutoProcessor
from transformers.generation.streamers import BaseStreamer
from websockets.asyncio.server import serve

import llm_clean

SR = 16000
DEFAULT_MODEL = "mehdi-hf/nemotron-asr-streaming-farsi"
LOOKAHEAD_TOKENS = 13  # 1.1 s of right context: the ASR repo's most accurate setting
IDLE_TIMEOUT = 10.0  # s without audio before a recording is closed (app killed mid-recording)

MODEL = PROCESSOR = None
MODEL_LOCK = threading.Lock()  # one transcription at a time (shared model and processor settings)
ACTIVE = None  # the LiveSession holding the model, across all connections


class TranscriptStreamer(BaseStreamer):
    """Gets token ids from generate() and sends the whole transcript every time it changes.

    transformers' TextIteratorStreamer only lets text out up to the last space, so a word spoken
    right before a pause stayed hidden until the next word began or the recording stopped. A word
    still being decoded now grows in place ("تس" -> "تستینگ"): each asr_partial replaces the last.
    """

    def __init__(self, emit):
        self.emit = emit
        self.ids: list[int] = []
        self.text = ""

    def put(self, value) -> None:
        # (1, n) ids for the prompt, (1,) per decoding step; blanks (most steps) carry no text, so a
        # recording left running in silence doesn't make every re-decode longer
        self.ids += [i for i in value.reshape(-1).tolist() if i != MODEL.config.blank_token_id]
        # group_tokens=False: the tokenizer's decode merges repeated tokens by default (a CTC rule).
        text = PROCESSOR.tokenizer.decode(self.ids, skip_special_tokens=True, group_tokens=False)
        if text != self.text:  # most steps are blanks: nothing new to send
            self.text = text
            self.emit(text)  # a plain text callback: LiveSession._emit_partial slices the tail

    def end(self) -> None:
        pass  # LiveSession sends asr_final or error itself once generate() is done


class LiveSession:
    """One recording: audio chunks in, growing transcript out through emit(kind, text).

    Ported from LiveSession in nemotron-asr-streaming-farsi/scripts/gradio_app.py.
    emit is called from worker threads; it must be thread-safe.
    """

    def __init__(self, in_sr: int, emit, style: str = "spoken"):
        self.resampler = soxr.ResampleStream(in_sr, SR, 1, dtype="float32")
        self.emit = emit
        self.buf = np.zeros(SR * 60, dtype=np.float32)
        self.n = 0
        self.eof = False
        self.closed = False  # set by finish(); a chunk can still arrive after stop
        self.feed_lock = threading.Lock()
        self.cond = threading.Condition()
        self.done = threading.Event()
        self.last_feed = time.monotonic()
        self.cut_at = 0  # code-point offset into the full text: where the display tail starts
        self.style = style
        self.cleaned = ""  # text already cleaned and locked; only the tail after cut_at goes to the LLM again
        self.clean_q: queue.Queue = queue.Queue()  # ("delta"|"whole", text, final) — one worker, in order
        self.streamer = TranscriptStreamer(self._emit_partial)
        Thread(target=self._run, daemon=True).start()
        Thread(target=self._clean_worker, daemon=True).start()

    def _emit_partial(self, text: str) -> None:
        # after a cut the app shows only the new tail; everything before it lives in clean_all
        self.emit("asr_partial", text[self.cut_at:])

    def cut(self) -> None:
        """A speech pause: the new speech goes for cleaning; the recording continues."""
        if self.closed:
            return
        self._queue_delta(final=False)

    def _queue_delta(self, final: bool) -> None:
        """Freeze the speech since the last cut as the next cleaning item."""
        text = self.streamer.text
        delta = text[self.cut_at:].strip()
        if len(text) > self.cut_at:
            self.cut_at = len(text)
            if not final:
                self.emit("asr_partial", "")  # the display tail empties until speech resumes
        if delta and llm_clean.configured():
            self.clean_q.put(("delta", delta, final))

    def reclean(self) -> None:
        """One request for the WHOLE raw transcript, replacing all cleaned text (the Re-clean button)."""
        text = self.streamer.text.strip()
        if text and llm_clean.configured():
            self.clean_q.put(("whole", text, False))

    def _clean_worker(self) -> None:
        """Cleans queued items one at a time, in order: every delta is cleaned with the locked
        text before it as context and appended to it; nothing is ever sent twice."""
        while True:
            kind, text, final = self.clean_q.get()
            self.emit("clean_state", "on")
            if kind == "delta":
                cleaned = llm_clean.clean(text, context=self.cleaned or None, style=self.style)
            else:
                cleaned = llm_clean.clean(text, style=self.style)
            if not cleaned:
                cleaned = text  # the clean failed: this part is locked as raw instead of lost
            self.cleaned = (self.cleaned + " " + cleaned).strip() if kind == "delta" else cleaned
            self.emit("clean_all", self.cleaned, {"final": True} if final else None)

    def _finish_recording(self) -> None:
        """After stop: clean what's left, or close the recording without a new request."""
        if not llm_clean.configured():
            self.emit("clean_state", "off")  # nothing is coming: the app saves the raw text
        elif self.streamer.text[self.cut_at:].strip():
            self._queue_delta(final=True)
        elif self.cleaned:
            self.emit("clean_all", self.cleaned, {"final": True})  # nothing new: lock what we have
        # else: an empty recording — no history entry

    def _append(self, x: np.ndarray) -> None:
        with self.cond:
            while self.n + len(x) > len(self.buf):
                self.buf = np.concatenate([self.buf, np.zeros_like(self.buf)])
            self.buf[self.n:self.n + len(x)] = x
            self.n += len(x)
            self.cond.notify_all()

    def _get(self, start: int, end: int):
        """Samples [start, end); waits for them. None once the session has ended. A recording
        whose app stops sending audio without a stop is closed after IDLE_TIMEOUT s, so it
        can't hold the model forever."""
        while True:
            with self.cond:
                if self.n >= end:
                    return self.buf[start:end].copy()
                if self.eof:
                    return None
                self.cond.wait(timeout=1.0)
                idle = time.monotonic() - self.last_feed > IDLE_TIMEOUT
            if idle:
                print(f"no audio for {IDLE_TIMEOUT:.0f} s; closing the recording", flush=True)
                self.finish()

    def feed(self, chunk: np.ndarray) -> None:
        with self.feed_lock:
            if self.closed:
                return  # the resampler was already flushed; drop the late chunk
            self.last_feed = time.monotonic()
            self._append(self.resampler.resample_chunk(chunk))

    def finish(self) -> None:
        with self.feed_lock:
            if self.closed:
                return
            self.closed = True
            self._append(self.resampler.resample_chunk(np.zeros(0, np.float32), last=True))
        # two chunks of silence: the model holds back the look-ahead frames of each chunk
        self._append(np.zeros(2 * PROCESSOR.num_samples_per_audio_chunk, np.float32))
        with self.cond:
            self.eof = True
            self.cond.notify_all()

    def _run(self) -> None:
        p, m = PROCESSOR, MODEL
        error = ""
        with MODEL_LOCK:
            try:
                p.set_num_lookahead_tokens(LOOKAHEAD_TOKENS)
                first_audio = self._get(0, p.num_samples_first_audio_chunk)
                if first_audio is None:
                    return
                first = p(first_audio, sampling_rate=SR, is_streaming=True, is_first_audio_chunk=True,
                          language="fa-IR", return_tensors="pt").to(m.device, dtype=m.dtype)

                def chunks():
                    yield first.input_features[:, : p.num_mel_frames_first_audio_chunk, :]
                    mel = p.num_mel_frames_first_audio_chunk
                    hop, n_fft = p.feature_extractor.hop_length, p.feature_extractor.n_fft
                    start = mel * hop - n_fft // 2
                    while (x := self._get(start, start + p.num_samples_per_audio_chunk)) is not None:
                        yield p(x, sampling_rate=SR, is_streaming=True, is_first_audio_chunk=False,
                                language="fa-IR", return_tensors="pt").to(m.device, dtype=m.dtype).input_features
                        mel += p.num_mel_frames_per_audio_chunk
                        start = mel * hop - n_fft // 2

                m.generate(**{**first, "input_features": chunks()}, streamer=self.streamer)
            except Exception as e:  # reported to the app as an error message
                error = str(e) or type(e).__name__
            finally:
                if error:
                    self.emit("error", f"transcription failed: {error}")
                else:
                    self.emit("asr_final", self.streamer.text)
                    self._finish_recording()
                self.done.set()


async def _sender(ws, queue: asyncio.Queue) -> None:
    while True:
        kind, text, extra = await queue.get()
        msg = {"v": 1, "type": kind}
        if kind == "error":
            msg["message"] = text
        elif kind == "clean_state":
            msg["on"] = text == "on"
        else:
            msg["text"] = text
        msg.update(extra or {})
        await ws.send(json.dumps(msg, ensure_ascii=False))


async def handler(ws) -> None:
    global ACTIVE
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def emit(kind: str, text: str, extra: dict | None = None) -> None:
        loop.call_soon_threadsafe(queue.put_nowait, (kind, text, extra))

    sender = asyncio.create_task(_sender(ws, queue))
    session = None
    try:
        async for msg in ws:
            if isinstance(msg, bytes):
                if session is not None:
                    session.feed(np.frombuffer(msg, dtype=np.float32))
                continue
            m = json.loads(msg)
            if m.get("type") != "control":
                continue
            if m.get("action") == "start":
                if ACTIVE is not None and not ACTIVE.done.is_set():
                    queue.put_nowait(("error", "another recording is still running or finishing; try again in a moment", None))
                    continue
                session = ACTIVE = LiveSession(int(m.get("sample_rate", SR)), emit,
                                                "formal" if m.get("style") == "formal" else "spoken")
            elif m.get("action") == "cut" and session is not None:
                session.cut()
            elif m.get("action") == "reclean" and session is not None:
                session.reclean()
            elif m.get("action") == "stop" and session is not None:
                session.finish()
    finally:
        if session is not None:
            session.finish()  # the app went away mid-recording: release the model
        sender.cancel()


def pick_device(name: str) -> str:
    if name != "auto":
        return name
    return "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"


def _exit_with_parent(pid: int) -> None:
    """The app can die without stopping us (force quit, Xcode's Stop button); don't outlive it holding the port."""
    while True:
        time.sleep(2)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            print("tuti app is gone; exiting", flush=True)
            os._exit(0)


async def _serve(port: int) -> None:
    # browsers always send Origin; refusing it keeps web pages from driving the server (cross-site WebSocket hijacking)
    async with serve(handler, "127.0.0.1", port, origins=[None]):
        print(f"tuti server ready: ws://127.0.0.1:{port}", flush=True)
        await asyncio.get_running_loop().create_future()  # run until killed


def main() -> None:
    global MODEL, PROCESSOR
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default=DEFAULT_MODEL, help="Hugging Face repo id or local directory")
    ap.add_argument("--device", default="auto", help="auto, cpu, mps or cuda")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--parent-pid", type=int, help="exit once this process (the app that launched us) is gone")
    a = ap.parse_args()
    llm_clean.load_env()
    print(f"llm cleanup: {'on' if llm_clean.configured() else 'off (empty .env)'}", flush=True)
    if a.parent_pid:
        Thread(target=_exit_with_parent, args=(a.parent_pid,), daemon=True).start()

    from transformers.utils import logging as hf_logging

    hf_logging.set_verbosity_error()
    device = pick_device(a.device)
    print(f"Loading {a.model} ({device})...", flush=True)
    PROCESSOR = AutoProcessor.from_pretrained(a.model)
    MODEL = AutoModelForRNNT.from_pretrained(a.model).to(device).eval()
    asyncio.run(_serve(a.port))


if __name__ == "__main__":
    main()
