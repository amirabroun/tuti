# /// script
# requires-python = ">=3.11"
# dependencies = ["transformers==5.18.0", "torch", "librosa", "numpy", "soxr", "websockets>=14"]
# ///
"""Regression check for server.py: when the model fails mid-recording, the app must still get
an error message instead of hanging on "Finishing…".

    uv run test_error_path.py    # exit 0 = exactly one error event within 10 s

Runs in-process with the real processor and a fake model that fails after one audio chunk:
no server, no model weights. The dependency list matches server.py because it imports it.
"""

import sys
import threading

import numpy as np
import torch
from transformers import AutoProcessor

import server


class FailingModel:
    """Takes one audio chunk like a real decode step, then fails the way a real generate() can."""

    device = torch.device("cpu")
    dtype = torch.float32

    def generate(self, input_features, streamer, **kwargs):
        next(iter(input_features))
        raise RuntimeError("simulated failure mid-decode")


def main() -> int:
    server.PROCESSOR = AutoProcessor.from_pretrained(server.DEFAULT_MODEL)
    server.MODEL = FailingModel()
    events, terminal = [], threading.Event()

    def emit(kind: str, text: str) -> None:
        events.append((kind, text))
        if kind in ("asr_final", "error"):
            terminal.set()

    session = server.LiveSession(server.SR, emit)
    session.feed(np.zeros(server.SR * 2, np.float32))
    session.finish()
    terminal.wait(timeout=10)
    print("events:", events)
    ok = events == [("error", "transcription failed: simulated failure mid-decode")]
    print("PASS" if ok else "FAIL (no error event: the app would hang on 'Finishing…')")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
