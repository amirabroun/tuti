# Tuti Stage 2 — live AI cleanup — Implementation Plan

> Post-execution change 2 (Amir): cleaned text is LOCKED — each pause sends only the new
> speech (with the cleaned text as context); a Re-clean button re-sends everything; pause
> timer 3 s; English words spoken in English are restored (دیپلوی ← deploy). Verified by
> test_cut_request.py (mock LLM records every request).

> Post-execution change (same day, Amir): per-segment cleaning was replaced by WHOLE-message
> cleaning — every pause sends the entire transcript so far as one request (`clean_all`);
> cutAfter dropped to 2.5 s. Tasks 1-3's segment protocol is superseded by this.

> Execute task-by-task, in order; checkbox steps. Native in-session execution.
> Git rule for this repo: nothing is committed, pushed or branched without Amir's explicit ask.

**Goal:** during a recording, each speech pause cuts the transcript into a segment that is
cleaned by the LLM immediately (no Stop needed); an in-app history panel keeps every message;
cleaning gets context, a spoken/formal style toggle, a visible status, and an opt-in auto-stop.

**Architecture:** the server owns all text slicing — after a cut, `asr_partial` carries only
the tail of the transcript; cuts and the final remainder arrive as indexed `asr_segment`
messages; each segment is cleaned (`clean_final`/`clean_skip`) with the previous cleaned
segment as context and the session's style. Swift renders indexed segments, drives the
stall timer (cut after 4.5 s without new text; optional stop after 10 s), shows the editing
status, and persists resolved segments as JSONL for the history panel.

**Tech Stack:** Python stdlib + existing deps (`server.py`, `llm_clean.py`); SwiftUI +
Observation (macOS 14); no new dependencies on either side.

**Spec:** conversation of 2026-11-08. Amir asked for: auto-send to the AI after a 4-5 s
speech pause, an in-app clipboard/message history, and better AI integration; of the pitched
upgrades he picked all four (context between segments, style toggle, transparent status,
opt-in auto-stop).

## Global Constraints

- Personal use, app only; hard-coded paths stay in `Config` (`swift/App.swift`).
- Protocol additions only, in one place (the `server.py` docstring): new `control` action
  `cut` (with the session's `style` set at `start`), new server messages `asr_segment`
  `{"i":N,"text":Δ}`, `clean_final` `{"i":N,"text":...}`, `clean_skip` `{"i":N}`.
  `asr_partial.text` after a cut = tail only. `asr_final.text` = full transcript, terminator;
  Swift ignores its text. `v` stays 1.
- Existing types keep their shape: `asr_partial`, `error` (`message`), `control` `start`/`stop`.
- LLM config unchanged: `.env` (`TUTI_LLM_BASE_URL/MODEL/API_KEY`), empty = cleaning off.
- No new Python or Swift dependencies; no new Swift test files (Amir tests the UI himself);
  Python checks run as scripts, like `test_ws_client.py`.
- Amir's own app may hold port 8765: test servers run on 8766 and are cleaned up with
  `pkill -f "server.py --port 8766"`; launch the built app only when
  `pgrep -f tuti.app/Contents/MacOS/tuti` prints nothing.
- Old `history.txt` is not deleted or migrated (Amir decides); the panel reads only JSONL.
- Match the surrounding code: one-line why comments; a multi-line why becomes a named
  function with a docblock.

## Review Focus

1. A cut arriving between the last partial and Stop must not duplicate or drop text: the
   remainder at Stop is everything after the last cut; an empty remainder sends no segment.
   Pinned by Task 1's test (cut then more speech then stop; segments concatenate to the
   final text exactly).
2. Clean responses that arrive after the next segment started (or after Stop) must replace
   the right line: everything is indexed; a late `clean_final` for i never touches i+1.
   Pinned by Task 1 (index monotonicity) and Task 4 (Swift replaces by index).
3. Cleaning disabled (empty `.env`) must behave exactly like stage 1 minus manual cuts:
   segments still arrive, lines stay raw, nothing errors. Pinned by Task 1's test run with
   an empty environment.
4. A clean failure (bad key, timeout) must leave the raw line and the recording usable:
   `clean_skip`, not `error` (an `error` would stop the mic mid-recording). Pinned by
   Task 3's test with a wrong key.
5. Unicode offsets: the server slices Python strings (code points); Swift never computes
   offsets into the transcript — it renders only what messages carry. UTF-8 everywhere
   (JSON, file IO). Pinned by Task 1 (Persian assertions exact-match) and Task 5 (history
   round-trips Persian, including ZWNJ).

---

### Task 1: Server — cut action, indexed segments, tail partials

**Files:** Modify `server.py` (docstring protocol, `LiveSession`, `handler`), `test_ws_client.py`

**Interfaces:**
- Produces (protocol): `control` `{"action":"cut"}`; `asr_segment` `{"i":N,"text":Δ}`;
  `asr_final` unchanged shape (full text); `asr_partial` tail-only after a cut.
- Produces (code): `LiveSession.cut()` (idempotent, thread-safe); `self.segments: list[str]`
  on `LiveSession`, appended per cut/remainder.

- [x] **Step 1:** Docstring: document the additions under Protocol v1 exactly as the
      Global Constraints list them.
- [x] **Step 2:** `LiveSession`: add `cut_at = 0` (code-point offset into the full text) and
      `segments = []`; a `_emit_tail` wrapper slices `asr_partial` to `text[cut_at:]` and
      skips empty tails; `cut()` sets `emit("asr_segment", ...)` — implement as: with the
      model lock NOT held, read `self.streamer.text`, `Δ = text[cut_at:]`, append to
      `segments`, `i = len(segments) - 1`, `cut_at = len(text)`, then emit
      `("asr_segment", json {"i": i, "text": Δ})` only when `Δ` is non-empty. Emit needs the
      index: change `emit` payload from `(kind, text)` tuples to `(kind, text, index|None)`
      and `_sender` to include `"i"` when not None (only `asr_segment`/`clean_*` use it).
- [x] **Step 3:** `handler`: `action == "cut"` → `session.cut()`. In `_run`'s success branch,
      emit the remainder as a final `asr_segment` (same code path as `cut`, minus timer
      concerns) and only then `asr_final` with the full text.
- [x] **Step 4:** `test_ws_client.py`: after the current stream, before `stop`: wait 0.2 s,
      send `cut`, stream more audio, send `cut` again (empty-tail case), then `stop`.
      Assert: two `asr_segment`s, indices 0 and 1, `"".join(segment texts) == asr_final.text`
      exactly, and partials after the first cut never contain the frozen text. Exit 0.
- [x] **Step 5:** Run (model loads ~10 s):

      cd ~/Documents/repos/tuti && uv run --offline server.py --port 8766 &  # then, another shell:
      uv run --offline test_ws_client.py   # URI env/arg as the file already supports → PASS

      `pkill -f "server.py --port 8766"` after. Also run once with
      `env -u TUTI_LLM_BASE_URL -u TUTI_LLM_MODEL -u TUTI_LLM_API_KEY` server start (cleaning
      off changes nothing here; clean wiring lands in Task 3).

### Task 2: llm_clean — context and style

**Files:** Modify `llm_clean.py` (`clean`), `prompts/clean.md`, `test_clean.py`

**Interfaces:**
- Produces: `clean(text: str, context: str | None = None, style: str | None = None) -> str | None`
  (`style` is `"spoken"` or `"formal"`; `None`/`"spoken"` → keep spoken words as spoken,
  `"formal"` → formal register). Backwards compatible: existing callers still work.
- Consumes: nothing new.

- [x] **Step 1:** `prompts/clean.md`: add one line — «کلمات را در سطح گفتاری خودشان حفظ کن؛
      محاوره را رسمی نکن (مثلاً «ازشون» را به «از آنها» تبدیل نکن).» The formal line is
      appended by code, not the file (one file, two dialects of one rule).
- [x] **Step 2:** `clean()`: when `style == "formal"`, append to the system prompt:
      «سطح کلام را رسمی کن: صورت رسمی کلمات محاوره‌ای (مثل «ازشون» → «از آنها»).» When
      `context` is non-empty, prepend one extra user message before the text:
      `f"قطعهٔ قبلی گفتار (فقط برای ربط؛ بازنویسیش نکن): {context}"` in both protocols.
- [x] **Step 3:** `test_clean.py`: add `--formal` and `--context` flags (default off/none);
      print which style ran. Run all four combinations against the real API (Amir's key in
      the environment, never a file); spoken + no context output must differ from formal
      output on a sentence containing «ازشون».
- [x] **Step 4:** Run each; expect exit 0 and sensible Persian.

### Task 3: Server — clean per segment, with context, style and clean_skip

**Files:** Modify `server.py` (`LiveSession`, `handler`, `main`)

**Interfaces:**
- Consumes: Task 1's segment emission, Task 2's `clean` signature.
- Produces: `clean_final` `{"i":N,"text":...}` / `clean_skip` `{"i":N}` on the socket;
  `control` `start` accepts optional `"style":"spoken"|"formal"` (default spoken).

- [x] **Step 1:** `LiveSession` gains `style` (from the start message) and
      `last_cleaned: str | None = None`; a `_clean(i, text)` method (daemon thread) calls
      `llm_clean.clean(text, context=self.last_cleaned, style=self.style)`, emits
      `clean_final` `{"i": i, "text": out}` and sets `last_cleaned = out` on success, emits
      `clean_skip` `{"i": i}` on None. `_sender` maps both to the `"text"`/`"i"` JSON shape.
- [x] **Step 2:** Call `_clean` wherever a segment is emitted (cut and final remainder) when
      `llm_clean.configured()` and the segment is non-empty. `last_cleaned` resets to None
      on each new `LiveSession`.
- [x] **Step 3:** Test with the real key in the environment, server on 8766: a
      `test_ws_client.py` run must log `asr_segment`, then a `clean_final` with the same
      `i` and cleaned text, then `asr_final`. Then run once with
      `TUTI_LLM_API_KEY=wrong-key` (other vars real): expect `clean_skip`, no `error`, the
      run still ends with `asr_final`. `pkill` after each.

### Task 4: Swift — segments, stall timer, style, status, optional auto-stop

**Files:** Modify `swift/TranscriptViewModel.swift`, `swift/App.swift` (no new files except
the panel in Task 5)

**Interfaces:**
- Consumes: the Task 1/3 protocol.
- Produces: `struct Segment: Identifiable { let id: Int; var text: String; var clean = false }`
  (in `TranscriptViewModel.swift`); view model state `segments: [Segment]`, `cleaning: Bool`,
  `spoken: Bool` (UserDefaults `"spoken"`, default true), `autoStop: Bool` (UserDefaults
  `"autoStop"`, default **false**), constants `cutAfter: TimeInterval = 4.5`,
  `stopAfter: TimeInterval = 10`.

- [x] **Step 1:** Replace `finals: [String]` with `segments: [Segment]`; `asr_segment`
      appends (text, id: i); `clean_final` sets `segments[i].text`/`.clean` by id (never by
      position — a late reply must not hit a newer line); `clean_skip` marks `clean = false`
      and leaves text. `asr_partial` renders as today (tail-only text needs no trimming);
      `asr_final` ignores its text, keeps phase/mic handling. Clipboard copies on
      `clean_final`/`clean_skip` (Task 5 moves persistence); `ForEach` keys on `id`.
- [x] **Step 2:** Stall timer: on every `asr_partial`, cancel and restart a Task that sleeps
      `cutAfter` and, if still `.recording`, sends `{"action":"cut"}`; when `autoStop` is
      on, the same task chain additionally sleeps to `stopAfter` total and calls
      `toggleRecord()` (the Stop path; `.finalizing` makes a second fire harmless). Timer
      cancelled on stop/error/`asr_final`. `start` message now carries
      `"style": spoken ? "spoken" : "formal"`.
- [x] **Step 3:** Status: `cleaning = true` while any segment has `clean == false` and the
      server is configured... — simpler and honest: set `cleaning = true` when a
      `clean_skip`/`clean_final`-owed segment exists (set on `asr_segment` when the server
      is cleaning; server knows — add `"cleaning": true` to `asr_segment` when it will clean,
      and let `clean_final`/`clean_skip` clear it; Swift mirrors: count of unresolved
      segments > 0). Status row: append `· Editing…` while `cleaning`.
- [x] **Step 4:** `ContentView`: a small `Toggle` for Auto-stop and a spoken/formal
      `Picker` (`.segmented`, «محاوره‌ای» / «رسمی») in the status row; both persisted.
- [x] **Step 5:** `xcodebuild` (as in the daily-use plan) → `** BUILD SUCCEEDED **`, no new
      warnings. Amir checks live: speak, pause ~4.5 s → line freezes and cleans by itself;
      Space-Stop still works; style switch applies to the next recording; with Auto-stop on,
      ~10 s of silence ends the recording.

### Task 5: Swift — history JSONL and the panel

**Files:** Modify `swift/TranscriptViewModel.swift`, `swift/App.swift`, `README.md`

**Interfaces:**
- Consumes: `Segment` from Task 4; resolution points `clean_final`/`clean_skip`.
- Produces: `Config.historyURL` → `.../tuti/history.jsonl`; `struct HistoryEntry: Codable,
  Identifiable { let id = UUID(); let ts: String; let raw: String; let clean: String? }`;
  `func saveHistory(_ raw: String, clean: String?)` (JSONL append, POSIX-locale
  `yyyy-MM-dd HH:mm` stamp); `func loadHistory() -> [HistoryEntry]`; `func clearHistory()`;
  the `History` button opens a `Sheet` (search field, list newest-first, row click copies,
  `Clear` with a confirmation dialog). `clear()` still touches only the window.

- [x] **Step 1:** Persistence: on `clean_final`/`clean_skip`, append one JSONL line for that
      segment (clean text or raw). Delete the old `saveHistory`/`replaceLastHistoryLine`
      (superseded — no other callers). Old `history.txt` stays on disk, untouched.
- [x] **Step 2:** Panel: `Sheet` driven by `@State showHistory` in `ContentView`; list rows
      show `ts`, the clean text (raw when `clean == nil`, grayed), a small copy icon;
      search filters both fields; `Clear` empties the file after confirmation.
- [x] **Step 3:** README: stage-2 section — pause-cutting, style toggle, auto-stop knob,
      history panel and `history.jsonl` (note that `history.txt` from stage 1 is not
      migrated).
- [x] **Step 4:** Build. Inline check (throwaway script or `swift` REPL, not a test file):
      write two Persian entries with ZWNJ to a temp JSONL, `loadHistory`-equivalent decode
      round-trips them exactly. Amir checks the panel live.

### Task 6: Docs and end-to-end pass

**Files:** Modify `server.py` docstring (if anything drifted), `README.md`

- [x] **Step 1:** One full pass server-on-8766 + `test_ws_client.py` with the real key:
      segments cut, clean, finalize; `clean_skip` path with the wrong key; cleaning-off run
      with an empty `.env` (uncommented empty values) — raw lines, no errors anywhere.
- [ ] **Step 2:** Build once more; hand Amir the manual checklist: pause-cut feel at 4.5 s
      (tunable constant), style, auto-stop off by default, panel, clipboard.

## Not in this plan

- Streaming LLM output (segments are short), caching, retries beyond clean_skip.
- Migrating or deleting `history.txt`; agent/TTS features (stage 3).
- Server-side stall detection (the client owns timing; the server stays stateless about UI).
