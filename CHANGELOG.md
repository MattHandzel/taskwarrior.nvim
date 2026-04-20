# Changelog

All notable changes to taskwarrior.nvim (formerly `task.nvim`) are documented
here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.3.0] - 2026-04-19

Renamed the plugin from `task.nvim` to `taskwarrior.nvim` and tightened a
few user-facing surfaces in the process. Functional behaviour is identical
to v1.2.0; this release exists to reduce ambiguity when users discover the
plugin via the `taskwarrior` keyword.

### Changed
- **Repository rename.** `MattHandzel/task.nvim` → `MattHandzel/taskwarrior.nvim`.
  Update your plugin spec.
- **Lua module path.** `require("task")` → `require("taskwarrior")` (and
  the same for every submodule: `taskwarrior.config`, `taskwarrior.taskmd`, …).
- **Vim doc tag.** `:help task.nvim` → `:help taskwarrior.nvim`. Section
  tags renamed from `task-*` to `taskwarrior-*` (`taskwarrior-config`,
  `taskwarrior-views`, …).
- **Health check.** `:checkhealth task` → `:checkhealth taskwarrior`.
  The Python check is now a `warn` (informational), not an `error` — the
  default backend is pure Lua, so Python is genuinely optional.
- **Plugin data dir.** `stdpath("data")/task.nvim/` → `…/taskwarrior.nvim/`.
  Saved views and apply backups migrate automatically on first use.
- **Projects file.** `stdpath("data")/task_nvim_projects.json` →
  `…/taskwarrior_nvim_projects.json`. Migrates automatically.
- **User autocmd events / namespaces / augroups** renamed from `TaskNvim*`
  / `task_nvim_*` to `Taskwarrior*` / `taskwarrior_*`.

### Unchanged (intentionally)
- `:Task*` user commands and the `taskmd` filetype.
- `bin/taskmd` CLI (still stdlib-only Python, still named `taskmd`).
- The Telescope extension is still registered as `task` (so
  `:Telescope task tasks` keeps working — the extension name is independent
  of the module path).

### Migration
- One-line lazy.nvim spec update: change `"matthandzel/task.nvim"` to
  `"matthandzel/taskwarrior.nvim"` and replace `require("task")` calls in
  the `config = function() … end` block.
- All persisted state is migrated transparently.
- If you depended on the old `TaskNvimRefresh` User autocmd pattern (or the
  `task_nvim_hl` / `task_views_hl` namespaces) for custom integrations,
  update to the new `Taskwarrior*` / `taskwarrior_*` names.

### Deprecation shim
`require("task")` and `require("task.*")` keep working during the transition
— `lua/task/` is now a shim directory that forwards to `lua/taskwarrior/`.
A one-time deprecation notice is emitted the first time `require("task")`
runs. Slated for removal in **v1.5**; please update your configs by then.

## [1.2.0] - 2026-04-17

Big release: splits the 2300-line `init.lua` monolith into focused
modules, adds the first real Lua test suite, introduces data-safety
defaults, and fixes a handful of user-reported bugs.

> Released as `task.nvim` v1.2.0. Paths below reflect the layout at that
> tag; in v1.3.0 the plugin was renamed to `taskwarrior.nvim` and the lua
> directory moved to `lua/taskwarrior/`.

### Added
- **Modular architecture.** `lua/task/init.lua` is now 273 lines (down
  from 2264). Domain logic moved into `buffer.lua`, `apply.lua`,
  `capture.lua`, `delegate.lua`, `review.lua`, `saved_views.lua`,
  `projects.lua`, `completion.lua`, `commands.lua`, `help.lua`,
  `validate.lua`.
- **Lua test suite.** 121 assertions across 4 specs under `tests/lua/`
  (parser, render, diff, config) using plenary.nvim's busted runner.
  Bootstrap via `./tests/lua/bootstrap.sh`; CI runs it on every push.
- **Validated setup.** `require("task").setup({...})` now rejects
  unknown keys with typo-aware suggestions, and type-checks every
  known key including nested `delegate.*`, `urgency_coefficients`,
  `urgency_value_mappers`, and `filters` / `projects`.
- **Auto-backup of Taskwarrior data** before every apply. Default
  `auto_backup = true` copies `~/.task` to
  `stdpath("data")/task.nvim/backups/<timestamp>/`; rolling retention
  of the ten most recent backups.
- **Distribution surface.** `plugin/task.lua` entrypoint (`:Task`
  exists without explicit `setup()`), `ftplugin/taskmd.lua`,
  `syntax/taskmd.vim`, `doc/task.txt` (`:help task.nvim`).
- **:TaskFeedback** command: structured feedback buffer that posts
  JSON to a configurable endpoint or opens a prefilled GitHub issue.
- **Community health.** `CONTRIBUTING.md`, `CHANGELOG.md`,
  `SECURITY.md`, `.github/ISSUE_TEMPLATE/`, `PULL_REQUEST_TEMPLATE.md`.
- **Lint configuration.** `stylua.toml`, `pyproject.toml` (ruff),
  `.editorconfig`. CI lint job runs advisory checks.
- **CI matrix.** Ubuntu + macOS × Python 3.8 / 3.10 / 3.12; added
  help-tag smoke verifying `doc/task.txt` (now `doc/taskwarrior.txt`).

### Changed
- **`delegate.flags` default is now `""`** (was
  `--dangerously-skip-permissions`). The old default silently
  disabled Claude Code's tool-permission prompts for every user;
  opting in is now explicit.
- **Views** render with consistent task-line coloring across tree,
  calendar, summary — shared `render_task_line()` helper.
- **Urgency coefficients** are now applied multiplicatively inside
  the Lua backend (via `urgency_value_mappers`) rather than being
  passed as `rc.urgency.uda.FIELD.coefficient` overrides to the
  Python CLI.

### Fixed
- **`:TaskAdd` no longer raises `E565: Not allowed to change text or
  change window`** when nvim-cmp is installed. Close and submit are
  both deferred via `vim.schedule` so they don't run inside cmp's
  textlocked keymap solver.
- **"Invalid buffer id" errors after `:bwipeout`** on a task buffer.
  `refresh_buf` guards against stale bufnrs at entry, and the User
  `TaskNvimRefresh` autocmd body is wrapped in `pcall`.
- **Triple backticks in a task description no longer paint every
  following task line as code.** `syntax/taskmd.vim` clears
  markdown's multi-line code-block regions after inheriting.
- Smart j/k: screen-line movement that falls back to buffer-line
  when the cursor is blocked by a concealed UUID comment; window
  `wrap = true` prevents horizontal-scroll disorientation.

## [1.1.0] - 2026-04-13

### Added
- Pure-Lua backend (`lua/task/taskmd.lua`, default). Python is now optional.
- `:TaskBurndown`, `:TaskTree`, `:TaskSummary`, `:TaskCalendar`,
  `:TaskTags` — five read-only visualisation views.
- `:TaskReview` — guided urgency walk.
- `:TaskDiffPreview` — live virtual-text diff annotations.
- `:TaskDelegate` — hand a task (or a visual range of tasks) to Claude.
- `:TaskSave` / `:TaskLoad` — named views persisted to `stdpath("data")`.
- `:TaskFeedback` — opt-in structured feedback buffer.
- Project auto-filter: `:TaskProjectAdd`, `:TaskProjectRemove`,
  `:TaskProjectList`.
- `urgency_coefficients`, `urgency_value_mappers`, and `custom_urgency`
  config knobs for UDA-aware sort.
- Nerd-font icons, configurable border style, open/transition animations,
  day-start-hour config.

### Fixed
- Header-protection cache moved from closure-local to buffer-local, so
  `:TaskFilter` / `:TaskSort` / `:TaskGroup` followed by any edit no longer
  reverts the header.
- Buffer `swapfile=false` — no more stale `.swp` warnings on reopen.
- CLI refuses to `apply` a file with a missing/malformed header unless
  `--force` is passed — prevents the "every pending task marked done"
  failure mode when a user hand-writes a markdown file.

## [1.0.0] - 2026-03-22

> Released as `task.nvim` v1.0.0.

### Added
- Initial public release. `:Task`, `:TaskFilter`, `:TaskSort`, `:TaskGroup`,
  `:TaskRefresh`, `:TaskAdd`, `:TaskUndo`, `:TaskHelp`.
- `bin/taskmd` CLI (Python, stdlib only).
- `:checkhealth task` (renamed to `:checkhealth taskwarrior` in v1.3.0).
- Demo GIF, README, MIT license.
