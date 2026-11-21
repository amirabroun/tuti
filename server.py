# /// script
# requires-python = ">=3.11"
# dependencies = ["transformers==5.18.0", "torch", "librosa", "numpy", "soxr", "websockets>=14"]
# ///
"""Tuti server: live Persian ASR over WebSocket, the Python side of the macOS app.

    uv run server.py          # loads the model (~10 s on MPS), then listens on ws://127.0.0.1:8765

Protocol v1 -- JSON text frames (real unicode), binary audio frames:
  app -> server   {"v":1,"type":"control","action":"start","sample_rate":48000}
                  optional "mode":"message" — the post-stop LLM pass rewrites the transcript
                  as one clean, flowing message (prompts/message.md: light summary + smooth
                  + reorder) instead of a plain clean (prompts/clean.md); absent = clean.
                  "mode":"memory" — the «حافظه» window's recorder («افزودن به حافظه»): NO
                  clean, NO intent; after asr_final the transcript merges straight into
                  MEMORY_PATH (clean_state off comes first; the app shows this recording's
                  state in the memory window's bar — no card in the main window at all).
                  Read once, at start.
                  binary: float32 mono PCM at that sample rate (resampled here)
                  {"v":1,"type":"control","action":"stop"}
                  {"v":1,"type":"retry","id":"<card uuid>","text":"<raw>","mode":"message"?}
                                                               a manual re-clean of an old
                                                               recording (the mode it was
                                                               recorded in; absent = clean)
  server -> app   {"v":1,"type":"asr_partial","text":"..."}   the whole raw transcript so far; the
                                                               LLM is never called mid-recording
                  {"v":1,"type":"clean_state","on":true}      the final clean started ("Editing...")
                                                               {"on":false} = nothing is coming: the
                                                               raw text is final (cleaning off, or
                                                               nothing was said)
                  {"v":1,"type":"clean_all","text":"..."}     the whole transcript, cleaned — once,
                                                               after stop. Only when .env is filled in.
                                                               optional "fallback":true = the LLM call
                                                               returned nothing; text is the raw
                                                               transcript (the app's HUD says so)
                  {"v":1,"type":"asr_final","text":"..."}     the whole raw recording, once, after
                                                               stop; a terminator, not a line
                  {"v":1,"type":"cleaned","id":"...","text":"..."}
                                                               the manual retry's result, for
                                                               that card id; optional
                                                               "fallback":true = it failed
                                                               again. No intent re-run.
                  {"v":1,"type":"usage","in":N,"out":N}      cumulative LLM tokens since the
                                                               server start, after every LLM call
                  {"v":1,"type":"config","model":"...","base_url":"...","clean":true}
                                                               the LLM config actually loaded
                                                               (never the key), sent once on
                                                               connect; clean false = raw text only
                  {"v":1,"type":"intent",...}                a voice command parsed off the FINAL
                                                               transcript: {"action":"reminder",
                                                               "title","when"} / {"action":"search",
                                                               "query"} / {"action":"open","url"}.
                                                               Sent only when cleaning is on and the
                                                               transcript IS a command; the app runs
                                                               it on a click, never automatically
                                                               (memory capture is manual: the app
                                                               records with mode "memory" instead)
                  {"v":1,"type":"memory_saved"}              that merge landed on disk — the app
                                                               shows a passive «حفظ شد» in the
                                                               recorder bar. Optional extra states:
                                                               "unchanged":true = the model judged
                                                               the file already covers it,
                                                               "failed":true = the merge failed
                  {"v":1,"type":"memory_chat","text":"<msg>",
                   "turns":[{"who":"me"|"ai","text":"..."}]}
                                                               the «حافظه» window's chat: recent
                                                               turns (oldest→newest) + a new
                                                               message → one LLM call; the model
                                                               may rewrite the memory file
                  {"v":1,"type":"memory_chat_result","text":"..."}
                                                               the chat's short reply; optional
                                                               "changed":true = the memory file
                                                               was rewritten on disk,
                                                               "failed":true = the call failed
                  {"v":1,"type":"error","message":"..."}
The socket only opens once the model is loaded, so "connected" means "ready".
Every memory interaction (record / chat) also appends ONE JSONL event — the raw
speech or message AND the AI's answer side by side, plus outcome and tokens — to
~/Library/Application Support/tuti/memory_log.jsonl (the usage-analysis record).
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
# the long-term memory the app keeps for Amir (the «حفظ شد» bar state points here)
MEMORY_PATH = os.path.expanduser("~/Documents/tuti-memory/memory.md")
MEMORY_LOCK = threading.Lock()  # one merge at a time: back-to-back memory-worthy recordings race otherwise
# the usage record: one JSONL event per memory interaction (raw speech/message + the AI's
# answer side by side) — what Amir will process later to see how his memory usage works
MEMORY_LOG = os.path.expanduser("~/Library/Application Support/tuti/memory_log.jsonl")
MLOG_LOCK = threading.Lock()
# cumulative LLM tokens since the server start (the menu-bar total); several worker
# threads (clean, memory merge, chat) report usage, so the += needs the lock
TOKENS = {"in": 0, "out": 0}
TOKENS_LOCK = threading.Lock()


def _add_tokens(emit, usage: tuple[int, int]) -> None:
    """Fold one call's usage into the server total and report the new totals to the app."""
    if usage == (0, 0):
        return
    with TOKENS_LOCK:
        TOKENS["in"] += usage[0]
        TOKENS["out"] += usage[1]
        totals = dict(TOKENS)
    emit("usage", "", totals)


def _mlog(kind: str, **fields) -> None:
    """Append one memory event to memory_log.jsonl. Failures land here too — the log is
    the analysis record, so an outcome is exactly what it must not swallow."""
    event = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "kind": kind, **fields}
    try:
        os.makedirs(os.path.dirname(MEMORY_LOG), exist_ok=True)
        with MLOG_LOCK:
            with open(MEMORY_LOG, "a") as f:
                f.write(json.dumps(event, ensure_ascii=False) + "\n")
    except OSError as e:
        print(f"memory log write failed: {e}", flush=True)


def _read_memory() -> str | None:
    """The current memory file; "" = absent (folder is made for the first write),
    None = unreadable — callers must NEVER write over a file they could not read."""
    if not os.path.exists(MEMORY_PATH):
        try:
            os.makedirs(os.path.dirname(MEMORY_PATH), exist_ok=True)
        except OSError as e:
            print(f"memory mkdir failed: {e}", flush=True)
            return None
        return ""
    try:
        with open(MEMORY_PATH) as f:
            return f.read()
    except OSError as e:
        print(f"memory read failed: {e}", flush=True)
        return None


def _write_memory(current: str, new_md: str) -> bool:
    """Atomically replace the memory file (tmp + os.replace); the previous version
    survives one bad merge day as .bak. Callers hold MEMORY_LOCK."""
    try:
        with open(MEMORY_PATH + ".tmp", "w") as f:
            f.write(new_md)
        if current:
            with open(MEMORY_PATH + ".bak", "w") as f:
                f.write(current)
        os.replace(MEMORY_PATH + ".tmp", MEMORY_PATH)
        return True
    except OSError as e:
        print(f"memory write failed: {e}", flush=True)
        return False

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
            self.emit(text)  # a plain text callback straight to the socket

    def end(self) -> None:
        pass  # LiveSession sends asr_final or error itself once generate() is done


class LiveSession:
    """One recording: audio chunks in, growing transcript out through emit(kind, text).

    Ported from LiveSession in nemotron-asr-streaming-farsi/scripts/gradio_app.py.
    emit is called from worker threads; it must be thread-safe.
    """

    def __init__(self, in_sr: int, emit, mode: str = "clean"):
        self.resampler = soxr.ResampleStream(in_sr, SR, 1, dtype="float32")
        self.mode = mode  # which post-stop LLM pass this recording gets (fixed at start)
        self.emit = emit
        self.buf = np.zeros(SR * 60, dtype=np.float32)
        self.n = 0
        self.eof = False
        self.closed = False  # set by finish(); a chunk can still arrive after stop
        self.feed_lock = threading.Lock()
        self.cond = threading.Condition()
        self.done = threading.Event()
        self.last_feed = time.monotonic()
        self.clean_q: queue.Queue = queue.Queue()  # the final transcript — one worker, off the model lock
        self.streamer = TranscriptStreamer(lambda text: self.emit("asr_partial", text))
        Thread(target=self._run, daemon=True).start()
        Thread(target=self._clean_worker, daemon=True).start()

    def _clean_worker(self) -> None:
        """Cleans the final transcript once, in a worker thread (the API call must not hold
        the model lock — the next recording starts while it is in flight). A None item ends
        the worker so the finished session (its ~4 MB buffer) is actually freed."""
        while True:
            text = self.clean_q.get()
            if text is None:
                return
            if self.mode == "memory":
                # the «حافظه» window's record button: no clean, no intent — the transcript
                # merges straight in. clean_state off comes FIRST so the card finishes with
                # its raw text (the app skips the clipboard write for memory cards) while
                # the merge runs; the «حفظ شد» chip lands when the file write succeeded.
                self.emit("clean_state", "off")
                self._remember(text)
                continue
            self.emit("clean_state", "on")
            cleaned, usage = llm_clean.message(text) if self.mode == "message" else llm_clean.clean(text)
            fallback = not cleaned
            if fallback:
                cleaned = text  # the clean failed: the raw transcript is the result
            self.emit("clean_all", cleaned, {"fallback": True} if fallback else None)
            self._count(usage)
            parsed, usage = llm_clean.intent(cleaned)
            self._count(usage)
            action = parsed.get("action") if parsed else None
            if parsed and action not in (None, "", "none"):
                self.emit("intent", "", parsed)

    def _remember(self, text: str) -> None:
        """A memory-mode recording's transcript: merge it into MEMORY_PATH (prompts/memory.md
        returns the whole rewritten file). The bar's «حفظ شد» goes out only AFTER the file
        is safely on disk; a failure or a no-change merge emits its own state instead —
        there is no card anymore to stay silently unchanged. The lock serializes merges:
        two memory recordings in a row would otherwise race on the same file and silently
        drop one merge."""
        with MEMORY_LOCK:
            current = _read_memory()
            if current is None:
                _mlog("record", raw=text, outcome="failed", tokens=[0, 0])
                self.emit("memory_saved", "", {"failed": True})
                return
            merged, usage = llm_clean.memory(current, text)
            self._count(usage)
            if not merged:  # failed: the file stays exactly as it was
                outcome = "failed"
            elif merged == current:  # the model judged the file already covers it
                outcome = "unchanged"
            elif _write_memory(current, merged):
                outcome = "saved"
            else:
                outcome = "failed"
        _mlog("record", raw=text, outcome=outcome, tokens=list(usage))
        if outcome == "saved":
            self.emit("memory_saved", "")
        elif outcome == "unchanged":
            self.emit("memory_saved", "", {"unchanged": True})
        else:
            self.emit("memory_saved", "", {"failed": True})

    def _count(self, usage: tuple[int, int]) -> None:
        _add_tokens(self.emit, usage)  # the total lives at module level, not per session

    def _finish_recording(self) -> None:
        """After stop: clean the whole transcript once, or close the recording without a request."""
        text = self.streamer.text.strip()
        if text and llm_clean.configured():
            self.clean_q.put(text)
        else:
            self.emit("clean_state", "off")  # nothing is coming: the app saves the raw text
            if self.mode == "memory" and text:
                # speech happened but no merge can run (LLM off): the bar must not
                # wait on «در حال ذخیره…» forever — say it failed (nothing was written)
                self.emit("memory_saved", "", {"failed": True})

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
                self.clean_q.put(None)  # the sentinel is last: queued cleans land before it


async def _sender(ws, queue: asyncio.Queue) -> None:
    while True:
        kind, text, extra = await queue.get()
        msg = {"v": 1, "type": kind}
        if kind == "error":
            msg["message"] = text
        elif kind == "clean_state":
            msg["on"] = text == "on"
        elif kind in ("usage", "intent", "config", "memory_saved"):
            pass  # every field lives in extra
        else:
            msg["text"] = text
        msg.update(extra or {})
        await ws.send(json.dumps(msg, ensure_ascii=False))


def _re_clean(emit, m: dict) -> None:
    """A manual retry from the app: the one LLM pass re-run on an old recording's raw text,
    in a thread (the asyncio loop must not wait on the API). No intent re-run — that chip
    is long gone by the time a retry is clicked."""
    text = m.get("text", "")
    cleaned, usage = (llm_clean.message(text) if m.get("mode") == "message"
                      else llm_clean.clean(text))
    extra = {"id": m.get("id", "")}
    if not cleaned:
        cleaned, extra["fallback"] = text, True
    emit("cleaned", cleaned, extra)
    _add_tokens(emit, usage)


def _memory_chat(emit, m: dict) -> None:
    """The «حافظه» window's chat (prompts/chat.md): the file + the recent turns + a new
    message → a short answer; a rewritten file lands on disk like a merge. In a thread;
    the MEMORY_LOCK is held across the LLM call — a merge that lands mid-chat must not
    be overwritten by a rewrite built from a stale read (a merge started meanwhile just
    waits a few seconds for the lock)."""
    turns = [t for t in m.get("turns", []) if isinstance(t, dict)]
    text = m.get("text", "")
    with MEMORY_LOCK:
        current = _read_memory()
        if current is None:
            _mlog("chat", text=text, reply=None, changed=False, failed=True,
                  nturns=len(turns), tokens=[0, 0])
            emit("memory_chat_result", "", {"failed": True})
            return
        reply, new_file, usage = llm_clean.chat(current, turns, text)
        changed = bool(new_file) and new_file != current and _write_memory(current, new_file)
    _add_tokens(emit, usage)
    # the analysis record: his raw message + the AI's answer side by side, every outcome
    _mlog("chat", text=text, reply=reply, changed=changed, failed=not reply,
          nturns=len(turns), tokens=list(usage))
    if not reply:
        emit("memory_chat_result", "", {"failed": True})
    else:
        emit("memory_chat_result", reply, {"changed": True} if changed else None)


async def handler(ws) -> None:
    global ACTIVE
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def emit(kind: str, text: str, extra: dict | None = None) -> None:
        loop.call_soon_threadsafe(queue.put_nowait, (kind, text, extra))

    sender = asyncio.create_task(_sender(ws, queue))
    # what the app's Settings panel shows: the LLM config actually loaded — never the key
    queue.put_nowait(("config", "", {
        "model": os.environ.get("TUTI_LLM_MODEL", ""),
        "base_url": os.environ.get("TUTI_LLM_BASE_URL", ""),
        "clean": llm_clean.configured(),
    }))
    session = None
    try:
        async for msg in ws:
            if isinstance(msg, bytes):
                if session is not None:
                    session.feed(np.frombuffer(msg, dtype=np.float32))
                continue
            m = json.loads(msg)
            if m.get("type") == "retry":
                Thread(target=_re_clean, args=(emit, m), daemon=True).start()
                continue
            if m.get("type") == "memory_chat":
                Thread(target=_memory_chat, args=(emit, m), daemon=True).start()
                continue
            if m.get("type") != "control":
                continue
            if m.get("action") == "start":
                if ACTIVE is not None and not ACTIVE.done.is_set():
                    queue.put_nowait(("error", "another recording is still running or finishing; try again in a moment", None))
                    continue
                session = ACTIVE = LiveSession(int(m.get("sample_rate", SR)), emit,
                                               mode=m.get("mode", "clean"))
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
    # fp16 halves the 2.3 GB fp32 weights (~3.5 GB -> ~2 GB RSS); ASR accuracy is unchanged
    MODEL = AutoModelForRNNT.from_pretrained(a.model, dtype=torch.float16).to(device).eval()
    asyncio.run(_serve(a.port))


if __name__ == "__main__":
    main()
