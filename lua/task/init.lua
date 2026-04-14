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

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function get_taskmd_path()
  local config = require("task.config")
  if config.options.taskmd_path then
    return config.options.taskmd_path
  end
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  return plugin_dir .. "/bin/taskmd"
end

local function run(cmd)
  local out = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  return out, ok
end

local function uuid_from_line(line)
  return line:match("<!%-%-.*uuid:([0-9a-fA-F]+).*%-%->")
end

-- Auto-setup guard: ensures setup() has been called (for lazy-loaded plugins)
local function ensure_setup()
  local config = require("task.config")
  if not next(config.options) then
    M.setup({})
  end
end

-- ---------------------------------------------------------------------------
-- Project detection + persistence
-- ---------------------------------------------------------------------------

local function projects_file()
  return vim.fn.stdpath("data") .. "/task_nvim_projects.json"
end

local function load_projects()
  local path = projects_file()
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, content)
  if ok and type(data) == "table" then return data end
  return {}
end

local function save_projects(projects)
  local path = projects_file()
  local f = io.open(path, "w")
  if not f then return end
  f:write(vim.fn.json_encode(projects))
  f:close()
end

local function detect_project()
  local config = require("task.config")
  local cwd = vim.fn.getcwd()
  local saved = load_projects()
  local all = vim.tbl_extend("keep", config.options.projects or {}, saved)

  for dir, name in pairs(all) do
    -- Normalize: strip trailing slash for comparison
    local d = dir:gsub("/$", "")
    if cwd == d or cwd:sub(1, #d + 1) == d .. "/" then
      return name
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Tab completion helpers
-- ---------------------------------------------------------------------------

local function get_tw_completions()
  local config = require("task.config")
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "task.taskmd")
    if ok_m then
      local ok_c, data = pcall(tm.tw_completions)
      if ok_c and type(data) == "table" then return data end
    end
    -- fall through to Python fallback on error
  end
  local taskmd = get_taskmd_path()
  local out, ok = run(taskmd .. " completions")
  if not ok then return { projects = {}, tags = {}, fields = {} } end
  local parsed_ok, data = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(data) ~= "table" then
    return { projects = {}, tags = {}, fields = {} }
  end
  return data
end

local function complete_filter(arg_lead)
  local completions = get_tw_completions()
  local results = {}

  -- Complete field names
  if not arg_lead:find(":") then
    local fields = { "project", "priority", "status", "due", "scheduled",
                     "recur", "wait", "until", "effort", "tag", "description" }
    for _, f in ipairs(fields) do
      if f:sub(1, #arg_lead) == arg_lead then
        table.insert(results, f .. ":")
      end
    end
    -- Also complete +tag
    if arg_lead == "" or arg_lead:sub(1, 1) == "+" then
      local prefix = arg_lead:sub(2)
      for _, t in ipairs(completions.tags or {}) do
        if prefix == "" or t:sub(1, #prefix) == prefix then
          table.insert(results, "+" .. t)
        end
      end
    end
  else
    -- Complete field values
    local field, val_prefix = arg_lead:match("^(%S-):(.*)$")
    if field == "project" then
      for _, p in ipairs(completions.projects or {}) do
        if val_prefix == "" or p:sub(1, #val_prefix) == val_prefix then
          table.insert(results, field .. ":" .. p)
        end
      end
    elseif field == "priority" then
      for _, v in ipairs({ "H", "M", "L" }) do
        if val_prefix == "" or v:sub(1, #val_prefix) == val_prefix then
          table.insert(results, field .. ":" .. v)
        end
      end
    elseif field == "status" then
      for _, v in ipairs({ "pending", "completed", "deleted", "waiting", "recurring" }) do
        if val_prefix == "" or v:sub(1, #val_prefix) == val_prefix then
          table.insert(results, field .. ":" .. v)
        end
      end
    end
  end
  return results
end

local function render(filter, sort, group)
  local config = require("task.config")

  -- Try the Lua backend first unless the user explicitly asked for python.
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "task.taskmd")
    if ok_m then
      local filter_args = {}
      if filter and filter ~= "" then
        for w in filter:gmatch("%S+") do table.insert(filter_args, w) end
      end
      local ok_r, result = pcall(tm.render, {
        filter = filter_args,
        sort = sort or config.options.sort or "urgency-",
        group = (group ~= "" and group) or nil,
        fields = config.options.fields,
      })
      if ok_r and type(result) == "string" then
        return result
      end
      vim.notify("task.nvim: Lua backend render failed (" .. tostring(result) .. "); falling back to Python",
        vim.log.levels.WARN)
    end
  end

  local taskmd = get_taskmd_path()
  local cmd = { taskmd, "render" }
  if filter and filter ~= "" then
    for word in filter:gmatch("%S+") do
      table.insert(cmd, word)
    end
  end
  table.insert(cmd, "--sort=" .. (sort or config.options.sort or "urgency-"))
  if group and group ~= "" then
    table.insert(cmd, "--group=" .. group)
  end
  if config.options.fields then
    table.insert(cmd, "--fields=" .. config.options.fields)
  end

  -- Pass urgency coefficients as rc overrides so TW uses them for sorting
  for field, coeff in pairs(config.options.urgency_coefficients or {}) do
    table.insert(cmd, string.format("rc.urgency.uda.%s.coefficient=%s", field, tostring(coeff)))
  end

  local out, ok = run(table.concat(cmd, " "))
  if not ok then
    vim.notify("task.nvim: render failed\n" .. out, vim.log.levels.ERROR)
    return nil
  end
  return out
end

local function set_buf_lines(bufnr, text)
  local lines = vim.split(text or "", "\n", { plain = true })
  -- strip trailing empty line that split may add
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Forward declarations (defined below, called from refresh_buf)
local update_highlights
local apply_virtual_text

-- Re-sort task lines within groups using custom_urgency function
local function apply_custom_sort(bufnr)
  local config = require("task.config")
  if not config.options.custom_urgency then return end

  -- Export tasks to get full data for the custom function
  local filter = vim.b[bufnr].task_filter or ""
  local export_filter = filter ~= "" and filter or "status:pending"
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", export_filter)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return end

  -- Build UUID → custom urgency map
  local urgency_map = {}
  for _, t in ipairs(tasks) do
    if t.uuid then
      local custom_urg = config.options.custom_urgency(t)
      urgency_map[t.uuid:sub(1, 8)] = custom_urg or 0
    end
  end

  -- Re-sort lines within each group
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local groups = {} -- list of { header_lines = {}, task_lines = {} }
  local current = { header_lines = {}, task_lines = {} }

  for _, line in ipairs(lines) do
    if line:match("^## ") then
      if #current.task_lines > 0 or #current.header_lines > 0 then
        table.insert(groups, current)
      end
      current = { header_lines = { line }, task_lines = {} }
    elseif line:match("^%- %[") then
      table.insert(current.task_lines, line)
    else
      if #current.task_lines > 0 then
        -- Non-task line after tasks = separator, start new section
        table.insert(current.task_lines, line)
      else
        table.insert(current.header_lines, line)
      end
    end
  end
  if #current.task_lines > 0 or #current.header_lines > 0 then
    table.insert(groups, current)
  end

  -- Sort task lines within each group by custom urgency (descending)
  for _, g in ipairs(groups) do
    table.sort(g.task_lines, function(a, b)
      local uuid_a = uuid_from_line(a)
      local uuid_b = uuid_from_line(b)
      local urg_a = uuid_a and urgency_map[uuid_a] or 0
      local urg_b = uuid_b and urgency_map[uuid_b] or 0
      return urg_a > urg_b
    end)
  end

  -- Reassemble
  local new_lines = {}
  for _, g in ipairs(groups) do
    for _, l in ipairs(g.header_lines) do table.insert(new_lines, l) end
    for _, l in ipairs(g.task_lines) do table.insert(new_lines, l) end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

local function refresh_buf(bufnr)
  local filter = vim.b[bufnr].task_filter or ""
  local sort   = vim.b[bufnr].task_sort
  local group  = vim.b[bufnr].task_group
  local out = render(filter, sort, group)
  if not out then return end
  set_buf_lines(bufnr, out)
  apply_custom_sort(bufnr)
  update_highlights(bufnr)
  apply_virtual_text(bufnr)
  vim.bo[bufnr].modified = false
  -- Update header-protection cache with the freshly-rendered header so the
  -- TextChanged guard doesn't revert to the previous filter/sort/group.
  vim.b[bufnr].taskmd_header_cache = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "TaskNvimRefresh" })
  -- Refresh any open visualization views
  pcall(function() require("task.views").refresh_all() end)
end

-- Namespaces
local hl_ns = vim.api.nvim_create_namespace("task_nvim_hl")
local vt_ns = vim.api.nvim_create_namespace("task_nvim_vt")

-- ---------------------------------------------------------------------------
-- Virtual text (urgency + annotation count)
-- ---------------------------------------------------------------------------

apply_virtual_text = function(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, vt_ns, 0, -1)
  local filter = vim.b[bufnr].task_filter or ""
  local export_filter = filter ~= "" and filter or "status:pending"
  local cmd = string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", export_filter)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return end

  -- Handle warnings before JSON
  local json_start = out:find("%[")
  if json_start and json_start > 1 then
    out = out:sub(json_start)
  end

  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return end

  local config = require("task.config")
  local meta = {}
  for _, t in ipairs(tasks) do
    if t.uuid then
      local urg = t.urgency
      if config.options.custom_urgency then
        local cok, custom = pcall(config.options.custom_urgency, t)
        if cok then urg = custom end
      end
      meta[t.uuid:sub(1, 8)] = {
        urgency = urg,
        annotations = t.annotations and #t.annotations or 0,
      }
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local short_uuid = uuid_from_line(line)
    if short_uuid and meta[short_uuid] then
      local m = meta[short_uuid]
      local parts = {}
      if m.urgency then
        table.insert(parts, string.format("%.1f", m.urgency))
      end
      if m.annotations > 0 then
        table.insert(parts, string.format("[%d note%s]",
          m.annotations, m.annotations > 1 and "s" or ""))
      end
      if #parts > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, vt_ns, i - 1, 0, {
          virt_text = { { table.concat(parts, "  "), "Comment" } },
          virt_text_pos = "right_align",
        })
      end
    end
  end
end

-- Define highlight groups once
local function define_highlights()
  vim.api.nvim_set_hl(0, "TaskPriorityH", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "TaskPriorityM", { fg = "#fab387", bold = true })
  vim.api.nvim_set_hl(0, "TaskPriorityL", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "TaskDue", { fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "TaskDueOverdue", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "TaskScheduled", { fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "TaskWait", { fg = "#9399b2" })
  vim.api.nvim_set_hl(0, "TaskTag", { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "TaskProject", { fg = "#94e2d5" })
  vim.api.nvim_set_hl(0, "TaskRecur", { fg = "#cba6f7" })
  vim.api.nvim_set_hl(0, "TaskEffort", { fg = "#9399b2" })
  vim.api.nvim_set_hl(0, "TaskCompleted", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "TaskHeader", { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "TaskGroupHeader", { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "TaskCheckbox", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "TaskCheckboxDone", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "TaskStarted", { fg = "#89b4fa", bold = true })
end

-- Highlight patterns: { lua pattern, highlight group, is_prefix_match }
-- Order matters for whole-line matches (completed must come first)
-- Tags are handled separately (see highlight_line) so we can require a word
-- boundary before the `+` — otherwise `housing+food` would light up `+food`.
local HL_PATTERNS = {
  { "priority:H",              "TaskPriorityH" },
  { "priority:M",              "TaskPriorityM" },
  { "priority:L",              "TaskPriorityL" },
  { "scheduled:%d%d%d%d%-%d%d%-%d%d", "TaskScheduled" },
  { "wait:%d%d%d%d%-%d%d%-%d%d",      "TaskWait" },
  { "recur:%S+",               "TaskRecur" },
  { "effort:%S+",              "TaskEffort" },
  { "project:%S+",             "TaskProject" },
}

-- Check if a date string (YYYY-MM-DD) is in the past
local function is_overdue(date_str)
  local today = os.date("!%Y-%m-%d")
  return date_str < today
end

-- Apply highlights to a single line
local function highlight_line(bufnr, line_nr, line)
  -- Header comment line — concealed entirely. Users don't need to see the
  -- <!-- taskmd filter: ... | sort: ... | rendered_at: ... --> metadata, only
  -- the tasks themselves. Filter/sort/group are shown via statusline if the
  -- user configures it, and :TaskHelp lists the active settings.
  if line:match("^<!%-%-.*taskmd") then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = #line, hl_group = "TaskHeader",
      conceal = "",
    })
    return
  end

  -- Group header (## ...)
  if line:match("^## ") then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = #line, hl_group = "TaskGroupHeader",
    })
    return
  end

  -- Completed task — dim entire line
  if line:match("^%- %[x%]") then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = #line, hl_group = "TaskCompleted",
    })
    return
  end

  -- Started/active task — highlight with accent color
  if line:match("^%- %[>%]") then
    local cb_s, cb_e = line:find("^%- %[>%]")
    if cb_s then
      vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
        end_col = cb_e, hl_group = "TaskStarted",
      })
    end
    -- Don't return — still highlight fields on this line
  end

  -- Checkbox
  local cb_start, cb_end = line:find("^%- %[ %]")
  if cb_start then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = cb_end, hl_group = "TaskCheckbox",
    })
  end

  -- UUID concealment
  local uuid_start, uuid_end = line:find("<!%-%- uuid:[0-9a-fA-F]+ %-%->")
  if uuid_start then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, uuid_start - 1, {
      end_col = uuid_end, conceal = "",
    })
  end

  -- Due dates (special: overdue = red, future = yellow)
  local pos = 1
  while true do
    local s, e, date = line:find("due:(%d%d%d%d%-%d%d%-%d%d)", pos)
    if not s then break end
    local hl = is_overdue(date) and "TaskDueOverdue" or "TaskDue"
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, s - 1, {
      end_col = e, hl_group = hl,
    })
    pos = e + 1
  end

  -- All other patterns
  for _, pat in ipairs(HL_PATTERNS) do
    pos = 1
    while true do
      local s, e = line:find(pat[1], pos)
      if not s then break end
      vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, s - 1, {
        end_col = e, hl_group = pat[2],
      })
      pos = e + 1
    end
  end

  -- Tags: +word, but only when the `+` is at start-of-line or preceded by a
  -- non-word character. Prevents "housing+food" from highlighting "+food".
  pos = 1
  while true do
    local s, e = line:find("%+[%w_-]+", pos)
    if not s then break end
    local prev = s > 1 and line:sub(s - 1, s - 1) or ""
    if prev == "" or not prev:match("[%w_]") then
      vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, s - 1, {
        end_col = e, hl_group = "TaskTag",
      })
    end
    pos = e + 1
  end
end

-- Re-highlight entire buffer
update_highlights = function(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    highlight_line(bufnr, i - 1, line)
  end
end

-- Debounced highlight update
local highlight_timer = nil
local function schedule_highlight_update(bufnr)
  if highlight_timer then
    vim.fn.timer_stop(highlight_timer)
  end
  highlight_timer = vim.fn.timer_start(50, function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        update_highlights(bufnr)
      end
    end)
    highlight_timer = nil
  end)
end

local function setup_buf_syntax(bufnr)
  define_highlights()
  update_highlights(bufnr)

  -- Set up autocmds for dynamic re-highlighting on text changes
  local hl_group = vim.api.nvim_create_augroup("TaskNvimHL_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    group = hl_group,
    callback = function()
      schedule_highlight_update(bufnr)
    end,
  })
end

local function setup_buf_keymaps(bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Cycle task state: [ ] → [>] → [x] → [ ]
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local toggled
    if line:match("^%- %[ %]") then
      toggled = line:gsub("^%- %[ %]", "- [>]", 1)
    elseif line:match("^%- %[>%]") then
      toggled = line:gsub("^%- %[>%]", "- [x]", 1)
    elseif line:match("^%- %[x%]") then
      toggled = line:gsub("^%- %[x%]", "- [ ]", 1)
    else
      return
    end
    vim.api.nvim_set_current_line(toggled)
  end, opts)

  -- Insert task below
  vim.keymap.set("n", "o", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "- [ ] " })
    vim.api.nvim_win_set_cursor(0, { row + 1, 6 })
    vim.cmd("startinsert!")
  end, opts)

  -- Insert task above
  vim.keymap.set("n", "O", function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "- [ ] " })
    vim.api.nvim_win_set_cursor(0, { row + 1, 6 })
    vim.cmd("startinsert!")
  end, opts)

  -- Annotate
  vim.keymap.set("n", "ga", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    vim.ui.input({ prompt = "Annotation: " }, function(text)
      if not text or text == "" then return end
      local _, ok = run(
        string.format("task rc.bulk=0 rc.confirmation=off %s annotate %s",
          short_uuid, vim.fn.shellescape(text))
      )
      if ok then
        vim.notify("task.nvim: annotation added")
        refresh_buf(bufnr)
      else
        vim.notify("task.nvim: annotation failed", vim.log.levels.ERROR)
      end
    end)
  end, opts)

  -- Modify/append mode: press gm to modify task attributes via prompt
  vim.keymap.set("n", "gm", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    vim.ui.input({
      prompt = "Modify (e.g. +tag project:foo due:tomorrow): ",
      completion = "custom,v:lua.require'task'._complete_modify",
    }, function(input)
      if not input or input == "" then return end
      local escaped = input:gsub("'", "'\\''")
      local _, ok = run(
        string.format("task rc.bulk=0 rc.confirmation=off %s modify '%s'",
          short_uuid, escaped)
      )
      if ok then
        vim.notify("task.nvim: modified")
        refresh_buf(bufnr)
      else
        vim.notify("task.nvim: modify failed", vim.log.levels.ERROR)
      end
    end)
  end, opts)

  -- Filter presets from config
  local config = require("task.config")
  for _, preset in ipairs(config.options.filters or {}) do
    if preset.key and preset.filter then
      vim.keymap.set("n", preset.key, function()
        vim.b[bufnr].task_filter = preset.filter
        refresh_buf(bufnr)
        vim.notify("task.nvim: filter → " .. (preset.label or preset.filter))
      end, { buffer = bufnr, noremap = true, silent = true,
             desc = "task.nvim: " .. (preset.label or preset.filter) })
    end
  end

  -- Buffer-local filter key (uses input() for tab completion support)
  local config2 = require("task.config")
  if config2.options.filter_key then
    vim.keymap.set("n", config2.options.filter_key, function()
      -- Use vim.fn.input with completion so <Tab> works
      local ok, input = pcall(vim.fn.input, {
        prompt = "Filter: ",
        default = vim.b[bufnr].task_filter or "",
        completion = "customlist,v:lua.require'task'._complete_filter",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_filter = input
      refresh_buf(bufnr)
      vim.notify("task.nvim: filter → " .. (input ~= "" and input or "(all pending)"))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "task.nvim: Change filter" })
  end

  -- Buffer-local sort key
  if config2.options.sort_key then
    vim.keymap.set("n", config2.options.sort_key, function()
      local ok, input = pcall(vim.fn.input, {
        prompt = "Sort: ",
        default = vim.b[bufnr].task_sort or "urgency-",
        completion = "customlist,v:lua.require'task'._complete_sort",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_sort = input
      refresh_buf(bufnr)
      vim.notify("task.nvim: sort → " .. input)
    end, { buffer = bufnr, noremap = true, silent = true, desc = "task.nvim: Change sort" })
  end

  -- Buffer-local group key
  if config2.options.group_key then
    vim.keymap.set("n", config2.options.group_key, function()
      local ok, input = pcall(vim.fn.input, {
        prompt = "Group by (empty=none): ",
        default = vim.b[bufnr].task_group or "",
        completion = "customlist,v:lua.require'task'._complete_group",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_group = (input ~= "" and input ~= "none") and input or nil
      refresh_buf(bufnr)
      vim.notify("task.nvim: group → " .. (input ~= "" and input or "(none)"))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "task.nvim: Change grouping" })
  end

  -- Show full task info in split
  vim.keymap.set("n", "gf", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    local out, ok = run(
      string.format("task rc.bulk=0 rc.confirmation=off %s info", short_uuid)
    )
    if not ok or out == "" then
      vim.notify("task.nvim: info failed", vim.log.levels.ERROR)
      return
    end
    local detail_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[detail_buf].buftype = "nofile"
    set_buf_lines(detail_buf, out)
    vim.bo[detail_buf].modifiable = false
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, detail_buf)
  end, opts)
end

local function setup_buf_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("TaskNvim_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    group = group,
    callback = function()
      M._on_write(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    group = group,
    callback = function()
      vim.wo[0].conceallevel = 3
      vim.wo[0].concealcursor = "nvic"
    end,
  })

  -- Protect header line: if user edits line 1 (the <!-- taskmd ... --> comment),
  -- restore it on the next TextChanged event. The cached header lives on the
  -- buffer (vim.b) so :TaskFilter/:TaskSort/:TaskRefresh can update it when
  -- they re-render; otherwise a stale closure would revert the new header on
  -- the next edit.
  vim.b[bufnr].taskmd_header_cache = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = bufnr,
    group = group,
    callback = function()
      local cached = vim.b[bufnr].taskmd_header_cache or ""
      local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
      if first_line ~= cached and cached:match("^<!%-%-.*taskmd") then
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { cached })
        vim.notify("task.nvim: header is read-only (use :TaskFilter to change filter)", vim.log.levels.WARN)
      end
    end,
  })

  -- Update header cache when buffer is refreshed (filter/sort/group changes)
  vim.api.nvim_create_autocmd("User", {
    pattern = "TaskNvimRefresh",
    group = group,
    callback = function()
      header_cache = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    end,
  })

  -- Cursor clamping: keep cursor before the UUID comment region.
  --
  -- Only clamp on HORIZONTAL motions (same row as previous CursorMoved). On
  -- vertical motions (j/k/G/gg/<C-d>/etc.) the cursor lands wherever vim
  -- decided based on curswant — clamping there resets curswant to the clamped
  -- column, which causes the very next j/k to snap to that column and makes
  -- it feel like j "doesn't work" after a row where the cursor was near the
  -- concealed UUID region (especially after $ or across blank/group lines).
  local config = require("task.config")
  if config.options.clamp_cursor then
    vim.b[bufnr].taskmd_last_row = nil
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      group = group,
      callback = function()
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local prev_row = vim.b[bufnr].taskmd_last_row
        vim.b[bufnr].taskmd_last_row = row
        -- Row changed → vertical motion. Record and return; do not touch the
        -- cursor, so curswant is preserved for subsequent j/k.
        if prev_row ~= row then return end
        local line = vim.api.nvim_get_current_line()
        local uuid_start = line:find(" <!%-%- uuid:")
        if uuid_start and col >= uuid_start - 1 then
          vim.api.nvim_win_set_cursor(0, { row, uuid_start - 2 })
        end
      end,
    })
  end
end

-- ---------------------------------------------------------------------------
-- Write handler
-- ---------------------------------------------------------------------------

-- Apply helper: runs Lua backend if configured, else shells to bin/taskmd.
-- Returns (result_table, error_string_or_nil).
local function do_apply(opts)
  -- opts: { content=str, tmpfile=str, dry_run=bool, on_delete=str, force=bool }
  local config = require("task.config")
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "task.taskmd")
    if ok_m then
      local ok_a, result = pcall(tm.apply, {
        content = opts.content,
        file = opts.tmpfile,
        dry_run = opts.dry_run,
        on_delete = opts.on_delete,
        force = opts.force,
      })
      if ok_a and type(result) == "table" then return result, nil end
      vim.notify("task.nvim: Lua backend apply failed (" .. tostring(result) .. "); falling back to Python",
        vim.log.levels.WARN)
    end
  end
  local taskmd = get_taskmd_path()
  local flags = {}
  if opts.dry_run then table.insert(flags, "--dry-run") end
  if opts.force then table.insert(flags, "--force") end
  table.insert(flags, "--on-delete=" .. (opts.on_delete or "done"))
  local cmd = string.format("%s apply %s %s",
    taskmd, table.concat(flags, " "), vim.fn.shellescape(opts.tmpfile))
  local out, ok = run(cmd)
  if not ok then return nil, out end
  local ok2, decoded = pcall(vim.fn.json_decode, out)
  if not ok2 or type(decoded) ~= "table" then return nil, "could not parse output" end
  return decoded, nil
end

function M._on_write(bufnr)
  local config = require("task.config")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(lines, tmpfile)

  local on_delete = config.options.on_delete or "done"

  if config.options.confirm then
    local decoded, err = do_apply({
      tmpfile = tmpfile,
      dry_run = true,
      on_delete = on_delete,
    })
    if not decoded then
      vim.notify("task.nvim: dry-run failed\n" .. (err or ""), vim.log.levels.ERROR)
      vim.fn.delete(tmpfile)
      return
    end

    local actions = decoded.actions or {}
    if #actions == 0 then
      vim.notify("task.nvim: no changes")
      vim.bo[bufnr].modified = false
      vim.fn.delete(tmpfile)
      return
    end

    local labels = {}
    for _, action in ipairs(actions) do
      local desc = action.description or (action.fields and action.fields.description) or ""
      if action.type == "add" then
        table.insert(labels, string.format("+ Add: %q", desc))
      elseif action.type == "modify" then
        local parts = {}
        for k, v in pairs(action.fields or {}) do
          table.insert(parts, string.format("%s -> %s", k, tostring(v)))
        end
        table.insert(labels, string.format("~ Modify: %q (%s)", desc, table.concat(parts, ", ")))
      elseif action.type == "done" then
        table.insert(labels, string.format("v Done: %q", desc))
      elseif action.type == "delete" then
        table.insert(labels, string.format("x Delete: %q", desc))
      end
    end

    local preview = table.concat(labels, "\n")
    vim.ui.select({ "Apply", "Cancel" }, {
      prompt = string.format("Apply %d change(s)?\n%s", #actions, preview),
    }, function(choice)
      if choice ~= "Apply" then
        vim.notify("task.nvim: cancelled")
        vim.fn.delete(tmpfile)
        return
      end
      M._do_apply(bufnr, tmpfile, on_delete)
    end)
  else
    M._do_apply(bufnr, tmpfile, on_delete)
  end
end

function M._do_apply(bufnr, tmpfile, on_delete)
  local summary, err = do_apply({
    tmpfile = tmpfile,
    on_delete = on_delete,
  })
  vim.fn.delete(tmpfile)
  if not summary then
    vim.notify("task.nvim: apply failed\n" .. (err or ""), vim.log.levels.ERROR)
    return
  end
  vim.b[bufnr].task_last_action_count = summary.action_count or 0
  local msg = string.format(
    "Applied: +%d added, ~%d modified, v%d done",
    summary.added or 0,
    summary.modified or 0,
    summary.completed or 0
  )
  if (summary.deleted or 0) > 0 then
    msg = msg .. string.format(", x%d deleted", summary.deleted)
  end
  if summary.errors and #summary.errors > 0 then
    msg = msg .. string.format(" (%d errors!)", #summary.errors)
    vim.notify(msg, vim.log.levels.WARN)
  else
    vim.notify(msg)
  end

  refresh_buf(bufnr)
  vim.bo[bufnr].modified = false
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

M.get_taskmd_path = get_taskmd_path

function M.open(filter_str)
  ensure_setup()
  local config = require("task.config")
  filter_str = filter_str or ""

  -- Auto-detect project filter from cwd when no filter is given
  if filter_str == "" then
    local project = detect_project()
    if project then
      filter_str = "project:" .. project
    end
  end

  local sort = config.options.sort or "urgency-"
  local group = config.options.group

  -- Reuse existing task buffer with same filter
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter == filter_str then
      vim.api.nvim_win_set_buf(0, b)
      vim.wo[0].conceallevel = 3
      vim.wo[0].concealcursor = "nvic"
      refresh_buf(b)
      return
    end
  end

  local out = render(filter_str, sort, group)
  if not out then return end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "taskmd"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"

  set_buf_lines(bufnr, out)
  vim.bo[bufnr].modified = false

  vim.b[bufnr].task_filter = filter_str
  vim.b[bufnr].task_sort = sort
  vim.b[bufnr].task_group = group

  setup_buf_syntax(bufnr)
  setup_buf_keymaps(bufnr)
  setup_buf_autocmds(bufnr)
  apply_virtual_text(bufnr)

  vim.api.nvim_win_set_buf(0, bufnr)
  vim.wo[0].conceallevel = 3
  vim.wo[0].concealcursor = "nvic"

  -- Set name safely — wipe stale buffer with same name if needed
  local buf_name = "Tasks: " .. filter_str
  local ok = pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
  if not ok then
    local stale = vim.fn.bufnr(buf_name)
    if stale ~= -1 and stale ~= bufnr then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
      pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
    end
  end
end

function M.filter(filter_str)
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].task_filter then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_filter = filter_str or ""
  refresh_buf(bufnr)
end

function M.refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].task_filter then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  refresh_buf(bufnr)
end

function M.undo()
  local bufnr = vim.api.nvim_get_current_buf()
  local count = vim.b[bufnr].task_last_action_count
  if not count or count == 0 then
    vim.notify("task.nvim: nothing to undo")
    return
  end

  vim.ui.select({ "Undo", "Cancel" }, {
    prompt = string.format("Undo %d action(s) from last save?", count),
  }, function(choice)
    if choice ~= "Undo" then return end

    local failed = 0
    for _ = 1, count do
      local _, ok = run("task rc.bulk=0 rc.confirmation=off undo")
      if not ok then failed = failed + 1 end
    end

    vim.b[bufnr].task_last_action_count = nil

    if failed > 0 then
      vim.notify(string.format("task.nvim: undo completed (%d failed)", failed), vim.log.levels.WARN)
    else
      vim.notify(string.format("task.nvim: undid %d action(s)", count))
    end

    refresh_buf(bufnr)
  end)
end

function M.sort(sort_spec)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_sort = sort_spec or "urgency-"
  refresh_buf(bufnr)
end

function M.group(group_field)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_group = (group_field and group_field ~= "none" and group_field ~= "") and group_field or nil
  refresh_buf(bufnr)
end

function M.project_add(name)
  local cwd = vim.fn.getcwd()
  name = name or vim.fn.fnamemodify(cwd, ":t")
  local projects = load_projects()
  projects[cwd] = name
  save_projects(projects)
  vim.notify(string.format("task.nvim: project '%s' → %s", name, cwd))
end

function M.project_remove()
  local cwd = vim.fn.getcwd()
  local projects = load_projects()
  if projects[cwd] then
    local name = projects[cwd]
    projects[cwd] = nil
    save_projects(projects)
    vim.notify(string.format("task.nvim: removed project '%s' from %s", name, cwd))
  else
    vim.notify("task.nvim: no project registered for " .. cwd, vim.log.levels.WARN)
  end
end

function M.project_list()
  local config = require("task.config")
  local saved = load_projects()
  local all = vim.tbl_extend("keep", config.options.projects or {}, saved)
  if vim.tbl_isempty(all) then
    vim.notify("task.nvim: no projects registered")
    return
  end
  local lines = { "task.nvim projects:" }
  for dir, name in pairs(all) do
    table.insert(lines, string.format("  %s → %s", name, dir))
  end
  vim.notify(table.concat(lines, "\n"))
end

-- Detect project for the current cwd (public API)
M.detect_project = detect_project

function M.delegate()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_get_current_line()
  local short_uuid = uuid_from_line(line)
  if not short_uuid then
    vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
    return
  end

  local out, ok = run(
    string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", short_uuid))
  if not ok or not out or out == "" then
    vim.notify("task.nvim: failed to export task", vim.log.levels.ERROR)
    return
  end

  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end

  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" or #tasks == 0 then
    vim.notify("task.nvim: failed to parse task", vim.log.levels.ERROR)
    return
  end

  local task = tasks[1]
  return task, short_uuid
end

-- ---------------------------------------------------------------------------
-- TaskDelegate — popup form + interactive terminal
-- ---------------------------------------------------------------------------

-- Format a single task block for inclusion in a multi-task prompt.
local function format_task_block(info, index, total)
  local task = info.task
  local short = info.short_uuid
  local uuid = task.uuid or short
  local desc = task.description or "unknown"
  local project = task.project or ""
  local tags = task.tags or {}
  local due = task.due or ""
  local priority = task.priority or ""
  local annotations = task.annotations or {}

  local lines = { string.format("=== Task %d/%d ===", index, total) }
  table.insert(lines, string.format("Short UUID: %s", short))
  table.insert(lines, string.format("Full UUID:  %s", uuid))
  table.insert(lines, string.format("Description: %s", desc))
  if project ~= "" then table.insert(lines, string.format("Project: %s", project)) end
  if priority ~= "" then table.insert(lines, string.format("Priority: %s", priority)) end
  if due ~= "" then table.insert(lines, string.format("Due: %s", due)) end
  if #tags > 0 then table.insert(lines, string.format("Tags: +%s", table.concat(tags, " +"))) end
  if #annotations > 0 then
    table.insert(lines, "Existing annotations:")
    for _, a in ipairs(annotations) do
      table.insert(lines, string.format("  - %s", (a.description or ""):gsub("\n", " ")))
    end
  end
  return table.concat(lines, "\n")
end

-- Build the full prompt text. `task_infos` is a list of
-- { task = <export_dict>, short_uuid = <8-char> }.
local function build_task_prompt(task_infos, extra_context)
  local n = #task_infos
  local p = {}
  local function add(s) table.insert(p, s) end

  add(string.format("You have been delegated %d task%s from Taskwarrior via task.nvim.",
    n, n == 1 and "" or "s"))
  add("")
  add("# How the user watches your progress")
  add("")
  add("The user sees Taskwarrior annotations, not this terminal. Annotate OFTEN")
  add("(every 3-5 minutes of real work) so progress is visible. Use these exact")
  add("annotation prefixes so the user can filter for them:")
  add("")
  add("  START     — your plan, posted before you begin the task")
  add("  PROGRESS  — what you just finished, posted along the way")
  add("  OUTPUT    — absolute path of any file you produced")
  add("  BLOCKED   — why you stopped (use only if you cannot finish)")
  add("  COMPLETE  — 1-sentence summary, posted once the task is finished")
  add("")
  add("# Protocol for every task below")
  add("")
  add("  1. Mark it active and post your plan:")
  add("       task <short_uuid> start")
  add("       task <short_uuid> annotate \"START: <1-2 sentence plan>\"")
  add("  2. Work, annotating milestones:")
  add("       task <short_uuid> annotate \"PROGRESS: <what you just did>\"")
  add("  3. Record any files you created:")
  add("       task <short_uuid> annotate \"OUTPUT: </abs/path>\"")
  add("  4. Finish with a completion annotation AND mark the task done:")
  add("       task <short_uuid> annotate \"COMPLETE: <1-sentence summary>\"")
  add("       task <short_uuid> done")
  add("  5. If you genuinely cannot finish, leave it pending and annotate why:")
  add("       task <short_uuid> annotate \"BLOCKED: <why>\"")
  add("       task <short_uuid> stop")
  add("")
  add("Do not skip annotations. The user's only view into your progress is the")
  add("annotation feed — silence looks like the delegation failed.")
  add("")

  for i, info in ipairs(task_infos) do
    add(format_task_block(info, i, n))
    add("")
  end

  if extra_context and extra_context ~= "" then
    add("# Additional context from the user")
    add("")
    add(extra_context)
    add("")
  end

  add("# Completion signal")
  add("")
  add("When you are finished with ALL tasks above (or have marked any unfinishable")
  add("ones as BLOCKED), print the following banner verbatim on its own lines so")
  add("the user can spot it at a glance in the terminal:")
  add("")
  add("    ==================================================")
  add(string.format("    [TASKDELEGATE COMPLETE] %d task(s) processed", n))
  add("    ==================================================")

  return table.concat(p, "\n")
end

-- Back-compat wrapper used internally; takes a single (task, short_uuid) pair.
local function build_task_context(task, short_uuid, extra_context)
  return build_task_prompt({ { task = task, short_uuid = short_uuid } }, extra_context)
end

local function run_claude_in_terminal(prompt, opts)
  local cfg = require("task.config").options.delegate or {}
  local command = opts.command or cfg.command or "claude"
  local flags = opts.flags or cfg.flags or ""
  local system_prompt_file = opts.system_prompt_file or cfg.system_prompt_file
  local model = opts.model or cfg.model
  local height_frac = cfg.height or 0.5

  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(vim.split(prompt, "\n", { plain = true }), tmpfile)

  -- Build the argv. Interactive mode (no -p) keeps claude's TUI attached to
  -- the terminal so the user can follow up. The prompt is passed as a
  -- positional argument via command substitution from a tmpfile (handles
  -- newlines / shell metacharacters safely).
  local parts = { command }
  if flags and flags ~= "" then table.insert(parts, flags) end
  if model and model ~= "" then
    table.insert(parts, string.format("--model %s", vim.fn.shellescape(model)))
  end
  if system_prompt_file and system_prompt_file ~= "" then
    table.insert(parts, string.format("--append-system-prompt \"$(cat %s)\"",
      vim.fn.shellescape(vim.fn.expand(system_prompt_file))))
  end

  -- Pass the prompt as the first user turn via positional argument (not
  -- stdin — claude refuses to start its TUI if stdin isn't a TTY). After
  -- claude exits, keep the pane alive so the user can read its output.
  local shell_cmd = string.format(
    "%s \"$(cat %s)\"; rc=$?; rm -f %s; echo; echo \"[TaskDelegate] claude exited ($rc). Press any key to close.\"; read -n 1",
    table.concat(parts, " "),
    vim.fn.shellescape(tmpfile),
    vim.fn.shellescape(tmpfile))

  local height = math.floor(vim.o.lines * height_frac)
  vim.cmd(string.format("botright %dnew", height))
  local term_buf = vim.api.nvim_get_current_buf()
  vim.bo[term_buf].bufhidden = "wipe"
  vim.fn.termopen(shell_cmd, {
    on_exit = function()
      vim.schedule(function() vim.notify("TaskDelegate: session ended") end)
    end,
  })
  vim.cmd("startinsert")
end

-- Collect tasks for delegation. Returns a list of { task, short_uuid }. When
-- `range` is nil, returns just the task under the cursor. When `range` is
-- {line1, line2}, returns every task line in that range that has a UUID.
function M.delegate_collect(range)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return nil
  end

  local short_uuids = {}
  if range then
    local lines = vim.api.nvim_buf_get_lines(bufnr, range[1] - 1, range[2], false)
    for _, line in ipairs(lines) do
      local u = uuid_from_line(line)
      if u then table.insert(short_uuids, u) end
    end
  else
    local u = uuid_from_line(vim.api.nvim_get_current_line())
    if u then table.insert(short_uuids, u) end
  end

  if #short_uuids == 0 then
    vim.notify("task.nvim: no task UUID on cursor/range", vim.log.levels.WARN)
    return nil
  end

  local filter = table.concat(short_uuids, " ")
  local out, ok = run(
    string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", filter))
  if not ok or not out or out == "" then
    vim.notify("task.nvim: failed to export tasks", vim.log.levels.ERROR)
    return nil
  end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" or #tasks == 0 then
    vim.notify("task.nvim: failed to parse tasks", vim.log.levels.ERROR)
    return nil
  end

  -- Preserve the order in which short_uuids appeared in the buffer.
  local by_short = {}
  for _, t in ipairs(tasks) do
    if t.uuid then by_short[t.uuid:sub(1, 8)] = t end
  end
  local result = {}
  for _, s in ipairs(short_uuids) do
    local t = by_short[s]
    if t then table.insert(result, { task = t, short_uuid = s }) end
  end
  return result
end

-- Build the exact shell command that would launch claude with the given
-- prompt, honoring the current config + per-invocation overrides.
local function build_claude_command(prompt, opts)
  opts = opts or {}
  local cfg = require("task.config").options.delegate or {}
  local command = opts.command or cfg.command or "claude"
  local flags = opts.flags or cfg.flags or ""
  local system_prompt_file = opts.system_prompt_file or cfg.system_prompt_file
  local model = opts.model or cfg.model

  local parts = { command }
  if flags and flags ~= "" then table.insert(parts, flags) end
  if model and model ~= "" then
    table.insert(parts, string.format("--model %s", vim.fn.shellescape(model)))
  end
  if system_prompt_file and system_prompt_file ~= "" then
    table.insert(parts, string.format("--append-system-prompt \"$(cat %s)\"",
      vim.fn.shellescape(vim.fn.expand(system_prompt_file))))
  end
  return string.format("%s %s", table.concat(parts, " "), vim.fn.shellescape(prompt))
end

-- :TaskDelegate copy | copy-command
-- Builds the prompt (or command) for the task under cursor OR the selected
-- range, copies it to both `+` and `"` registers, and reports byte count.
function M.delegate_copy(mode, opts)
  opts = opts or {}
  local infos = M.delegate_collect(opts.range)
  if not infos then return end

  local prompt = build_task_prompt(infos, opts.extra_context or "")
  local payload, label
  if mode == "command" then
    payload = build_claude_command(prompt, opts)
    label = "command"
  else
    payload = prompt
    label = "prompt"
  end

  pcall(vim.fn.setreg, "+", payload)
  pcall(vim.fn.setreg, '"', payload)
  vim.notify(string.format(
    "task.nvim: copied %s (%d bytes, %d task%s) to + register",
    label, #payload, #infos, #infos == 1 and "" or "s"))
  return payload
end

-- Open a floating popup to collect extra context + flags before launching claude.
-- opts.range = { line1, line2 } for multi-task (visual-range) delegation.
function M.delegate_open_popup(opts)
  opts = opts or {}
  local infos = M.delegate_collect(opts.range)
  if not infos then return end

  local cfg = require("task.config").options.delegate or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local initial_lines = {
    "## Extra context",
    "",
    "",
    "",
    "## Flags",
    string.format("flags: %s", cfg.flags or ""),
    string.format("model: %s", cfg.model or ""),
    string.format("system-prompt-file: %s", cfg.system_prompt_file or ""),
    "",
    "Press <CR> or :w to launch claude.  Press q or <Esc> to cancel.",
    "",
    "---",
  }
  if #infos == 1 then
    table.insert(initial_lines, string.format("Task: %s", infos[1].task.description or "unknown"))
    table.insert(initial_lines, string.format("UUID: %s", infos[1].task.uuid or infos[1].short_uuid))
  else
    table.insert(initial_lines, string.format("Delegating %d tasks:", #infos))
    for _, info in ipairs(infos) do
      table.insert(initial_lines, string.format("  [%s] %s",
        info.short_uuid, (info.task.description or ""):sub(1, 60)))
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

  local width = math.min(80, math.floor(vim.o.columns * 0.7))
  local height = math.min(#initial_lines + 4, math.floor(vim.o.lines * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = (require("task.config").options.border_style or "rounded"),
    title = #infos > 1
      and string.format(" TaskDelegate (%d tasks) ", #infos)
      or " TaskDelegate ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.cmd("startinsert")

  local function parse_form()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local extra = {}
    local flags_line, model_line, spf_line
    local section = "header"
    for _, l in ipairs(lines) do
      if l:match("^## Extra context") then
        section = "extra"
      elseif l:match("^## Flags") then
        section = "flags"
      elseif section == "extra" then
        table.insert(extra, l)
      elseif section == "flags" then
        local f = l:match("^flags:%s*(.*)")
        local m = l:match("^model:%s*(.*)")
        local s = l:match("^system%-prompt%-file:%s*(.*)")
        if f then flags_line = f end
        if m then model_line = m end
        if s then spf_line = s end
      end
    end
    while extra[1] == "" do table.remove(extra, 1) end
    while extra[#extra] == "" do table.remove(extra) end
    return {
      extra_context = table.concat(extra, "\n"),
      flags = flags_line,
      model = model_line,
      system_prompt_file = spf_line,
    }
  end

  local function submit()
    local form = parse_form()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    local prompt = build_task_prompt(infos, form.extra_context)
    run_claude_in_terminal(prompt, {
      flags = form.flags,
      model = form.model,
      system_prompt_file = form.system_prompt_file,
    })
  end

  local function cancel()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    vim.notify("TaskDelegate: cancelled")
  end

  vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, nowait = true, silent = true })
  vim.api.nvim_buf_create_user_command(buf, "W", submit, {})
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
end

-- ---------------------------------------------------------------------------
-- TaskStart / TaskStop — toggle active (start) state on the task under cursor
-- ---------------------------------------------------------------------------

function M.start_stop(which)
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_get_current_line()
  local short_uuid = uuid_from_line(line)
  if not short_uuid then
    vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
    return
  end
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off %s %s", short_uuid, which)
  local _, ok = run(cmd)
  if ok then
    vim.notify(string.format("task.nvim: %s %s", which, short_uuid))
    if vim.b[bufnr].task_filter ~= nil then refresh_buf(bufnr) end
  else
    vim.notify(string.format("task.nvim: %s failed", which), vim.log.levels.ERROR)
  end
end

-- ---------------------------------------------------------------------------
-- Saved views (:TaskSave / :TaskLoad)
-- ---------------------------------------------------------------------------

local function views_file_path()
  local data_dir = vim.fn.stdpath("data") .. "/task.nvim"
  vim.fn.mkdir(data_dir, "p")
  return data_dir .. "/saved-views.json"
end

local function read_saved_views()
  local path = views_file_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or not content or #content == 0 then return {} end
  local joined = table.concat(content, "\n")
  local parsed_ok, data = pcall(vim.fn.json_decode, joined)
  if not parsed_ok or type(data) ~= "table" then return {} end
  return data
end

local function write_saved_views(data)
  local path = views_file_path()
  local encoded = vim.fn.json_encode(data)
  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
end

function M.view_list_names()
  local data = read_saved_views()
  local names = {}
  for k, _ in pairs(data) do table.insert(names, k) end
  table.sort(names)
  return names
end

function M.view_save(name)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  local function finish(chosen)
    if not chosen or chosen == "" then return end
    local views = read_saved_views()
    views[chosen] = {
      filter = vim.b[bufnr].task_filter or "",
      sort = vim.b[bufnr].task_sort or "",
      group = vim.b[bufnr].task_group or "",
    }
    write_saved_views(views)
    vim.notify(string.format("task.nvim: saved view %q", chosen))
  end
  if name then finish(name) else
    vim.ui.input({ prompt = "Save view as: " }, finish)
  end
end

function M.view_load(name)
  local function finish(chosen)
    if not chosen or chosen == "" then return end
    local views = read_saved_views()
    local v = views[chosen]
    if not v then
      vim.notify(string.format("task.nvim: no saved view %q", chosen), vim.log.levels.WARN)
      return
    end
    M.open(v.filter or "")
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.b[bufnr].task_filter ~= nil then
      if v.sort and v.sort ~= "" then vim.b[bufnr].task_sort = v.sort end
      if v.group and v.group ~= "" then vim.b[bufnr].task_group = v.group end
      refresh_buf(bufnr)
    end
    vim.notify(string.format("task.nvim: loaded view %q", chosen))
  end
  if name then
    finish(name)
  else
    local names = M.view_list_names()
    if #names == 0 then
      vim.notify("task.nvim: no saved views", vim.log.levels.WARN)
      return
    end
    vim.ui.select(names, { prompt = "Load view:" }, finish)
  end
end

-- ---------------------------------------------------------------------------
-- Guided review mode (:TaskReview)
-- ---------------------------------------------------------------------------

function M.review()
  local out, ok = run(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on status:pending export")
  if not ok or not out or out == "" then
    vim.notify("task.nvim: failed to export tasks", vim.log.levels.ERROR)
    return
  end
  local js = out
  local s = js:find("%[")
  if s and s > 1 then js = js:sub(s) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, js)
  if not parsed_ok or type(tasks) ~= "table" or #tasks == 0 then
    vim.notify("task.nvim: no pending tasks", vim.log.levels.INFO)
    return
  end
  -- Sort by urgency desc for review order
  table.sort(tasks, function(a, b) return (a.urgency or 0) > (b.urgency or 0) end)

  local idx = 1
  local function step()
    if idx > #tasks then
      vim.notify(string.format("task.nvim: review complete (%d tasks)", #tasks))
      return
    end
    local t = tasks[idx]
    local short = t.uuid and t.uuid:sub(1, 8) or ""
    local lines = {
      string.format("[%d/%d]  %s", idx, #tasks, t.description or ""),
      string.format("project:%s  urgency:%.1f", t.project or "(none)", t.urgency or 0),
    }
    if t.due then table.insert(lines, string.format("due:%s", t.due)) end
    if t.tags and #t.tags > 0 then table.insert(lines, "tags:" .. table.concat(t.tags, ",")) end
    local header = table.concat(lines, "\n") .. "\n"
    local choices = {
      "k  Keep (next)",
      "d  Defer (set wait:tomorrow)",
      "x  Done",
      "m  Modify (prompt)",
      "g  Go to task buffer",
      "q  Quit review",
    }
    vim.ui.select(choices, {
      prompt = header .. "Action:",
      format_item = function(i) return i end,
    }, function(choice)
      if not choice then return end
      local key = choice:sub(1, 1)
      if key == "k" then
        idx = idx + 1; step()
      elseif key == "d" then
        run(string.format("task rc.bulk=0 rc.confirmation=off %s modify wait:tomorrow", short))
        idx = idx + 1; step()
      elseif key == "x" then
        run(string.format("task rc.bulk=0 rc.confirmation=off %s done", short))
        idx = idx + 1; step()
      elseif key == "m" then
        vim.ui.input({ prompt = "Modify " .. short .. ": " }, function(input)
          if input and input ~= "" then
            local esc = input:gsub("'", "'\\''")
            run(string.format("task rc.bulk=0 rc.confirmation=off %s modify '%s'", short, esc))
          end
          idx = idx + 1; step()
        end)
      elseif key == "g" then
        M.open("uuid:" .. short)
      elseif key == "q" then
        vim.notify(string.format("task.nvim: review paused at %d/%d", idx, #tasks))
      end
    end)
  end
  step()
end

function M.help()
  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[help_buf].buftype = "nofile"
  vim.bo[help_buf].filetype = "markdown"
  set_buf_lines(help_buf, HELP_TEXT)
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

function M.capture()
  ensure_setup()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "taskmd"

  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor(vim.o.lines / 2) - 1,
    style = "minimal",
    border = "rounded",
    title = " Task Add ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.cmd("startinsert")

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd("stopinsert")
  end

  vim.keymap.set("i", "<CR>", function()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    close()
    if line and line ~= "" then
      -- Write to temp file and use taskmd apply to avoid shell escaping issues
      -- with special characters (dashes, parens, plus signs, etc.)
      local escaped = line:gsub("'", "'\\''")
      local _, ok = run("task rc.bulk=0 rc.confirmation=off add -- '" .. escaped .. "'")
      if ok then
        vim.notify("task.nvim: added task")
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].task_filter ~= nil and vim.api.nvim_buf_is_valid(b) then
            refresh_buf(b)
          end
        end
      else
        vim.notify("task.nvim: add failed", vim.log.levels.ERROR)
      end
    end
  end, { buffer = buf })

  vim.keymap.set("i", "<Esc>", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf })
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

function M._setup_commands()
  vim.api.nvim_create_user_command("Task", function(cmd_opts)
    M.open(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Open Taskwarrior tasks as markdown",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  vim.api.nvim_create_user_command("TaskFilter", function(cmd_opts)
    M.filter(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Change task filter",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  vim.api.nvim_create_user_command("TaskRefresh", function()
    M.refresh()
  end, { nargs = 0, desc = "Refresh task buffer" })

  vim.api.nvim_create_user_command("TaskUndo", function()
    M.undo()
  end, { nargs = 0, desc = "Undo last save" })

  vim.api.nvim_create_user_command("TaskSort", function(cmd_opts)
    M.sort(cmd_opts.args)
  end, {
    nargs = 1,
    desc = "Change task sort order (e.g. due+, urgency-)",
    complete = function(arg_lead)
      local fields = { "urgency-", "urgency+", "due+", "due-", "priority-",
                       "priority+", "project+", "project-", "description+" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  vim.api.nvim_create_user_command("TaskGroup", function(cmd_opts)
    M.group(cmd_opts.args)
  end, {
    nargs = "?",
    desc = "Change task grouping (field name or 'none')",
    complete = function(arg_lead)
      local fields = { "project", "priority", "status", "tag", "none" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  vim.api.nvim_create_user_command("TaskAdd", function()
    M.capture()
  end, { nargs = 0, desc = "Quick-capture a new task" })

  vim.api.nvim_create_user_command("TaskHelp", function()
    M.help()
  end, { nargs = 0, desc = "Show task.nvim help" })

  vim.api.nvim_create_user_command("TaskProjectAdd", function(cmd_opts)
    local name = cmd_opts.args ~= "" and cmd_opts.args or nil
    M.project_add(name)
  end, { nargs = "?", desc = "Register cwd as a Taskwarrior project" })

  vim.api.nvim_create_user_command("TaskProjectRemove", function()
    M.project_remove()
  end, { nargs = 0, desc = "Unregister cwd as a Taskwarrior project" })

  vim.api.nvim_create_user_command("TaskProjectList", function()
    M.project_list()
  end, { nargs = 0, desc = "List registered projects" })

  vim.api.nvim_create_user_command("TaskDelegate", function(cmd_opts)
    local arg = cmd_opts.args or ""
    local has_range = cmd_opts.range > 0 and cmd_opts.line1 ~= cmd_opts.line2
    local range = has_range and { cmd_opts.line1, cmd_opts.line2 } or nil
    if arg == "copy" then
      return M.delegate_copy("prompt", { range = range })
    elseif arg == "copy-command" then
      return M.delegate_copy("command", { range = range })
    else
      return M.delegate_open_popup({ range = range })
    end
  end, {
    nargs = "?",
    range = true,
    desc = "Delegate task(s) under cursor or selection to Claude",
    complete = function() return { "copy", "copy-command" } end,
  })

  vim.api.nvim_create_user_command("TaskStart", function()
    M.start_stop("start")
  end, { nargs = 0, desc = "Start (activate) task under cursor" })

  vim.api.nvim_create_user_command("TaskStop", function()
    M.start_stop("stop")
  end, { nargs = 0, desc = "Stop (deactivate) task under cursor" })

  vim.api.nvim_create_user_command("TaskSave", function(cmd_opts)
    M.view_save(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, { nargs = "?", desc = "Save current filter/sort/group as a named view" })

  vim.api.nvim_create_user_command("TaskLoad", function(cmd_opts)
    M.view_load(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, {
    nargs = "?",
    desc = "Load a saved view by name",
    complete = function(arg_lead)
      local names = M.view_list_names()
      local r = {}
      for _, n in ipairs(names) do
        if n:sub(1, #arg_lead) == arg_lead then table.insert(r, n) end
      end
      return r
    end,
  })

  vim.api.nvim_create_user_command("TaskReview", function()
    M.review()
  end, { nargs = 0, desc = "Walk through pending tasks one at a time" })

  vim.api.nvim_create_user_command("TaskDiffPreview", function(cmd_opts)
    local dp = require("task.diff_preview")
    local a = cmd_opts.args
    if a == "on" then dp.enable()
    elseif a == "off" then dp.disable()
    else dp.toggle() end
  end, {
    nargs = "?",
    desc = "Toggle live diff preview (virtual text)",
    complete = function() return { "on", "off", "toggle" } end,
  })

  -- Visualization commands
  local views = require("task.views")

  vim.api.nvim_create_user_command("TaskBurndown", function()
    views.burndown()
  end, { nargs = 0, desc = "Show burndown chart" })

  vim.api.nvim_create_user_command("TaskTree", function()
    views.tree()
  end, { nargs = 0, desc = "Show dependency tree" })

  vim.api.nvim_create_user_command("TaskSummary", function()
    views.summary()
  end, { nargs = 0, desc = "Show project summary" })

  vim.api.nvim_create_user_command("TaskCalendar", function()
    views.calendar()
  end, { nargs = 0, desc = "Show calendar view of due dates" })

  vim.api.nvim_create_user_command("TaskTags", function()
    views.tags()
  end, { nargs = 0, desc = "Show tag distribution" })
end

-- ---------------------------------------------------------------------------
-- Lua API (for other plugins)
-- ---------------------------------------------------------------------------

-- Completion functions exposed for vim.fn.input() completion callbacks
-- Signature: (ArgLead, CmdLine, CursorPos) -> list of strings
function M._complete_filter(arg_lead, cmd_line, _cursor_pos)
  -- cmd_line contains the full input; arg_lead is the word under cursor
  -- For multi-word filters, complete the last word
  local words = vim.split(cmd_line, "%s+")
  local last = words[#words] or ""
  return complete_filter(last)
end

function M._complete_sort(arg_lead, _cmd_line, _cursor_pos)
  local fields = { "urgency-", "urgency+", "due+", "due-", "priority-",
                   "priority+", "project+", "project-", "description+" }
  local results = {}
  for _, f in ipairs(fields) do
    if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
  end
  return results
end

function M._complete_group(arg_lead, _cmd_line, _cursor_pos)
  local fields = { "project", "priority", "status", "tag", "none" }
  local results = {}
  for _, f in ipairs(fields) do
    if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
  end
  return results
end

M.api = {}

M.api.export = function(filter_args)
  filter_args = filter_args or {}
  local filter_str = type(filter_args) == "table" and table.concat(filter_args, " ") or filter_args
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export",
    filter_str)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return {} end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return {} end
  return tasks
end

M.api.get_task_on_cursor = function()
  local line = vim.api.nvim_get_current_line()
  local short_uuid = uuid_from_line(line)
  if not short_uuid then return nil end
  local tasks = M.api.export({ short_uuid })
  return tasks[1]
end

M.api.detect_project = detect_project
M.api.get_completions = get_tw_completions
M.api.refresh = function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].task_filter ~= nil and vim.api.nvim_buf_is_valid(b) then
      refresh_buf(b)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  require("task.config").setup(opts)

  local config = require("task.config")
  local gopts = { noremap = true, silent = true }

  -- Global keymaps
  if config.options.capture_key then
    vim.keymap.set("n", config.options.capture_key, M.capture,
      vim.tbl_extend("force", gopts, { desc = "task.nvim: Quick-capture task" }))
  end

  if config.options.open_key then
    vim.keymap.set("n", config.options.open_key, function() M.open() end,
      vim.tbl_extend("force", gopts, { desc = "task.nvim: Open tasks" }))
  end

  if config.options.project_add_key then
    vim.keymap.set("n", config.options.project_add_key, function()
      vim.ui.input({
        prompt = "Project name: ",
        default = vim.fn.fnamemodify(vim.fn.getcwd(), ":t"),
      }, function(name)
        if name and name ~= "" then M.project_add(name) end
      end)
    end, vim.tbl_extend("force", gopts, { desc = "task.nvim: Register cwd as project" }))
  end

  M._setup_commands()
end

return M
