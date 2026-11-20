# tuti — agent knowledge

Personal Persian dictation app for Amir (single user, macOS app only — no web UI, no auth).
Speak → live ASR transcript → one LLM pass after stop → clipboard/history. Stage 3 mini
(voice commands) shipped 2026-11-09; stage 4 (final-only clean + live menu bar) 2026-11-10;
prompt mode 2026-11-13 (REPLACED 2026-11-15 by message mode — a «پیام» toggle: light summary +
smooth + sentence reorder, prompts/message.md; the agent-prompt mode and agent.md are gone) and
the shared ASR glossary (frequency-ordered keyword list in clean.md + message.md, built from
llm_calls.jsonl evidence) 2026-11-15; a stronger agent is the known future direction.

## Map

- `swift/` — SwiftUI app: `App.swift` (window, cards, menu-bar dropdown), `TranscriptViewModel.swift`
  (state, socket, mic, timers, card delete/search), `SidecarManager.swift` (launches the
  server, owns the log), `HotkeyCenter.swift` (global ⌥Space + the paste-back ⌘V),
  `CopyHud.swift` (the copied-feedback pop sound + floating HUD capsule),
  `Actions.swift` (voice-command executor: Reminders/search/open URL), `Paragraphs.swift`
  (deterministic final-text paragrapher), `Permissions.swift` (Settings panel: permission
  dots + the LLM config the server reports; asks everything on first launch). xcodegen project
  from `project.yml`.
- `server.py` — Python sidecar (PEP-723, `uv run`): ASR over WebSocket. Protocol v1 = the
  docstring at the top. Runs mehdi-hf/nemotron-asr-streaming-farsi offline from local caches.
- `llm_clean.py` — LLM client, stdlib only; OpenAI + Anthropic dialects (Anthropic when
  "anthropic" is in the base URL; thinking disabled). `clean()`/`message()`/`intent()`/`memory()` return
  `(result, (in_tokens, out_tokens))` and append every call to `llm_calls.jsonl`
  (kind: clean/message/intent/memory). Since 2026-11-18: one retry on HTTP 429 (the shared Z.ai
  coding plan's short-lived limit — it clears in ~a minute; sleep = the API's Retry-After,
  capped 8 s, else 4 s), and FAILED calls are logged too: `out_text: null` + `error`
  (HTTP code + response body) + `ms`/`tries`, so rate limits stay debuggable afterwards.
- `prompts/clean.md` — the cleanup system prompt (Amir's own text, 2026-11-09); re-read per
  call. Raw text is sent wrapped in `<t>…</t>` (data, never a command). `prompts/message.md` —
  the message-mode system prompt (2026-11-15: clean + light summary + smooth + reorder; no
  content cuts, casual-clean tone, no answering the speaker). Both share one glossary block
  (frequency-ordered, ASR-actual spellings like پونیتیل/کویست/پیارو; «اسکیل پونیتیل ← ponytail
  skill» as a compound entry — the single word alone flaked even when listed first). `prompts/intent.md` —
  the voice-command classifier (stage 3 mini, 2026-11-09). `prompts/memory.md` — the memory
  merge prompt (2026-11-20): current file in `<m>…</m>` + transcript in `<t>…</t>` → the whole
  rewritten file back (dedup, tick done `- [x]`, drop nothing else).
- `.env` — TUTI_LLM_BASE_URL / TUTI_LLM_MODEL / TUTI_LLM_API_KEY. Gitignored SECRET: never
  echo the key, never commit it. Empty = cleanup off (and no intent calls).
- `docs/plans/` — one executed plan per stage (the decision history).
- Data: `~/Library/Application Support/tuti/history.jsonl` (entries carry a UUID since
  2026-11-09; pre-UUID lines match by ts+raw; `fallback`/`mode` fields since 2026-11-18 —
  pre-flag lines are detected as fallbacks by clean == raw), `~/Library/Application Support/tuti/llm_calls.jsonl`
  (per-call before/after + tokens; failures too since 2026-11-18), `~/Documents/tuti-memory/memory.md`
  (the auto memory file, 2026-11-20 — HIS file, hand-editable; `.bak` next to it),
  `~/Library/Logs/tuti/server.log`.

## Build

    xcodegen generate                                  # only when files are added/renamed
    xcodebuild -project tuti.xcodeproj -scheme tuti -configuration Debug -derivedDataPath build build

Canonical app: `build/Build/Products/Debug/tuti.app` — the single copy on the machine.
`/Applications/tuti.app` is a SYMLINK to it (2026-11-14, `ln -s` + `lsregister -f`), so every
rebuild flows through and there is still one real bundle — a real copy would go stale on the
next rebuild. UNVERIFIED as of 2026-11-14: whether the symlink gives what Amir wanted from
/Applications (he did not name the missing capabilities; Launchpad/Spotlight/picker
visibility was never checked), and whether Launch at Login needs an off/on toggle to point
at the /Applications path (inferred, login-item code not read). If the symlink falls short,
the fallback is a real copy into /Applications after each build.

## Current behavior (2026-11-20)

- Record/Stop = button or Space. NO LLM call mid-recording: the raw transcript streams live
  (active card + menu bar); after stop the WHOLE transcript gets ONE LLM pass and the result
  replaces the card text. No style picker, no Re-clean, no History panel (removed
  2026-11-09 — cards ARE the history).
- Message mode (2026-11-15, replaced prompt mode 2026-11-13): sticky «پیام» checkbox (status
  row) + menu-bar toggle. ON at Record time → the post-stop pass is `llm_clean.message()`
  (prompts/message.md: clean + light summary + smooth + reorder; keeps all facts, names and
  tech details, never answers the speaker) instead of the clean; no verbatim clean exists in
  that mode (card = message text, «خام» flip = raw ASR). Mode is sent on the start frame
  (`"mode":"message"`, absent = clean) and fixed per recording; ⌥Space follows the same
  toggle. Benchmark notes: glm-4.5-air glossary recall is ~95% per call (one دیف occasionally
  stays Persian); proper-noun protection can fight the glossary, hence the explicit
  «واژه‌نامه مقدم است» line.
- Auto-stop checkbox (default on): ~4 s of silence ends the recording → the one pass → history.
- Finished text is paragraphed deterministically (a break every 3 sentence enders, no LLM).
- Main window = card list, one card per recording, click a card to copy. Launch loads the last
  50 history entries as cards. Finished cards: «خام» chip (bordered, waveform/wand icon) =
  flip to the raw ASR text, trash = delete card + history entry (no confirm, red on hover).
  Inline card edit REMOVED 2026-11-13 (never used). Search field filters cards by clean or
  raw text. Nothing is auto-deleted besides that; empty recordings drop their blank card.
  Fallback cards (the LLM pass failed) carry a «تلاش دوباره» chip (2026-11-18): one click
  re-runs the pass on that recording's raw text, in its recorded mode, via the server's
  `retry` message (`cleaned` reply updates the card AND its history line; clipboard never
  touched — card-click copies). No intent re-run on retry.
- Menu bar (app stays alive after the window closes; Quit lives there): icon alone shows the
  state — mic.fill + live word count while recording, wand.and.stars while the AI edits,
  waveform idle; dropdown adds the last ~60 chars heard while recording, status, record,
  the «پیام» toggle, last 5 cards (click = copy), cumulative token usage, Launch at Login.
- Global ⌥Space: record from any app; when the recording finishes it activates that app and
  pastes the result there. Recordings started in-window never paste.
- Permissions asked together on the first launch (2026-11-10): the Settings panel opens once
  (mic prompt + Reminders automation probe fire right there), reopenable from the menu bar
  (Settings…). It also shows the LLM config actually loaded (model + URL from the server's
  one `config` message; the key never crosses the socket). Accessibility is only linked to
  its Settings pane — macOS grants it by hand, never via API. The menu-bar dropdown shows
  `lastError` in red, so paste/permission failures are visible without the window.
- Voice commands (stage 3 mini): after the final clean one small `intent` call classifies the
  transcript; a reminder/search/open-URL command shows a chip on the card, executed only on
  click. Plain dictation → none. Junk JSON is dropped silently.
- Auto memory (2026-11-20): the same `intent` call also flags memory-worthy transcripts
  (`{"action":"memory"}` — tasks/plans/durable facts, even without «یادت باشه»); the server
  then makes ONE `memory()` call (current file + transcript + today's date) and merge-rewrites
  `~/Documents/tuti-memory/memory.md` (`# کارها` checkboxes + `# حقایق`; done tasks tick
  `- [x]`, never deleted; previous version kept as .bak). FULLY AUTOMATIC — no click anywhere
  (his hard rule); the card's «حفظ شد» chip (brain, persisted in history as `memory`) is
  notification only. Failure/unchanged file → no chip, recording long since done. The retry
  («تلاش دوباره») never re-runs memory, same as intent.
- LLM/API failure (after the one 429 retry) → the raw text becomes the result (clean_all then carries `"fallback":true`);
  the recording is unaffected. The clipboard is written exactly once per recording (at finish),
  never mid-recording.
- Copied feedback (2026-11-14): at that one clipboard write a soft Pop plays and a floating
  click-through HUD capsule shows top-center (fades in, gone at ~3 s): «کپی شد» + ~60-char
  snippet of the final text; orange «LLM خطا — متن خام کپی شد» when the server flagged
  fallback. Never fires on card-click copies — that copy is his own action.

## Gotchas

- Amir's Z.ai key speaks the Anthropic protocol ONLY (`https://api.z.ai/api/anthropic` +
  `/v1/messages`); the OpenAI dialect returns 403. Model in use: glm-4.5-air.
- The ASR tokenizer has no Latin letters: English words come out Persian-ized — the prompt
  turns them back (دیپلوی → deploy); settled loanwords (فایل، سرور) stay Persian.
- TextIteratorStreamer holds the last word until the next one — already handled in server.py.
- Every recording terminates in exactly one of `clean_all` / `clean_state off` / `error`;
  the app holds `.finalizing` (Record disabled) until it — up to the 15 s LLM timeout — so a
  restart can never land mid-clean on the wrong card. Pinned by test_final_clean.py.
- The mid-speech cut system (stage 2, incl. locked-clean context chaining) was REMOVED
  2026-11-10: cuts landed mid-word, every pause overwrote the clipboard, and the 3 s/4 s
  cut–stop coupling ended recordings on thinking pauses. `clean()`'s context param stays
  (test_clean.py --context) but the server never sends it.
- Paste-back needs Tuti in System Settings › Privacy & Security › Accessibility (checked at
  paste time, one-line error otherwise). Reminders needs the Apple Events permission.
- Automation TCC (Reminders) has NO read API — the panel's granted dot is a UserDefaults flag;
  revoked in Settings it stays stale-green until re-probed. The probe (`get name`) briefly
  wakes Reminders; tuti quits it again if it woke it.
- The app is signed with the self-signed `tuti-dev` identity (login keychain, since
  2026-11-10; `CODE_SIGN_IDENTITY` in project.yml). Its designated requirement anchors on the
  cert leaf, so TCC grants (Accessibility/mic/automation) SURVIVE rebuilds. The earlier
  ad-hoc builds reset TCC per rebuild — that was the "I ticked it but the panel stays red"
  bug: the tick pointed at a dead binary's cdhash. If tuti-dev is ever missing from the
  keychain, rebuild it (openssl key+cert CN=tuti-dev with codeSigning EKU → legacy PKCS12 →
  `security import -T /usr/bin/codesign` → `security add-trusted-cert -p codeSign`).
- ⌥Space paste-back activates the target app, waits up to 1 s for it to become active, then
  posts ⌘V via `CGEvent.postToPid` — straight to the app's queue, so a focus miss (menu bar
  open, app switched mid-LLM-call) cannot drop or misdirect the keystroke.
- His system SOCKS proxy (VPN/Clash on) breaks `uv run test_ws_client.py`/`test_final_clean.py`
  (websockets tries python-socks): run them with `WS_PROXY= WSS_PROXY= HTTP_PROXY= HTTPS_PROXY=
  ALL_PROXY= all_proxy=`.
- macOS has NO Persian TTS voice (checked 2026-11-09) — read-back was skipped for that reason.
- Swift: `FileHandle.write(contentsOf:)`, not `(contents:)`. Carbon keycodes in
  HotkeyCenter are raw ints (49=Space, 9=V) — kVK_* names don't resolve in this target.
- Space (Record) is a local key monitor in TranscriptViewModel, NOT a button
  keyboardShortcut: a bare-Space SwiftUI shortcut also fires while a TextField has focus
  (the search field would toggle the mic mid-typing).
- The intent call appends «تاریخ امروز» to prompts/intent.md per call — the model has no
  clock; without it «فردا» cannot become an ISO date.
- The ASR model loads fp16 on MPS (`dtype=torch.float16` in server.py main): ~3.5 GB → ~1.6 GB
  footprint. If recognition ever degrades, that is the line to drop.
- The server refuses any Origin header — browsers blocked on purpose (personal app).
- Test servers: port 8766 only (`pkill -f "server.py --port 8766"`); NEVER kill his app/server
  on 8765. Launch the built app only if `pgrep -f tuti.app/Contents/MacOS/tuti` is empty.

## Working rules (Amir's)

- Reply in Persian, caveman mode. He tests mic/UI himself; light inline verification only.
- Nothing is committed or pushed without a fresh explicit ask. Merge is delegable here
  (rescoped 2026-11-13; Sanjeman's never-merge doesn't apply to personal GitHub repos):
  an explicit ask like «pr اجرا کن و بعد merge کن» (PR #4) = create + merge (--merge) +
  delete branch. No merge without that ask.
- New work streams: propose the approach first, he picks, then execute.
- A stronger stage 3 (transcript → stronger LLM → tools) is the known direction — wait for
  his ask. Export/stats ("جانبی") rejected 2026-11-09; don't re-propose.
