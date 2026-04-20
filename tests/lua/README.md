# Lua Test Suite for taskwarrior.nvim

This directory contains a [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)-based
test harness for the pure-Lua backend (`lua/taskwarrior/taskmd.lua`) and configuration
module (`lua/taskwarrior/config.lua`).

## Prerequisites

- Neovim 0.9+ (tested on 0.11)
- `git` (to clone plenary.nvim on first run)
- Internet access on first run only (subsequent runs use the cached clone)

No global installation of plenary.nvim is required. The bootstrap script
clones it into `tests/lua/.deps/plenary.nvim` automatically.

## Running the Suite Locally

```bash
./tests/lua/bootstrap.sh
```

That single command will:

1. Clone plenary.nvim (shallow) into `tests/lua/.deps/plenary.nvim` if it is
   not already present.
2. Launch Neovim in headless mode with `tests/lua/minimal_init.lua` as the
   init file, which sets up `runtimepath` for the repo and plenary.
3. Run `PlenaryBustedDirectory` over `tests/lua/spec/`.
4. Exit non-zero if any test fails.

### Running a single spec file

```bash
nvim --headless \
  -u tests/lua/minimal_init.lua \
  -c "PlenaryBustedFile tests/lua/spec/parse_spec.lua" \
  -c "qa!"
```

## Spec Files

| File | What it covers |
|---|---|
| `spec/parse_spec.lua` | `parse_task_line`, `tw_date_to_human`, `human_date_to_tw`, `format_effort`, `parse_effort` |
| `spec/render_spec.lua` | `serialize_task_line` — checkboxes, field order, UUID comments, dates, effort, tags, UDA |
| `spec/diff_spec.lua` | `compute_diff` — zero-change, add, remove, complete, start/stop, modify, duplicate UUID |
| `spec/config_spec.lua` | `task.config.setup()` — defaults, overrides, deep-merge, idempotency |

## Adding New Tests

1. Create `tests/lua/spec/your_spec.lua`.
2. Use plenary's busted shim: `describe`, `it`, `before_each`, `after_each`,
   `assert.equals`, `assert.same`, `assert.is_true`, `assert.is_nil`, etc.
3. Keep tests hermetic — stub `vim.fn.system` if you need to prevent real
   Taskwarrior subprocess calls (see `diff_spec.lua` for the pure-table
   pattern that requires no stubbing).
4. Run `./tests/lua/bootstrap.sh` to verify.

## CI

The `lua-tests` job in `.github/workflows/test.yml` runs this suite on every
push and pull request. It installs Neovim via the `rhysd/action-setup-vim`
action and then executes `./tests/lua/bootstrap.sh`.
