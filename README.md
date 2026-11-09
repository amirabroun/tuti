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

The app also lives in the **menu bar** (status, record, the last 5 cards, token usage,
Launch-at-Login, quit — closing the window just hides it). **⌥Space** is a global hotkey:
start speaking from any app; when the recording finishes, the text activates that app and
pastes itself there (the in-app button never pastes — it keeps the card). Paste-back needs
Tuti ticked in System Settings › Privacy & Security › Accessibility.

Paths (repo `~/Documents/repos/tuti`, `uv`) are fixed in `Config` in `swift/App.swift`,
resolved from the home directory.

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
are normal Persian (فایل، سرور) stay Persian. While a clean is in flight the active card
shows a progress bar (`در حال ویرایش…`); if the API fails, that part is locked as raw text and
the recording is unaffected. Empty `.env` = cleanup off, raw text as before. The system prompt
lives in `prompts/clean.md` (raw text is sent wrapped in `<t>…</t>`).

Finished text is split into paragraphs (a break every 3 sentence enders — deterministic,
no extra LLM call), and every LLM call (input, context, raw model output, token usage) is
appended to `~/Library/Application Support/tuti/llm_calls.jsonl` — the before/after record
for prompt testing. The **خام** button on a card flips it to the original raw ASR text;
cumulative token usage shows in the menu-bar dropdown. A card's **pencil** edits it in place
(the history line is rewritten; entries have carried a UUID since 2026-11-09), the **trash**
deletes card + history entry, and the search field filters cards by clean or raw text.

**Voice actions (stage 3)**: after the final clean, one extra small call
(`prompts/intent.md`) checks whether the transcript was a command — «فردا ساعت ۹ یادم بنداز
که به دکتر زنگ بزنم» → a chip «یادآور: زنگ زدن به دکتر» appears on the card; clicking it
creates the Reminders entry (needs the Apple Events permission on first use). Search and
open-URL commands work the same way. Nothing ever runs automatically; plain dictation
answers `none` and costs one small call per recording.

**Auto-stop** (checkbox, on by default): ~4 s without new text ends the recording by itself
(the 3 s pause before it already sent the new speech for cleaning).

**History**: every recording (raw + clean + timestamp) is stored as JSONL in
`~/Library/Application Support/tuti/history.jsonl` and loaded back as cards on launch
(the last 50; the stage-1 `history.txt` stays on disk, not migrated).

Quick check without the mic:

    uv run test_clean.py [--context "previous segment"] "raw text"

