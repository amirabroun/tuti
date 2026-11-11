# Tuti Stage 4 — final-only clean + live menu bar — Implementation Plan

> Decision (Amir, 2026-11-10): the mid-speech cut/delta/context system is REMOVED — exactly
> one clean of the whole transcript, after stop. The menu bar becomes the live status surface
> (state icon + word count + last words heard). This supersedes the stage-2 live-clean flow
> and its post-execution changes. Branch `fp16-asr` deleted (merged as PR #2).

> Execute task-by-task, in order; checkbox steps. Native in-session execution.
> Git rule for this repo: nothing is committed, pushed or branched without Amir's explicit ask.

**Goal:** while recording, no LLM call happens — the raw transcript streams to the window AND
the menu bar; after stop exactly one clean of the whole transcript (then intent); the
clipboard is written once, at the end.

**Architecture:** the server loses `cut`, `cut_at`, delta queueing and context chaining —
`asr_partial` carries the whole raw transcript so far, `_finish_recording` queues one final
clean, and every recording terminates in exactly one of `clean_all` (cleaned) or
`clean_state` `off` (nothing coming). Swift holds phase `.finalizing` until that terminator
(a restart can no longer land mid-clean on the wrong card), the stall timer becomes a single
auto-stop timer, and the menu bar label becomes a state icon (+ word count while recording)
with a live-tail row in the dropdown.

**Tech Stack:** unchanged — Python stdlib + existing deps, SwiftUI/Observation, no new deps.

**Spec:** conversation of 2026-11-10. Of the pitched options Amir picked final-only clean and
"icon + live dropdown" for the menu bar, and approved deleting `fp16-asr`. Evidence behind
final-only: `llm_calls.jsonl` median delta 64 chars (recordings are short — one final call is
seconds on glm-4.5-air); the `cutAfter=3`/`stopAfter=4` coupling ended recordings on thinking
pauses; every mid-speech clean overwrote the clipboard; cuts landed mid-word (تستینگ → تست + ینگ).

## Global Constraints

- Personal use, app only; paths stay in `Config` (`swift/App.swift`).
- Protocol stays `"v":1`, documented only in the `server.py` docstring. Removed: the `cut`
  action and `clean_all`'s `final` field (always final now). `asr_partial.text` = the whole
  raw transcript so far. `clean_state {"on":false}` is terminal: no clean is coming.
- Every recording ends in exactly one terminator: `clean_all` OR `clean_state off` (or
  `error`). The app stays `.finalizing` until it arrives.
- The clipboard is written exactly once per recording (inside `finishCard`).
- No new Python or Swift dependencies; no new Swift test files (Amir tests the UI himself);
  Python checks run as scripts.
- His app/server on 8765 is never touched: test servers on 8766 only, cleaned up with
  `pkill -f "server.py --port 8766"`; the built app is never launched while
  `pgrep -f tuti.app/Contents/MacOS/tuti` prints something.
- Match the surrounding code: one-line why comments; a multi-line why becomes a named
  function with a docblock.

## Review Focus

1. A restart while the final clean is in flight must not touch the new card: the app holds
   `.finalizing` until `clean_all`/`clean_state off`; the clean runs off the model lock.
   Pinned by Task 2 (terminator always arrives, in order) and Task 3 (phase transitions).
2. Cleaning off (empty `.env`): stop → `clean_state off` → raw card final; no hang on
   Finishing. Pinned by Task 2's empty-env run.
3. Clean failure (wrong key): the raw text becomes the result (cleaned=text fallback) and
   the card still finalizes — no `error`, no hang. Pinned by Task 2's wrong-key run.
4. Empty recording: no clean request, card dropped, back to `.ready`. Pinned by Task 2.
5. Nothing is sent (or clipboard-written) mid-speech: no API request before stop even after
   two speech pauses. Pinned by Task 2's mock recording exactly 2 requests (clean + intent).

---

### Task 1: Server — final-only clean

**Files:** Modify `server.py` (docstring protocol, `LiveSession`, `handler`)

**Interfaces:**
- Produces (protocol): `asr_partial.text` = whole raw transcript so far; `clean_all
  {"text":...}` once after stop (no `final` field); `clean_state {"on":false}` terminal;
  `cut` action gone (ignored like any unknown action).
- Produces (code): `LiveSession.clean_q` items are `str` (the final transcript) or the `None`
  sentinel; `_finish_recording` queues at most one item.

- [x] **Step 1:** Docstring: rewrite the protocol block per Global Constraints.
- [x] **Step 2:** `LiveSession`: drop `cut_at`/`cleaned`/`cut()`/`_queue_delta`;
  `_emit_partial` emits the text as-is; `_finish_recording` = `text = streamer.text.strip()`,
  `put(text)` when `text and llm_clean.configured()` else `emit("clean_state", "off")`;
  `_clean_worker` takes `str` items: `clean_state on` → `llm_clean.clean(text)` (no context)
  → fallback raw on None → `clean_all` → intent on the result. Remove the `cut` branch in
  `handler`.

### Task 2: Python checks

**Files:** Rename `test_cut_request.py` → `test_final_clean.py` (rewritten); Modify `test_ws_client.py`

**Interfaces:**
- Consumes: Task 1's protocol; `test_ws_client.make_audio/stream/RATE` (unchanged).
- Produces: `test_final_clean.py` — mock LLM on :8899 records every request body.

- [x] **Step 1:** `test_final_clean.py`: one recording, two speech stretches with a pause
      between; assert 0 API requests before `stop`; after stop exactly 2 requests —
      clean: single user message `<t>{asr_final.text}</t>`; intent: `<t>MOCK1</t>`;
      exactly one `clean_all`, its text == `MOCK1`.
- [x] **Step 2:** `test_ws_client.py`: drop cut sends, tail assertions and the `final` field;
      keep second-start refusal + late-chunk-after-stop; expect partials, one `asr_final`,
      and one `clean_all` (or clean never started when cleaning is off).
- [x] **Step 3:** Run on 8766 against the mock (docstring commands), once with the real
      `.env`, once with `TUTI_LLM_API_KEY=wrong-key`, once with the three vars unset.
      PASS each time; `pkill -f "server.py --port 8766"` after.

### Task 3: Swift — state machine

**Files:** Modify `swift/TranscriptViewModel.swift`

**Interfaces:**
- Consumes: Task 1's protocol.
- Produces: `scheduleAutoStop()` replacing `scheduleStall()` (`stallTask` → `autoStopTask`);
  `stopAfter: TimeInterval = 4` stays, `cutAfter` is gone; `var wordCount: Int` (whitespace
  split of `partial`).

- [x] **Step 1:** `asr_partial` stores the whole text and restarts the single auto-stop
      timer (`autoStop`-gated, fires `toggleRecord()` after `stopAfter`); the timer is
      cancelled on stop/error/`asr_final`/disconnect/shutdown.
- [x] **Step 2:** `asr_final` no longer sets `.ready`: empty recording → drop card +
      `.ready`; otherwise keep `.finalizing` until `clean_all` (finish clean path) or
      `clean_state off` (finish raw path) — both set `.ready` after `finishCard`.
- [x] **Step 3:** `clean_all`: no clipboard write here (only `finishCard` copies);
      `statusText(.finalizing)` = `cleaning ? "Editing…" : "Finishing…"`.

### Task 4: Swift — menu bar live status

**Files:** Modify `swift/App.swift`

- [x] **Step 1:** `MenuBarExtra` label: `mic.fill` + live `wordCount` while recording;
      `wand.and.stars` while `.finalizing`; `waveform` otherwise.
- [x] **Step 2:** Dropdown: while recording, a live-tail row (last ~60 chars of the raw
      partial, flat, `…` when empty) above the status row.
- [x] **Step 3:** `xcodebuild -project tuti.xcodeproj -scheme tuti -configuration Debug
      -derivedDataPath build build` → `** BUILD SUCCEEDED **` (Amir relaunches the app
      himself).

### Task 5: Docs

**Files:** Modify `README.md`, `AGENTS.md`, this file's checkboxes

- [x] **Step 1:** README: stage-2 section rewritten to final-only (no pause-cut, context,
      locked text), auto-stop paragraph updated, menu bar paragraph updated.
- [x] **Step 2:** `AGENTS.md`: Current behavior + Gotchas updated (cut gotcha line →
      final-only notes; `test_cut_request.py` → `test_final_clean.py`).

## Not in this plan

- Streaming LLM output, retries, caching; bigger stage-3 agent work (Amir's known future
  direction — waits for his ask).
- Any change to `llm_clean.py`/`prompts/` — `context` stays callable via `test_clean.py`
  for prompt experiments even though the server no longer sends it.
