# Changelog

All notable changes to taskwarrior.nvim (formerly `task.nvim`) are documented
here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

Large feature push closing the gap against ribelo/taskwarrior.nvim,
huantrinh1802/m_taskwarrior_d.nvim, and duckdm/neowarrior.nvim. See
`docs/feature-gap-analysis.md` for the full competitor survey that drove
this list, and `docs/research/ui-polish.md` for the UI redesign notes.

### Fixed
- **Save with no changes is a true no-op.** Previously a clean `:w` on a
  taskmd buffer ran the apply pipeline anyway, forking `task` and
  emitting `Applied: +0 added, ~0 modified, v0 done`. Now zero-action
  saves short-circuit silently in both confirm and non-confirm modes;
  toast suppression also covers the `:w!` / `force=true` path. (#370)
- **Checkbox NF glyphs were empty strings** in `icons.lua` for
  `checkbox_pending` / `checkbox_started` / `checkbox_done`, so the
  fallback always took the ASCII branch. Codepoints populated.

### UI polish — checkbox icons land
- **Checkbox virt_text overlay.** Each task line now paints a 5-cell
  overlay over the literal `- [ ]` / `- [>]` / `- [x]` showing
  󰄱 / 󰐊 / 󰸞 (or whatever the user override resolves to). The markdown
  source is **unchanged** — the parser regex `^- \[([ >x])\] (.+)$`
  still matches, so round-trips through `taskmd apply` are bitwise
  identical. Disable with `icons = false`; configure individual slots
  via `icons = { checkbox_pending = "...", checkbox_done = "..." }`.
  Auto-skipped when `vim.g.have_nerd_font` is unset and no slot
  override is provided (the ASCII fallback would just redraw the
  source).

### UI polish (task lines look 10x better)
- **Nerd Font icon system.** New `lua/taskwarrior/icons.lua` exposes a
  typed slot table (`priority_h`, `status_started`, `due_today`,
  `urg_1..urg_8`, etc.) with per-slot NF glyph + ASCII fallback.
  Auto-selects based on `vim.g.have_nerd_font`. Override via
  `config.icons = { priority_h = "!!!" }` for individual slots or
  `icons = false` to force ASCII.
- **Sign-column priority + status glyphs.** Active tasks get a play
  icon, priority levels get chevron glyphs, overdue tasks get an alert
  icon — all in the sign column, which doesn't shift any text columns
  and is automatically revealed on task buffers.
- **Contextual relative-date virt-text.** `due:2026-04-21` gets a
  right-aligned chip showing `today`, `tomorrow`, `in 3d · Fri`,
  `next Mon`, `in 2w`, `3d overdue`, etc. **The literal date in the
  buffer is never rewritten** — `:w` still round-trips. Refresh is
  automatic on buffer render (and will be on CursorHold in a follow-up).
- **OVERDUE badge pill** for any task past its due date — contrasting
  fg/bg so it dominates the margin. **Off by default**
  (`overdue_badge = false`); the relative-date label already says
  "Nd overdue". Enable for a high-contrast alarm effect.
- **Urgency bar glyph.** `12.3` becomes `▇ 12.3` — 8-band unicode
  block glyph whose color matches the `urgency_colors` breakpoints.
  **Off by default** (`show_urgency = false`); enable for the score.
  `urgency_bar = true` controls whether to prefix the number with
  the band glyph when urgency IS shown.
- **Started-elapsed chip.** Active tasks show `󰐊 14m`, `󰐊 1h32m`, etc.
  in the right-align virt-text. (DST-safe: `os.time()` with
  `isdst=false` to match `os.date("!*t")` convention.)
- **Palette refactor.** Six semantic roles (`TaskAccent`, `TaskUrgent`,
  `TaskWarn`, `TaskInfo`, `TaskTagHL`, `TaskSubtle`). Field groups
  (`TaskPriorityH`, `TaskProject`, …) now `link=` to a role so a
  colorscheme override of the role recolors every field that uses it.
- **`TaskPriorityL` is no longer green.** Green reads "good / ready",
  but L priority is "ignorable" — now linked to `TaskSubtle`.
- **`TaskCompleted` renders with strikethrough**, making finished
  tasks unambiguous at a glance.
- **`TaskProject` is now subtle**, not bright teal — projects are
  always present, so they belong in the background.
- New config knobs: `icons`, `urgency_bar`, `relative_dates`,
  `relative_date_refresh_ms`.

### Added

#### Task-level operations
- **`:TaskAppend` / `:TaskPrepend`** — add text to the description of the
  task under the cursor without entering the full modify flow. Buffer
  keymaps `>>` and `<<`.
- **`:TaskDuplicate`** — copy the cursor task as a fresh pending task
  (same project/tags/due, new UUID). Buffer keymap `yt`.
- **`:TaskPurge [filter]`** — irreversibly drop deleted tasks from the
  Taskwarrior database. Confirms before acting. Buffer keymap `dD`.
- **`:TaskDenotate`** — remove an annotation from the task under the
  cursor (counterpart to `ga` which adds one). Buffer keymap `gA`.
- **`:TaskModifyField <name>`** — field-specific pickers for
  `project`, `priority`, `due`, and `tag`. Reuses existing values from
  pending tasks so typos in project names don't create orphans.
  Buffer keymaps `MM` (project), `Mp` (priority), `MD` (due), `Mt` (tag).
- **`:TaskBulkModify <spec>`** — apply the same modify spec to every task
  in a visual/line range, one subprocess per task.
- **`:TaskLinkChildren` / `:TaskUnlinkChildren`** — mark `- [ ]` lines
  indented directly under the cursor task as `depends:` of it (or remove
  those dependencies).

#### Reports & workflows
- **`:TaskReport <name>`** — open a named Taskwarrior report. Built-in
  names mirror `task <report>`: `next`, `active`, `overdue`, `recurring`,
  `waiting`, `unblocked`, `ready`, `blocked`, `completed`, `today`,
  `week`, `noproject`.
- **`:TaskInbox`** — GTD-style triage of tasks added in the last 24h
  with no project, no due date, and no tags. Walks them one at a time
  with: set project / schedule / tag / defer / drop / skip / quit.

#### Live query blocks in markdown
- **`<!-- taskmd query: FILTER | sort:X | group:Y -->` / `<!-- taskmd
  endquery -->`** — any markdown buffer can host one or more live
  Taskwarrior views. Blocks auto-refresh on BufReadPost / BufWritePost
  (and on demand via `:TaskQueryRefresh`). Edits inside the block are
  not written back — blocks are read-only mirrors.

#### Visualisation & UI
- **`:TaskFloat [filter]`** — open a task buffer in a centered floating
  window. `q` dismisses.
- **`gf` is now a bordered float**, not a split (less disruptive).
- **`:TaskGraph`** — render the `depends:` graph as a Mermaid flowchart
  in a markdown code fence (renders in markdown-preview.nvim, quarto,
  and most obsidian-style viewers).
- **Header stats virtual-text slots.** `header_stats = { fn1, fn2, … }`
  renders right-aligned strings on the task-buffer header (each fn
  receives the full task list and returns a string or nil).
- **`:TaskExport [path]`** — write the current task buffer out as clean
  markdown (UUIDs and header comment stripped).
- **`:TaskSync`** — async `task sync` wrapper with progress, error
  detection (no-server / auth failure hints), and retry prompt.

#### Dashboard widget
- **`require("taskwarrior.dashboard").top_urgent(n)`** — returns a list
  of pretty-printed urgent tasks for alpha.nvim / dashboard.nvim startup
  sections. See |taskwarrior-dashboard|.

#### Telescope picker actions
- **`<C-d>`** delete with confirm, **`<C-y>`** yank UUID,
  **`<C-a>`** open quick-capture, **`<C-c>`** run arbitrary
  `task <uuid> <verb>`. Added to `lua/telescope/_extensions/task.lua`.

#### Configuration knobs
- **`tag_colors`** — per-tag highlight overrides (string or inline
  `nvim_set_hl` table spec). See |taskwarrior-tag-colors|.
- **`urgency_colors`** — user-configurable urgency→highlight
  breakpoints. Replaces the hardcoded 8/4/0 bands in virtual text and
  views. See |taskwarrior-urgency-colors|.
- **`notifications`** — per-category `vim.notify` gate
  (`start`, `stop`, `modify`, `apply`, `review`, `capture`, `delegate`,
  `view`, `error`, `warn`). Every notification in the plugin now goes
  through a single helper (`lua/taskwarrior/notify.lua`) that honors
  this table. See |taskwarrior-notifications|.
- **`granulation`** — opt-in auto-stop of running Taskwarrior timers
  after N ms of nvim-wide idle. See |taskwarrior-granulation|.
- **`header_stats`** — list of stat-slot functions rendered as virtual
  text on the task-buffer header.
- **`projects` extended form** — each project entry can now be a table
  with `{ name, view, filter, sort }` instead of a plain name. The
  named saved view is auto-loaded when `:Task` opens from that cwd.

### Changed
- `gf` (show `task info`) renders in a bordered float with `q` / `<Esc>`
  to close, rather than a split window.
- Virtual-text urgency numbers are now colored by `urgency_colors`
  breakpoints (previously always `Comment`).
- `views.lua` respects `urgency_colors` when rendering task lines.

### Fixed
- **`+ACTIVE` / `+OVERDUE` / `+BLOCKED` / `+READY` / `+WAITING` (virtual
  tag) filters silently returned empty in the Lua backend.** The tag
  normalizer was rewriting `+ACTIVE` → `tags.has:ACTIVE`, but virtual
  tags aren't stored on tasks — only on-the-fly computed — so the
  `tags.has:` filter never matched. `lua/taskwarrior/taskmd.lua` now
  passes the full Taskwarrior virtual-tag set through verbatim. This
  repairs `:TaskReport active/overdue/ready/waiting/unblocked/blocked`,
  `:TaskFilter +ACTIVE`, and anyone else who filtered by a virtual tag.
- **`:TaskGraph` produced Mermaid output that several extractors
  rejected.** Node IDs are now `t_<uuid8>` (guaranteed letter prefix);
  all nodes are declared before any edges; labels sanitize every
  Mermaid-reserved character (`| ; # { } [ ] " \``) before
  interpolation; empty DBs render a `(no tasks)` placeholder rather
  than an invalid `flowchart TD` with no body.
- **`:TaskExport` crashed with `bad argument #2 to 'insert'`.**
  `string.gsub` returns (result, count) in Lua; passing it directly to
  `table.insert` tricks it into the 3-arg form. Wrap to coerce to
  string-only.
- **`:TaskUnlinkChildren` only removed the first child.** Taskwarrior's
  `depends:-a,b` parser reads it as "remove a, ADD b" — we now prefix
  every UUID with `-` so the whole list is removed.
- **`housing+food` painted `+food` as a tag.** `syntax/taskmd.vim`
  matched `+\w[-_\w]*` with no word-boundary check before the `+`.
  Fixed with `\%(^\|[^0-9A-Za-z_]\)\zs` lookbehind. (The Lua
  extmark-based highlighter in `buffer.lua` already handled this; the
  vim syntax file was a second, out-of-sync highlight layer.)
- **`priority:H` was painted as generic `taskmdField` not
  `taskmdPriorityH`.** Vim syntax rule-precedence is "later-defined
  wins at equal start position"; the generic `field:value` rule was
  defined before the priority-specific ones and stole the match. Rule
  order reversed.
- **External Taskwarrior changes were silently clobbered on save.**
  When Taskwarrior was mutated outside the plugin between render and
  save (CLI `task add`, mobile sync, another editor), the old save
  path would: mark the external add as done/delete, overwrite the
  external field change, or resurrect a task that was completed
  externally. The conflict detector existed (checked
  `modified > rendered_at`) but its output was ignored by
  `apply.on_write`. Rewrote `compute_diff` to implement a 3-way
  merge with five rules (external_modify / external_delete /
  external_add, plus the original modify/done cases). Added
  `force` propagation from `:w!` / `config.force`, and a
  structured `conflicts` list that surfaces to the confirm prompt
  (Apply safe / Apply force / Cancel) or aborts non-confirm saves
  until the user re-renders or forces. Python CLI mirrored for
  parity. Regression shield: `tests/lua/spec/diff_external_changes_spec.lua`
  (9 pure unit tests), `tests/e2e/spec/external_changes_spec.lua`
  (7 round-trip tests against a real `task` CLI),
  `TestIntegrationConflicts` in `tests/test_taskmd_extended.py`
  (5 Python integration tests).
- **Right-aligned virt-text overwrote long task descriptions.**
  `right_align` draws at the window's right edge unconditionally, so
  on wrapped lines it stomped on the last ~35 chars of the first wrap
  segment (e.g. `project:career` became `proje7d overdue   !OVERDUE`).
  All right-align chips switched to `virt_text_pos = "eol"`; the
  chips now follow the content and never overwrite it. `eol` can push
  to an extra wrap line on long tasks — acceptable tradeoff.

### Tests
- Added `tests/lua/spec/features_spec.lua` — 30 assertions covering
  module loading, config defaults and validation, query-block parsing,
  `urgency_hl` banding, per-cwd project entries, and report registry.
- **Screen-rendering harness** (`geometric_overlaps` in
  `tests/e2e/spec/e2e_spec.lua`): given a buffer, reads every
  right-align extmark and compares its width against the literal
  content width at a fixed window size. Flags any case where virt_text
  would overwrite visible characters on a real terminal. Catches the
  class of bug where "the test passed but the user saw garbled text"
  because extmark-data checks alone can't see layout conflicts.
- **Added `tests/e2e/` — full end-to-end harness**. Spawns a temp
  TASKDATA, seeds fixtures, then drives each feature headlessly and
  asserts observable effects: `task export` for mutations, `mmdc` for
  Mermaid output, `nvim_win_get_config` for floats, extmark inspection
  for highlight/virt_text, `vim.fn.synID()` / `synIDattr()` for the
  vim syntax layer, buffer `:w` round-trips for apply/undo.
- Full suite: 151 Lua unit + 60 Lua e2e + 358 Python = **569 tests**,
  up from 474.


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
