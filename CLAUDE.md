# taskwarrior.nvim

Neovim plugin + Python CLI for editing Taskwarrior tasks as markdown.

## Structure
- `bin/taskmd` — Python CLI tool (parser, adapter, render, diff, apply)
- `lua/taskwarrior/init.lua` — thin orchestrator (~273 lines)
- `lua/taskwarrior/{buffer,apply,capture,delegate,review,saved_views,projects,
  completion,commands,help,validate,taskmd,config,views,diff_preview,feedback,
  health,statusline,cmp}.lua` — focused modules (split landed in v1.2.0)
- `lua/telescope/_extensions/task.lua` — Telescope extension (deliberately
  named `task` even after the v1.3.0 rename, because the extension name is
  the user-facing `:Telescope <name>` slug, not the module path)
- `plugin/taskwarrior.lua` — runtime entrypoint (registers `:Task` lazily)
- `doc/taskwarrior.txt` — vim help reference
- `tests/test_taskmd*.py` — Python tests (pytest, 358 tests)
- `tests/lua/spec/*_spec.lua` — Lua tests (plenary busted, 121 assertions)

## Development
- Python tests: `uv run --with pytest python -m pytest tests/ -q --ignore=tests/e2e`
- Lua unit tests: `./tests/lua/bootstrap.sh`
- **Lua e2e tests: `./tests/e2e/run.sh`** — spawns a temp TASKDATA,
  seeds fixtures, drives each feature against a real `task` CLI, and
  validates downstream output (mmdc for Mermaid, task export for
  mutations, window state for floats). **This is where "verified"
  lives**; unit tests catch syntax errors, e2e catches behaviour.
- Integration tests use a temp TASKDATA dir — they don't touch real tasks
- The CLI must have zero external dependencies (stdlib only)
- `lua/taskwarrior/init.lua` should remain a thin orchestrator (≤300 lines);
  business logic belongs in submodules

## Demo Assets
- Render demos: `demo/render-all.sh` (validates tapes + renders + size-checks)
- Validate tapes only: `demo/validate-tapes.sh`
- Never run `vhs` directly — the render wrapper enforces env isolation to prevent leaking real task data
- Pre-commit hook (`.githooks/pre-commit`) blocks commits with unsafe tapes or oversized assets

## Conventions
- Python: type hints, argparse, no external deps
- Lua: follow NvChad/lazy.nvim patterns
- All Taskwarrior commands must include `rc.bulk=0 rc.confirmation=off` to avoid interactive prompts

## Verification — "works" means end-to-end, not "module loads"

Before reporting a feature done, it must be verified against a real
Taskwarrior DB (use the `tw_env` fixture pattern from
`tests/test_taskmd.py`: temp TASKDATA + isolated `.taskrc`). Unit
tests that only assert "module loads", "command registers", or
"helper returns a list" do NOT verify the feature. They catch syntax
errors, nothing else.

Bar per feature category:

- **Commands that mutate a task** (`:TaskAppend`, `:TaskModifyField`, …):
  seed a task, invoke the command headlessly, `task export` the UUID,
  assert the field changed. Stubbing `vim.ui.input/select` is fine for
  driving the flow.
- **Commands that read and render** (`:TaskGraph`, `:TaskReport`,
  `:TaskInbox`, dashboard, query blocks): actually run a downstream
  validator on the output. For Mermaid, pipe through `mmdc` (it is
  installed). For markdown export, round-trip through `taskmd apply`.
  For reports, assert the buffer contents match the expected filter.
- **Commands with side effects on Neovim state** (`:TaskFloat`, `gf`
  float, embedded query blocks): assert the resulting buffer or window
  exists with the expected properties (`nvim_list_wins`, `nvim_buf_get_lines`).
- **Rendering that places virt_text / signs on buffer lines**
  (relative date chips, overdue badges, urgency bars): checking that
  the extmark *exists* with the right `virt_text_pos` is NOT enough.
  `right_align` draws at the window's right edge unconditionally and
  overwrites buffer text on wrapped long lines. Verify with a
  *geometric* layout check: compute `strdisplaywidth` of the visible
  line content, subtract `strdisplaywidth` of the virt_text, assert
  the first wrap segment doesn't exceed `columns − virt_text_width`.
  See `geometric_overlaps` in `tests/e2e/spec/e2e_spec.lua`.
- **Background behaviour** (granulation auto-stop): drive the real
  timer by advancing `vim.loop.now()`-equivalent or by calling the
  internal check directly; verify `task +ACTIVE export` is empty.
- **Concurrent state — external Taskwarrior changes**: the plugin is
  not the only writer. CLI `task add`, mobile sync, another editor, or
  a background hook can mutate Taskwarrior between the time we render
  a buffer and the time the user saves it. Any change to the save
  path (`compute_diff`, `M.apply`, `apply.on_write`) must hold the
  line against these scenarios:
  A. external `task add` between render and save → not marked done/deleted;
  B. external `task modify` adding a field → field survives the save;
  C. externally completed task whose UUID is still in the buffer →
     no pending duplicate resurrected;
  D. both sides modified same task → conflict surfaced, buffer does
     not silently overwrite external;
  E. `--force` / `:w!` preserves the destructive escape hatch;
  F. no external change → ordinary edits still apply (control).
  See `tests/e2e/spec/external_changes_spec.lua` (Lua round-trip),
  `tests/lua/spec/diff_external_changes_spec.lua` (pure compute_diff),
  and `TestIntegrationConflicts` in `tests/test_taskmd_extended.py`
  (Python mirror). Taskwarrior timestamps have 1-second precision;
  e2e tests must `sleep 1.2s` between render and external mutation
  to make `modified > rendered_at` hold reliably.

"Runs the test suite and all tests pass" is necessary but not sufficient
— the test suite must exercise the feature's real effect, not just its
existence. When the user says "verify all features," expand the test
suite to cover each feature's observable behaviour, don't just run what
already exists. Do not claim a feature is verified if the only check is
that `pcall(require, "taskwarrior.foo")` returned true.
