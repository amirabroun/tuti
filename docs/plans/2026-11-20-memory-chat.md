# Memory window split + AI chat — plan

> **For agentic workers:** native execution in-session; no commits (Amir's rule — uncommitted
> until he asks). Verification = py_compile / xcodebuild / inline probes; test suites are ask-first.

**Goal (his ask, 2026-11-20):** «بخش بنفش رو جدا کن از اون بخشی که برای clip برده و اسمش رو
یه چیز دیگه بذار» + «بعضی وقتا می‌خوام همون AI یه جواب کوتاه بهم بده، توی همون‌جا … بعد من
بهش بگم همونی که ذخیره کرده رو عوضش کنم، مثلاً اسمشو. یه سیستم کوچیک این‌جوری براش درست کن.»

**Decoded:**
1. The purple memory recorder is decoupled from the main window's cards/clipboard flow
   (a memory recording used to pop a card into the clip list) and renamed:
   the bar is «افزودن به حافظه», the button «ضبط/توقف».
2. A small chat with the AI inside the «حافظه» window: short answers, file-aware, able to
   rewrite the memory file (save / rename / tick / delete) in the same conversation.

## Global constraints

- Memory recordings must NOT create main-window cards, touch the clipboard, or drive the
  main phase; the mic is exclusive — either recorder, never both.
- A chat file-rewrite goes through the same MEMORY_LOCK + tmp/.bak/os.replace path as a
  merge; the lock is held across the chat LLM call (a concurrent merge waits, never races).
- Chat failure touches nothing (reply-only failure = an error line; the file stays as it was).
- prompts/chat.md is self-contained (the memory.md format rules inline) and re-read per call.

## Task 1: prompts + llm_clean.chat()

- `prompts/chat.md` (new): «دستیار حافظهٔ توتی» — short Persian replies (1–2 sentences);
  save directly when clear, ask one short question when ambiguous; edits/deletes only on
  his explicit ask; answer file questions (incl. چینش) from the file; when (and only when)
  the file changed, append `===MEMORY===` + the whole new file + `===END===` after the reply.
- `llm_clean.chat(memory_md, turns, text) -> (reply | None, new_file | None, usage)`:
  extra = `<m>` file + optional `<history>` (last 8 turns, «امیر:/تو:» lines); max_tokens
  4000; TUTI_LLM_PLAN_MODEL overrides the model here too (same stronger-head reasoning as
  plan()); delimiter parse; reply-only + file-only («انجام شد.» fallback) both handled.

## Task 2: server.py

- `_read_memory()` (None = unreadable → callers must never write) + `_write_memory()`
  (tmp + .bak + os.replace, callers hold MEMORY_LOCK) — `_remember` refactored onto them.
- `_remember` now emits the merge outcome: `memory_saved` plain / `unchanged:true` /
  `failed:true` (no silent no-chip path — there is no card to stay silent on anymore).
- `_memory_chat` (thread, lock held across the LLM call) → `memory_chat_result` with
  optional `changed:true` / `failed:true`. Protocol docstring updated (incl. the renamed bar).

## Task 3: Swift

- TranscriptViewModel: `memoryActive` / `memoryPartial` / `memorySave` (+ 4 s self-clear) —
  the memory recorder's own state; `toggleRecord()` loses the memory param (main cards only,
  guarded on memoryActive); `toggleMemoryRecord()` drives start/stop frames itself; partial/
  asr_final/error/memory_saved handlers branch on memoryActive; memory recordings write NO
  card and NO history line (the transcript lives in llm_calls.jsonl kind "chat"/"memory" and
  the file). Chat state `chatTurns/chatPending/chatFailed` + `sendChat()` (last 8 turns ride
  along). Auto-stop fires whichever recorder is active.
- MemoryView: `chatCard` (thread + input + pending/failed states) above the plan card;
  recordBar renamed «افزودن به حافظه» with the save-state line (saving/saved/unchanged/failed).
- App.swift: menu-bar label shows brain + word count while the memory recorder runs;
  Record buttons disabled while memoryActive.
- The card «حفظ شد» chip stays only for old history lines (memory:true in history.jsonl).

## Review Focus

- clean_state off arriving after asr_final for a memory recording must not hit the card
  path (finalRaw stays nil → the `if !cleaning, let raw = finalRaw` branch skips).
- An empty memory recording: memorySave resets to none, no merge call (server skips empty).
- Chat while a recording is active: sendChat refuses (mic + lock business).
- Old memory-mode history lines: chip on relaunch unchanged; retry never re-runs memory.

## EXTENDED same night — the usage log + window polish (his ask)

«سیستم لاگ رو درست کن … هم نسخهٔ خام و هم جوابی که AI داده ذخیره شود، صرفاً برای اینکه
بعداً بتوانیم پردازششان کنیم. یه مقدار هم frontendش را بهتر کن»:

- `~/Library/Application Support/tuti/memory_log.jsonl` (server `_mlog`, MLOG_LOCK): ONE
  JSONL event per memory interaction — `record` {raw, outcome: saved/unchanged/failed,
  tokens} / `chat` {text, reply, changed, failed, nturns, tokens} / `plan` {question,
  answer, failed, tokens}. Failures logged too. llm_calls.jsonl stays the per-call LLM
  debugging record — this file is the usage-analysis record (raw + AI answer side by side).
- Window: a third title-row button opens the log (disabled until it exists), the chat
  card gained a clear-thread button (session only — the log keeps everything), section
  headers show counts («کارها — ۲ باز از ۳»), the empty-state line matches the renamed
  bar. VM: `clearChat()`. Config: `memoryLogURL`.
