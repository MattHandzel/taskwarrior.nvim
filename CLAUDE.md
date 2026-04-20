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
- Python tests: `uv run --with pytest python -m pytest tests/ -q`
- Lua tests: `nvim --headless -u tests/lua/minimal_init.lua \
            -c "PlenaryBustedDirectory tests/lua/spec/ {minimal_init = 'tests/lua/minimal_init.lua', sequential = true}" -c "qa!"`
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
