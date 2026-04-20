# Contributing to taskwarrior.nvim

Thanks for wanting to help. taskwarrior.nvim is small enough that the contribution
loop is fast — usually a PR lands within a week if it's on-scope.

## What's in scope

- Bugs in the rendering, diffing, or apply pipeline.
- Better Taskwarrior interoperability: new UDA shapes, edge-case metadata,
  recurring-task semantics.
- New visualisations (`:Task*` read-only views).
- Ecosystem adapters: telescope pickers, nvim-cmp sources, statusline
  components.
- Docs, tests, CI fixes.

## What's out of scope (probably)

- Features that live outside the "edit tasks as markdown" loop — full
  GUI-style kanbans, web UIs, mobile sync, etc.
- Features that require the CLI to take external dependencies — `bin/taskmd`
  is stdlib-only by design.

If you're unsure, open an issue first and ask.

## Development

### Prerequisites

- Neovim >= 0.9
- Taskwarrior >= 2.6
- Python >= 3.8 with pytest

### Running tests

```bash
python3 -m pytest tests/ -v          # 358 Python tests (CLI + diff contract)
./tests/lua/bootstrap.sh             # 121+ Lua assertions (parser/render/config)
```

Both suites run against a temp `TASKDATA` and never touch your real tasks.
If a test touches `~/.task`, that's a bug — please file it.

### Lua module load check

CI runs:

```bash
nvim --headless -u NONE --cmd "set rtp+=." \
  -c "lua for _, m in ipairs({'taskwarrior','taskwarrior.config','taskwarrior.taskmd','taskwarrior.views','taskwarrior.diff_preview','taskwarrior.feedback','taskwarrior.cmp','taskwarrior.statusline','taskwarrior.health'}) do assert(pcall(require, m), m) end; print('ok')" \
  -c "qa!"
```

You can do the same locally.

### Demo rendering

If you touch anything under `demo/`, run:

```bash
demo/validate-tapes.sh   # lints tape sources only
demo/render-all.sh       # re-renders every GIF (requires vhs, ttyd)
```

The pre-commit hook blocks commits that render oversized or unsafe demo
assets. Install it with `git config core.hooksPath .githooks`.

## Code conventions

### Python (`bin/taskmd`, `tests/`)

- Type hints on public functions.
- `argparse` for new commands.
- **Stdlib only.** No `requests`, no `click`, no `rich`. If you need a
  third-party dep, the feature belongs on the Lua side, not the CLI.
- Tests go in `tests/test_taskmd.py` or `tests/test_taskmd_extended.py` —
  every bug fix gets a regression test, no exceptions.

### Lua (`lua/taskwarrior/`)

- Follow the existing style: snake_case, `local M = {}`/`return M`, no
  globals.
- Don't hardcode field-specific semantics. Effort, priority coefficients,
  UDA interpretation must go through configurable mappers. See
  `DEFAULT_URGENCY_VALUE_MAPPERS` in `lua/taskwarrior/taskmd.lua` for the pattern.
- When shelling out, always include `rc.bulk=0 rc.confirmation=off` in the
  Taskwarrior invocation. Interactive prompts break headless usage.
- Sanitize `\n` out of any string before `nvim_buf_set_lines` — vim treats
  those as a buffer-corruption error.
- Never trust `vim.cmd("normal!")` in headless tests — it silently no-ops
  when there's no active UI.

### Commits

- Use imperative present tense (`fix: parse +tag with trailing colon`, not
  `Fixed parsing`).
- Conventional commit prefixes where obvious (`fix:`, `feat:`, `docs:`,
  `test:`, `refactor:`). Not strictly enforced.
- Avoid `--amend` on public history.

## Filing bugs

Use the `Bug report` issue template and include:

- Neovim version (`nvim --version | head -1`)
- Taskwarrior version (`task --version`)
- Python version if the CLI path is implicated
- Minimal reproduction
- Full stack trace (`:messages`)

Data-loss bugs are triaged with top priority. Please flag them clearly.

## Proposing features

Open an issue with the `Feature request` template. Explain the workflow you
want — feature requests framed as a concrete task-management story tend to
get implemented; "would it be cool if" requests tend to stall.

## Releasing (maintainer notes)

1. Bump the `@version` line in `lua/taskwarrior/init.lua` if/when we add one.
2. Update `CHANGELOG.md` with user-visible changes under a new `## [x.y.z]
   - YYYY-MM-DD` heading.
3. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z"` and push the tag.
4. Create a GitHub release with the changelog section as the body
   (`gh release create vX.Y.Z --notes-file <(awk ...)`).

## Code of conduct

Be kind. This is a solo-maintained hobby project; snide criticism makes
maintainers burn out and disappear. If you wouldn't say it in person,
don't say it in an issue comment.
