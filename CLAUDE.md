# task.nvim

Neovim plugin + Python CLI for editing Taskwarrior tasks as markdown.

## Structure
- `bin/taskmd` — Python CLI tool (parser, adapter, render, diff, apply)
- `lua/task/init.lua` — Neovim plugin (buffer management, commands, keybindings)
- `lua/task/config.lua` — User-configurable defaults
- `tests/test_taskmd.py` — Python tests (pytest)

## Development
- Run tests: `python3 -m pytest tests/ -v`
- Integration tests use a temp TASKDATA dir — they don't touch real tasks
- The CLI must have zero external dependencies (stdlib only)
- The Lua plugin should be under 300 lines total

## Conventions
- Python: type hints, argparse, no external deps
- Lua: follow NvChad/lazy.nvim patterns
- All Taskwarrior commands must include `rc.bulk=0 rc.confirmation=off` to avoid interactive prompts
