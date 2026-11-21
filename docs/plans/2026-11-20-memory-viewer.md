# Memory viewer + AI plan ask (2026-11-20)

## Goal

Amir picked B+C from the viewer pitch (in-app panel + menu-bar items) and added one more
want: an AI that orders his open tasks for him («اول کارهای ساده»). The memory content
becomes visible in the app, and one button asks the LLM for an execution order.

## Global constraints

- `memory.md` stays read-only from the app — the file is the source of truth and the merge
  owns its writes. No in-app editing, no ticking (deliberate v1 exclusion).
- The plan ask is one LLM call on the server (the key never crosses the socket), through the
  same `_call` path as every other pass; a failure shows an error line and never touches the
  file.
- Nothing about the auto-memory flow changes: no click gates anywhere.

## Tasks

1. `prompts/plan.md` + `llm_clean.plan()` — memory file in `<m>`, optional question in `<t>`;
   `TUTI_LLM_PLAN_MODEL` optionally swaps the model for this call only.
2. server: app→server `memory_plan`, `_memory_plan()` thread handler, server→app
   `memory_plan_result` (`failed: true` on LLM failure; empty-memory answer without a call).
3. `swift/MemoryView.swift`: the `MemoryFile` parser + the «حافظه» window (tasks with
   done/overdue rendering, facts, the plan card, refresh, open-file).
4. `TranscriptViewModel`: memory state + folder watcher (`os.replace` changes the inode —
   the directory is what gets watched), `askPlan`/result handling, menu-bar data.
5. `App.swift`: brain toolbar button, the «حافظه» window scene, menu-bar next-3 tasks +
   «حافظه…» + file item.

## Review Focus

- Watcher lifecycle: fd closed on cancel; folder missing until the first save → retry on
  the next `reloadMemory`.
- Menu-bar section hidden entirely while the memory file does not exist.
- plan prompt: only `- [ ]` lines, no invented tasks, one short line per task.
