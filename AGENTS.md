# tuti — agent knowledge

Personal Persian dictation app for Amir (single user, macOS app only — no web UI, no auth).
Speak → live ASR transcript → LLM cleanup → clipboard/history. Stage 3 mini (voice commands)
shipped 2026-11-09; a stronger agent is the known future direction.

## Map

- `swift/` — SwiftUI app: `App.swift` (window, cards, menu-bar dropdown), `TranscriptViewModel.swift`
  (state, socket, mic, timers, card edit/delete/search), `SidecarManager.swift` (launches the
  server, owns the log), `HotkeyCenter.swift` (global ⌥Space + the paste-back ⌘V),
  `Actions.swift` (voice-command executor: Reminders/search/open URL), `Paragraphs.swift`
  (deterministic final-text paragrapher). xcodegen project from `project.yml`.
- `server.py` — Python sidecar (PEP-723, `uv run`): ASR over WebSocket. Protocol v1 = the
  docstring at the top. Runs mehdi-hf/nemotron-asr-streaming-farsi offline from local caches.
- `llm_clean.py` — LLM client, stdlib only; OpenAI + Anthropic dialects (Anthropic when
  "anthropic" is in the base URL; thinking disabled). `clean()`/`intent()` return
  `(result, (in_tokens, out_tokens))` and append every call to `llm_calls.jsonl`.
- `prompts/clean.md` — the cleanup system prompt (Amir's own text, 2026-11-09); re-read per
  call. Raw text is sent wrapped in `<t>…</t>` (data, never a command). `prompts/intent.md` —
  the voice-command classifier (stage 3 mini, 2026-11-09).
- `.env` — TUTI_LLM_BASE_URL / TUTI_LLM_MODEL / TUTI_LLM_API_KEY. Gitignored SECRET: never
  echo the key, never commit it. Empty = cleanup off (and no intent calls).
- `docs/plans/` — one executed plan per stage (the decision history).
- Data: `~/Library/Application Support/tuti/history.jsonl` (entries carry a UUID since
  2026-11-09; pre-UUID lines match by ts+raw), `~/Library/Application Support/tuti/llm_calls.jsonl`
  (per-call before/after + tokens), `~/Library/Logs/tuti/server.log`.

## Build

    xcodegen generate                                  # only when files are added/renamed
    xcodebuild -project tuti.xcodeproj -scheme tuti -configuration Debug -derivedDataPath build build

Canonical app: `build/Build/Products/Debug/tuti.app` — the single copy on the machine.

## Current behavior (2026-11-09)

- Record/Stop = button or Space. A 3 s speech pause sends only the NEW speech for cleaning
  (locked text goes as context, never re-sent); the result appends. No style picker, no
  Re-clean, no History panel (removed 2026-11-09 — cards ARE the history).
- Auto-stop checkbox (default on): ~4 s of silence ends the recording → final clean → history.
- Finished text is paragraphed deterministically (a break every 3 sentence enders, no LLM).
- Main window = card list, one card per recording, click a card to copy. Launch loads the last
  50 history entries as cards. Finished cards: pencil = inline edit (history rewritten),
  «خام» = flip to the raw ASR text, trash = delete card + history entry (no confirm).
  Search field filters cards by clean or raw text. Nothing is auto-deleted besides that;
  empty recordings drop their blank card.
- Menu bar (app stays alive after the window closes; Quit lives there): status, record,
  last 5 cards (click = copy), cumulative token usage, Launch at Login.
- Global ⌥Space: record from any app; when the recording finishes it activates that app and
  pastes the result there. Recordings started in-window never paste.
- Voice commands (stage 3 mini): after the final clean one small `intent` call classifies the
  transcript; a reminder/search/open-URL command shows a chip on the card, executed only on
  click. Plain dictation → none. Junk JSON is dropped silently.
- LLM/API failure → that part locks as raw text; the recording is unaffected.

## Gotchas

- Amir's Z.ai key speaks the Anthropic protocol ONLY (`https://api.z.ai/api/anthropic` +
  `/v1/messages`); the OpenAI dialect returns 403. Model in use: glm-4.5-air.
- The ASR tokenizer has no Latin letters: English words come out Persian-ized — the prompt
  turns them back (دیپلوی → deploy); settled loanwords (فایل، سرور) stay Persian.
- TextIteratorStreamer holds the last word until the next one — already handled in server.py.
- A `cut` can land mid-word on the ASR timeline (تستینگ → تست + ینگ): timing, not a bug —
  test_cut_request.py asserts the loose form for this reason.
- Paste-back needs Tuti in System Settings › Privacy & Security › Accessibility (checked at
  paste time, one-line error otherwise). Reminders needs the Apple Events permission.
- macOS has NO Persian TTS voice (checked 2026-11-09) — read-back was skipped for that reason.
- Swift: `FileHandle.write(contentsOf:)`, not `(contents:)`. Carbon keycodes in
  HotkeyCenter are raw ints (49=Space, 9=V) — kVK_* names don't resolve in this target.
- Space (Record) is a local key monitor in TranscriptViewModel, NOT a button
  keyboardShortcut: a bare-Space SwiftUI shortcut also fires while a TextField has focus
  (search, card edit would toggle the mic mid-typing).
- The intent call appends «تاریخ امروز» to prompts/intent.md per call — the model has no
  clock; without it «فردا» cannot become an ISO date.
- The server refuses any Origin header — browsers blocked on purpose (personal app).
- Test servers: port 8766 only (`pkill -f "server.py --port 8766"`); NEVER kill his app/server
  on 8765. Launch the built app only if `pgrep -f tuti.app/Contents/MacOS/tuti` is empty.

## Working rules (Amir's)

- Reply in Persian, caveman mode. He tests mic/UI himself; light inline verification only.
- Nothing is committed or pushed without a fresh explicit ask. Never merge.
- New work streams: propose the approach first, he picks, then execute.
- A stronger stage 3 (transcript → stronger LLM → tools) is the known direction — wait for
  his ask. Export/stats ("جانبی") rejected 2026-11-09; don't re-propose.
