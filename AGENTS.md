# tuti — agent knowledge

Personal Persian dictation app for Amir (single user, macOS app only — no web UI, no auth).
Speak → live ASR transcript → LLM cleanup → clipboard/history. Stage 3 (intent/agent) not
built yet.

## Map

- `swift/` — SwiftUI app: `App.swift` (window, cards, history panel), `TranscriptViewModel.swift`
  (state, socket, mic, timers), `SidecarManager.swift` (launches the server, owns the log).
  xcodegen project from `project.yml`.
- `server.py` — Python sidecar (PEP-723, `uv run`): ASR over WebSocket. Protocol v1 = the
  docstring at the top. Runs mehdi-hf/nemotron-asr-streaming-farsi offline from local caches.
- `llm_clean.py` — LLM client, stdlib only; OpenAI + Anthropic dialects (Anthropic when
  "anthropic" is in the base URL; thinking disabled).
- `prompts/clean.md` — the cleanup system prompt; re-read per call, one paragraph by design.
- `.env` — TUTI_LLM_BASE_URL / TUTI_LLM_MODEL / TUTI_LLM_API_KEY. Gitignored SECRET: never
  echo the key, never commit it. Empty = cleanup off.
- `docs/plans/` — one executed plan per stage (the decision history).
- Data: `~/Library/Application Support/tuti/history.jsonl`, `~/Library/Logs/tuti/server.log`.

## Build

    xcodegen generate                                  # only when files are added/renamed
    xcodebuild -project tuti.xcodeproj -scheme tuti -configuration Debug -derivedDataPath build build

Canonical app: `build/Build/Products/Debug/tuti.app` — the single copy on the machine.

## Current behavior (2026-11-09)

- Record/Stop = button or Space. A 3 s speech pause sends only the NEW speech for cleaning
  (locked text goes as context, never re-sent); the result appends. Re-clean button = whole
  transcript in one request, replaces.
- Auto-stop checkbox (default on): ~4 s of silence ends the recording → final clean → history.
- Main window = card list, one card per recording, click a card to copy. Launch loads the last
  50 history entries as cards. Nothing is auto-deleted; empty recordings drop their blank card.
- LLM/API failure → that part locks as raw text; the recording is unaffected.

## Gotchas

- Amir's Z.ai key speaks the Anthropic protocol ONLY (`https://api.z.ai/api/anthropic` +
  `/v1/messages`); the OpenAI dialect returns 403. Model in use: glm-4.5-air.
- The ASR tokenizer has no Latin letters: English words come out Persian-ized — the prompt
  turns them back (دیپلوی → deploy); settled loanwords (فایل، سرور) stay Persian.
- TextIteratorStreamer holds the last word until the next one — already handled in server.py.
- Swift: `FileHandle.write(contentsOf:)`, not `(contents:)`.
- The server refuses any Origin header — browsers blocked on purpose (personal app).
- Test servers: port 8766 only (`pkill -f "server.py --port 8766"`); NEVER kill his app/server
  on 8765. Launch the built app only if `pgrep -f tuti.app/Contents/MacOS/tuti` is empty.

## Working rules (Amir's)

- Reply in Persian, caveman mode. He tests mic/UI himself; light inline verification only.
- Nothing is committed or pushed without a fresh explicit ask. Never merge.
- New work streams: propose the approach first, he picks, then execute.
- Stage 3 (transcript → stronger LLM → tools) is the known direction — wait for his ask.
