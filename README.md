# tuti

Speak Persian on your Mac, see the text live. Stage 1 of a voice agent: the macOS app (Swift)
streams the microphone to a local Python server running
[mehdi-hf/nemotron-asr-streaming-farsi](https://huggingface.co/mehdi-hf/nemotron-asr-streaming-farsi)
and shows the transcript as you talk.

## Run the app

    brew install xcodegen          # once
    xcodegen generate
    xcodebuild -project tuti.xcodeproj -scheme tuti -configuration Debug -derivedDataPath build build
    open build/Build/Products/Debug/tuti.app

The app starts `uv run server.py` itself — offline, from the local caches — waits for the model,
then shows **Ready**. On a new machine, or after clearing the uv or Hugging Face caches, run
`uv run server.py` once by hand to download.

Press **Record** (or Space), speak, press **Stop** (or Space) — or just go quiet and let
Auto-stop end it. The window is a list of cards, one per recording (past ones load from history):
click a card to copy it; every clean also lands on the clipboard. The server log appends to
`~/Library/Logs/tuti/server.log`.

Paths (repo, `uv`) are hard-coded in `Config` in `swift/App.swift` for now.

## Server only

    uv run server.py            # ws://127.0.0.1:8765
    uv run test_ws_client.py    # smoke test: streams 48 kHz audio, expects partials + a final
    uv run test_error_path.py   # a model failure mid-recording still ends with an error (no server needed)

Protocol: the docstring at the top of `server.py`. Plan: `docs/plans/2026-11-08-stage1.md`.

## Stage 2 — live LLM cleanup (`.env`)

Fill `.env` (gitignored) with an LLM API — `TUTI_LLM_BASE_URL`, `TUTI_LLM_MODEL`,
`TUTI_LLM_API_KEY`; any OpenAI-compatible `/chat/completions` endpoint, or an Anthropic
endpoint (Z.ai keys are Anthropic-only: `https://api.z.ai/api/anthropic`). Then, while you
record: go quiet for ~3 s and the **new speech** goes for cleaning with the already-cleaned
text as context — the cleaned result is appended to the locked text, so nothing is ever
sent (or paid for) twice. Stop cleans the remainder and finalizes the history entry.
English words spoken in English come back in English (دیپلوی ← deploy); loanwords that
are normal Persian (فایل، سرور) stay Persian. The **Re-clean** button sends the whole raw
transcript as one request and replaces everything. While a clean is in flight the active card
shows a progress bar (`در حال ویرایش…`); if the API fails, that part is locked as raw text and
the recording is unaffected. Empty `.env` = cleanup off, raw text as before. The system prompt
lives in `prompts/clean.md`.

**Auto-stop** (checkbox, on by default): ~4 s without new text ends the recording by itself
(the 3 s pause before it already sent the new speech for cleaning).

**History** button: one entry per recording (raw + clean + timestamp) in an in-app panel —
search, click a row to copy. Stored as JSONL in `~/Library/Application Support/tuti/
history.jsonl` (the stage-1 `history.txt` stays on disk, not migrated).

Quick check without the mic:

    uv run test_clean.py [--formal] [--context "previous segment"] "raw text"

