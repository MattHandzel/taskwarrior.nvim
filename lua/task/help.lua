local M = {}

local HELP_TEXT = [[
task.nvim — Taskwarrior as Markdown
====================================

COMMANDS
  :Task [filter...]       Open tasks matching filter (default: status:pending)
  :TaskFilter [filter]    Change the active filter and re-render
  :TaskSort <spec>        Change sort order (e.g. due+, urgency-, priority-)
  :TaskGroup [field]      Change grouping (e.g. project, tag, or 'none')
  :TaskRefresh            Re-render without changing filter
  :TaskAdd                Quick-capture a new task (floating window)
  :TaskUndo               Undo the last save (repeats task undo N times)
  :TaskHelp               Show this help
  :TaskProjectAdd [name]  Register cwd as a Taskwarrior project
  :TaskProjectRemove      Unregister cwd as a project
  :TaskProjectList        List registered projects
  :TaskDelegate [sub]     Delegate task(s) to Claude. With no arg: open popup.
                          With a visual range: delegate all selected tasks
                          in one claude session. Subcommands:
                            copy          copy the prompt to + register
                            copy-command  copy the full shell command to + register
  :TaskStart / :TaskStop  Start (or stop) the task under cursor
  :TaskSave [name]        Save current filter+sort+group as a named view
  :TaskLoad [name]        Load a saved view (tab-completes names)
  :TaskReview             Walk through pending tasks one by one
  :TaskDiffPreview [on|off]  Toggle live virtual-text diff preview

GLOBAL KEYBINDINGS (always available)
  <leader>tt   Open task buffer (auto-filters by project if cwd is registered)
  <leader>ta   Quick-capture a new task
  <leader>tpa  Register current directory as a project

BUFFER KEYBINDINGS (in task buffers)
  <CR>   Cycle task state: [ ] → [>] started → [x] done → [ ] pending
  o      Insert a new task line below and enter insert mode
  O      Insert a new task line above and enter insert mode
  ga     Annotate the task on the current line (prompts for text)
  gm     Modify task attributes (prompts for +tag, project:, due:, etc.)
  gf     Show full task info for the task on the current line
  <leader>tf   Change filter interactively
  <leader>ts   Change sort order interactively
  <leader>tg   Change grouping interactively

SYNTAX
  - [ ] description [field:value...] [+tag...] <!-- uuid:XXXXXXXX -->
  - [x] completed task
  - [>] started/active task

FIELDS
  project:    Project name (e.g. project:career)
  priority:   H, M, or L
  due:        Due date (YYYY-MM-DD or natural: tomorrow, friday, eow)
  scheduled:  Scheduled date (YYYY-MM-DD or natural: monday, som)
  recur:      Recurrence (daily, weekly, monthly, 2w, etc.)
  wait:       Wait date — task hidden until this date (tomorrow, 2026-04-10)
  until:      Expiry date (YYYY-MM-DD or natural)
  effort:     Estimated effort (30m, 2h, 1h30m)
  depends:    Comma-separated short UUIDs (e.g. depends:ab05fb51,cd12ef34)

NATURAL DATES
  Taskwarrior natively supports: today, tomorrow, yesterday, monday-sunday,
  eow (end of week), eom (end of month), eoy (end of year), som, sow, soy,
  now, later, someday, and relative dates like 3d, 1w, 2m.

TAGS
  +tagname    Add a tag (supports hyphens: +my-tag)

FILTER PRESETS
  Configure named filters in setup():
    filters = {
      { key = "gp", filter = "project:myproject", label = "My Project" },
      { key = "gh", filter = "priority:H",        label = "High Priority" },
      { key = "gd", filter = "due.before:eow",    label = "Due This Week" },
      { key = "gA", filter = "status:pending",     label = "All Pending" },
    }

PROJECT AUTO-FILTER
  Register directories as projects:
    :TaskProjectAdd career       (in ~/projects/career-dev)
    projects = { ["/home/user/work"] = "work" }
  Then <leader>tt auto-filters by project in registered dirs.

FEATURES
  - Tab completion for :Task, :TaskFilter, :TaskSort, :TaskGroup commands
  - Special characters in descriptions (W-2, dashes, parens) are handled safely
  - Recurring tasks are collapsed (only earliest instance shown)
  - Tasks grouped by project (default), configurable via setup()
  - Confirmation dialog before applying changes
  - Header line is read-only (use :TaskFilter to change filter)
  - Cursor clamped before UUID comment (configurable)

LUA API
  require("task").api.export(filter)       Export tasks as Lua table
  require("task").api.get_task_on_cursor() Get task under cursor
  require("task").api.detect_project()     Get project for cwd
  require("task").api.get_completions()    Get projects, tags, fields
  require("task").api.refresh()            Refresh all task buffers

FILTER EXAMPLES
  :Task +finance                    Tasks tagged +finance
  :Task project:career              Tasks in career project
  :Task due.before:eow              Tasks due before end of week
  :Task priority:H                  High priority tasks
  :Task +ais project:career         Combine filters
]]

function M.show(set_buf_lines_fn)
  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[help_buf].buftype = "nofile"
  vim.bo[help_buf].filetype = "markdown"
  set_buf_lines_fn(help_buf, HELP_TEXT)
  vim.bo[help_buf].modifiable = false
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, help_buf)
  local ok = pcall(vim.api.nvim_buf_set_name, help_buf, "task.nvim Help")
  if not ok then
    local stale = vim.fn.bufnr("task.nvim Help")
    if stale ~= -1 and stale ~= help_buf then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
      pcall(vim.api.nvim_buf_set_name, help_buf, "task.nvim Help")
    end
  end
end

return M
