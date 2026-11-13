# Tuti — prompt mode (agent prompt on a toggle) — Implementation Plan

> Decision (Amir, 2026-11-13): a sticky «پرامپت» toggle picks the LLM pass per recording.
> Clean mode is untouched; prompt mode swaps the system prompt for `prompts/agent.md`, which
> does condense (الف) + English-term fix (ب) + turn-speech-into-an-agent-prompt (ج) in ONE
> call. A manual button — he watches the toggle himself; no automatic intent-based switching.
> In prompt mode no verbatim clean exists (card = agent text, «خام» flip = raw ASR as before).
> Supersedes the "second LLM pass after clean" shape proposed 2026-11-11.

> Native in-session execution, task-by-task. Git rule: nothing is committed/pushed/branched
> without Amir's explicit ask. Amir tests the mic/UI himself.

**Goal:** toggle ON at Record time → the recording's single post-stop LLM call uses
`prompts/agent.md` (terse agent prompt, English tech terms, his glossary) instead of
`prompts/clean.md`; everything downstream (clean_all, history, clipboard, paste-back,
intent chip) is unchanged because the agent result IS the final text.

**Architecture:** mode rides the existing `start` control frame (`"mode":"agent"`, absent =
clean, so old clients/tests are unaffected); `LiveSession` stores it and `_clean_worker`
picks `llm_clean.agent()` vs `llm_clean.clean()`. Swift keeps `promptMode` in
`UserDefaults` next to `autoStop`, sends it on start, and shows a checkbox in the status
row + a toggle in the menu-bar dropdown (⌥Space users switch mode without the window).

**Tech Stack:** unchanged — Python stdlib, SwiftUI/Observation, no new deps.

**Spec:** conversation of 2026-11-13 (الف/ب/ج together, one option, clean untouched, manual
button). Evidence behind ب: llm_calls.jsonl shows clean.md's English rule is lazy («دیف»
stays Persian); the ASR tokenizer has no Latin letters, so the prompt must carry a glossary.

## Global Constraints

- Protocol stays `"v":1`; only the docstring gains the optional `mode` field on `start`.
  No new server→app message types: the agent result arrives as the existing `clean_all`.
- `prompts/clean.md` byte-identical. `prompts/agent.md` becomes Amir's file after this
  lands — later changes only on his ask (same rule as clean.md).
- llm_calls.jsonl distinguishes the passes: `kind:"agent"` vs `kind:"clean"`.
- No new Swift/Python test files; `test_final_clean.py` stays green by design (it never
  sends `mode`).
- Buttons follow house idioms: a checkbox like Auto-stop in the status row; a menu-bar
  Toggle like Launch at Login.

## Tasks

### Task 1: prompts/agent.md

Create the prompt in clean.md's voice (his register, compact, examples with <t> input):
purge hesitation/repetition, condense to a direct imperative command, keep every number /
path / project name exact, ALL programming terms in English even when ASR wrote them
correctly in Persian, Persian prose + English terms. Glossary of his terms (کامیت ← commit
… پونیتل ← ponytail), plus "guess unknown tech words from their sound, write Latin".
He edits after seeing output.

### Task 2: llm_clean.agent()

`def agent(text: str) -> tuple[str | None, tuple[int, int]]` — `_call("agent", "agent.md",
text, None)`; same `configured()` gate as `clean()`. Header docstring mentions the third call.

### Task 3: server.py mode

`start` frame accepts `"mode":"agent"` (default `"clean"`); `LiveSession.__init__(in_sr,
emit, mode="clean")` stores it; `_clean_worker` calls `llm_clean.agent(text)` when agent,
else `llm_clean.clean(text)` — the `cleaned` fallback to raw on None, `intent(cleaned)` and
usage counting unchanged. Docstring: document the field.

### Task 4: Swift toggle

`TranscriptViewModel.promptMode: Bool` persisted like `autoStop` (default false), sent as
`"mode":"agent"` on start only when true. `App.swift`: `Toggle("پرامپت", …)` checkbox in the
status row next to Auto-stop; `Toggle("پرامپت", …)` in the menu-bar dropdown next to Record.

### Task 5: verify

`python3 -m py_compile` on both .py; `xcodebuild` Debug build; one real `llm_clean.agent()`
call from the CLI against his key (proves prompt + dialect end-to-end, lands in
llm_calls.jsonl). He does the live mic test.

## Review Focus

- Mode read at Record start: toggling mid-recording never changes an in-flight recording —
  by construction (mode captured in LiveSession).
- `.env` empty + prompt mode on: `configured()` gate is shared → `clean_state off`, raw text
  final, same as clean mode.
- Agent call fails/timeout: `cleaned = text` fallback → raw ASR becomes the card, recording
  unaffected (same path as clean).
- Old server + new app (or test scripts): absent mode = clean; unknown field ignored.
- History/search/«خام»: agent text lands in `clean` field; nothing downstream knows the
  difference.
