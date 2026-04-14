# task.nvim Stress Test Report

Date: 2026-04-09 — 2026-04-10
Environment:
- Neovim: v0.11.6
- Python: 3.13.11
- Taskwarrior: 3.4.2
- Platform: NixOS, Linux 6.19.2
- Baseline pytest: **69/69 passing** → after fixes **70/70 passing** (1.13s)

## Severity Rubric
- **P0**: Data loss, crash, unusable on fresh install, plugin won't load
- **P1**: Broken feature documented in README, confusing error, resource leak, latent correctness risk
- **P2**: Visual polish, minor UX issues, non-blocking edge case
- **P3**: Nitpick, future-work

## Summary

| Severity | Found | Fixed |
|----------|-------|-------|
| P0       | 1     | 1     |
| P1       | 2     | 2     |
| P2       | 0     | 0     |
| P3       | 1     | deferred |

All P0/P1 bugs fixed. 70/70 pytest passing after fixes. Full documented command surface works, checkhealth passes, no swap-file warnings, no global state leakage, conflict detection works, scales cleanly to 5000 tasks.

---

## Findings

### P0-1 — apply with missing/malformed header silently destroys task db

**Test:** Hand-wrote a markdown file with a short header (`<!-- taskmd filter: project:adv -->`) that doesn't match `HEADER_RE`. Ran `taskmd apply`.

**Result:** The parser fell through to `filter_args = []`, which causes `tw_export([])` to return **every pending task in the db**. Any task not present in the hand-written file is then marked done via the `on_delete="done"` default. In a real db, this would silently complete hundreds of tasks.

**Reproduction:**
```bash
cat > file.md <<EOF
<!-- taskmd filter: project:adv -->

- [ ] new task project:adv
EOF
taskmd apply --dry-run file.md   # returns "done" action for every unrelated task
```

**Fix:** `bin/taskmd` — cmd_apply now refuses to run if no valid header is found and `--force` is not passed. Error message tells the user to regenerate the header via `taskmd render` or pass `--force` explicitly. Regression test added: `TestRobustness::test_apply_refuses_missing_header`.

**Severity:** P0 — silent data loss is the worst possible failure mode for a task-management tool. Ship-blocker.

---

### P1-1 — Buffer creates stale swap files, scary warning on reopen

**Test:** Ran `:Task`, `:Task filter`, etc. in a fresh nvim.

**Result:** On startup, a loud multi-line swap-file warning appeared:

```
Found a swap file by the name "~/.local/state/nvim/swap/%home%matth%Obsidian%Main%Tasks: .swp"
    owned by: matth   dated: Sun Mar 22 17:46:08 2026
    ...
```

The plugin was creating a buffer named `"Tasks: <filter>"` without disabling the swapfile. Every open/close cycle leaked a swap file, and subsequent opens tripped vim's "swap file exists" prompt. A new user would see this as "the plugin is broken."

**Fix:** `lua/task/init.lua` — set `vim.bo[bufnr].swapfile = false` and `bufhidden = "hide"` at buffer creation. Stops leaking swap files and avoids the prompt.

**Severity:** P1 — first-run UX killer even though no data is lost.

---

### P1-2 — Header protection closure goes stale after :TaskFilter/:TaskSort/:TaskGroup

**Test:** Read the `setup_buf_autocmds` closure. `header_cache` is captured by `local` at setup time. After `:TaskFilter project:other`, `refresh_buf` rewrites line 1 with the new header, but the closure's `header_cache` still points to the old header.

**Result:** (Latent.) On the next `TextChanged` after a filter/sort/group change, the guard would compare the new header (line 1) against the stale closure-captured old header, see a mismatch, and **revert the buffer to the old header** — undoing the filter change as soon as the user types anything.

Reproduction requires a real TTY because headless nvim doesn't fire TextChanged from feedkeys, so I couldn't demonstrate the failure directly, but the logic is unambiguous.

**Fix:** `lua/task/init.lua` — moved `header_cache` from closure-local to buffer-local (`vim.b[bufnr].taskmd_header_cache`). `refresh_buf` now refreshes the cached value after each re-render, keeping it in sync with whatever header is currently displayed.

**Severity:** P1 — core feature (`:TaskFilter`) would visibly "glitch" or revert for any user who types after changing filters.

---

### P3-1 — Per-buffer augroups accumulate (not cleaned up)

**Test:** 50× `:Task` → `:bwipeout` cycles.

**Result:** `TaskNvim_<bufnr>` augroups linger after bwipeout (autocmds inside them are cleared because they're buffer-scoped, but the empty group remains). Memory growth was +104KB over 50 cycles — modest. Not noticeable at human usage scales.

**Fix:** Deferred. Would require a BufWipeout autocmd to `nvim_del_augroup_by_name`. Acceptable as-is.

**Severity:** P3.

---

## Passed Tests (no findings)

| Area | Detail |
|------|--------|
| Baseline pytest | 69/69 passed, 1.52s, no regressions |
| Empty db render | `taskmd render` on empty db → header only, exit 0 |
| Seed 5 tasks | render/apply clean, roundtrip produces zero actions |
| **Scale: 500 tasks** | render 0.13s, render --group project 0.16s |
| **Scale: 5000 tasks** | render 0.38s, render --group 0.31s, apply (no-op) 0.43s |
| Apply diff at scale | 10 actions on 5000-task file: 3 done + 2 modify + 3 add + 2 "delete→done", all correct |
| Unicode description | 日本語 task with 🎯 emoji + ümlaüts — roundtrip stable |
| Special chars | `(parens)` `[brackets]` `"quotes"` `'apostrophes'` `/slashes` — roundtrip stable |
| Very long description | 1000+ char description — roundtrip stable |
| `+` in description | `"Use C++ for project"` — parser does not create spurious `+for` `+project` tags |
| Missing `task` binary | Returns clean JSON error `{"error":"[Errno 2] No such file or directory: 'task'"}` |
| Nonexistent TASKRC | Returns clean JSON error with TW's explanation |
| checkhealth task | All 5 checks pass (nvim, task, python, taskmd path, data dir) |
| All documented commands | `:Task`, `:TaskFilter`, `:TaskSort`, `:TaskGroup`, `:TaskRefresh`, `:TaskUndo`, `:TaskHelp`, `:TaskBurndown`, `:TaskTree`, `:TaskSummary`, `:TaskTags`, `:TaskCalendar` — all execute without error |
| Buffer reuse | Second `:Task project:demo` returns same bufnr (no duplicate buffers) |
| End-to-end workflow | open → edit → save → refilter → resort → regroup → verify buffer state correct |
| Conflict detection | External modify between render and apply → conflict list correctly populated |
| Memory | 50 open/close cycles: +104KB growth, stable, no augroup leak in active autocmd list |
| `:messages` hygiene | Only explicit user notifications, no junk output |
| No global state leakage | Second `:Task` works correctly, buffer-local state isolated per buffer |

---

## Commands run (abbreviated)

```
pytest tests/ -v                                       # baseline → 69 passed
pytest tests/ -v                                       # after fixes → 70 passed
nvim --headless -c "checkhealth task"                  # all OK
python3 bin/taskmd render                              # empty, 5, 500, 5000
python3 bin/taskmd apply --dry-run …                   # various edit scenarios
nvim --headless ... (workflow/commands/memtest scripts)
```

## Artifacts

- `/tmp/engine-task-nvim/render-5000.md` — 5000-task rendered output
- `/tmp/engine-task-nvim/edit.lua`, `workflow.lua`, `commands.lua` — test scripts

## Verdict

**Ship-ready after fixes.** Phase 6.5 (Share & Distribute) may proceed.
