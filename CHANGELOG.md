# Changelog

All notable changes to task.nvim are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/) once tagged.

## [Unreleased]

### Added
- `plugin/task.lua` entrypoint — `:Task` is registered without requiring an
  explicit `setup()` call.
- `ftplugin/taskmd.lua` and `syntax/taskmd.vim` — native syntax
  highlighting for rendered task buffers.
- `doc/task.txt` — vim-help reference. `:help task.nvim` now works.
- `auto_backup` (default `true`): copies `~/.task` to
  `stdpath("data")/task.nvim/backups/<timestamp>/` before every apply.
  Keeps the ten most recent backups.
- Issue and pull-request templates under `.github/`.
- `CONTRIBUTING.md` and this `CHANGELOG.md`.

### Changed
- `delegate.flags` default is now `""` (empty) instead of
  `--dangerously-skip-permissions`. The previous default silently disabled
  Claude Code's tool-permission prompts for every user; now it must be
  opted into explicitly.
- `refresh_buf()` guards against stale bufnrs at entry, and the User
  `TaskNvimRefresh` autocmd body is wrapped in `pcall` — prevents "Invalid
  buffer id" errors after `:bwipeout`.

### Fixed
- `:TaskAdd` no longer raises `E565: Not allowed to change text or change
  window` when nvim-cmp is installed. Both close and submit are deferred
  via `vim.schedule` so they don't run inside cmp's textlocked keymap
  solver.
- `test_render_header_contains_filter` updated to match the header format
  that has prefixed `status:pending` since the 1.1 render changes.

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

### Added
- Initial public release. `:Task`, `:TaskFilter`, `:TaskSort`, `:TaskGroup`,
  `:TaskRefresh`, `:TaskAdd`, `:TaskUndo`, `:TaskHelp`.
- `bin/taskmd` CLI (Python, stdlib only).
- `:checkhealth task`.
- Demo GIF, README, MIT license.
