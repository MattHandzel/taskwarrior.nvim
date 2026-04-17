local M = {}

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
-- Project detection + persistence (delegated to task.projects)
-- ---------------------------------------------------------------------------

local function detect_project()
  return require("task.projects").detect()
end

-- ---------------------------------------------------------------------------
-- Tab completion helpers (delegated to task.completion)
-- ---------------------------------------------------------------------------

local function get_tw_completions()
  return require("task.completion").get_tw_completions()
end

local function complete_filter(arg_lead)
  return require("task.completion").complete_filter(arg_lead)
end

-- ---------------------------------------------------------------------------
-- Buffer module delegation (render, set_buf_lines, refresh_buf, syntax,
-- keymaps, autocmds — see lua/task/buffer.lua)
-- ---------------------------------------------------------------------------

local function set_buf_lines(bufnr, text)
  require("task.buffer").set_buf_lines(bufnr, text)
end

local function refresh_buf(bufnr)
  require("task.buffer").refresh_buf(bufnr)
end

local function update_highlights(bufnr)
  require("task.buffer").update_highlights(bufnr)
end

local function apply_virtual_text(bufnr)
  require("task.buffer").apply_virtual_text(bufnr)
end

local function setup_buf_syntax(bufnr)
  require("task.buffer").setup_buf_syntax(bufnr)
end

local function setup_buf_keymaps(bufnr)
  require("task.buffer").setup_buf_keymaps(bufnr)
end

local function setup_buf_autocmds(bufnr)
  require("task.buffer").setup_buf_autocmds(bufnr, M._on_write)
end

-- ---------------------------------------------------------------------------
-- Write handler (delegated to task.apply)
-- ---------------------------------------------------------------------------

function M._on_write(bufnr)
  require("task.apply").on_write(bufnr, refresh_buf, M._do_apply)
end

function M._do_apply(bufnr, tmpfile, on_delete)
  require("task.apply").do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_buf)
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
  require("task.projects").add(name)
end

function M.project_remove()
  require("task.projects").remove()
end

function M.project_list()
  require("task.projects").list()
end

-- Detect project for the current cwd (public API)
M.detect_project = detect_project

-- ---------------------------------------------------------------------------
-- Delegate (delegated to task.delegate)
-- ---------------------------------------------------------------------------

function M.delegate()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_get_current_line()
  local short_uuid = line:match("<!%-%-.*uuid:([0-9a-fA-F]+).*%-%->")
  if not short_uuid then
    vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
    return
  end
  local out, ok = run("task rc.bulk=0 rc.confirmation=off rc.json.array=on " .. short_uuid .. " export")
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
  return tasks[1], short_uuid
end

function M.delegate_collect(range)
  return require("task.delegate").collect(range)
end

function M.delegate_copy(mode, opts)
  return require("task.delegate").copy(mode, opts)
end

function M.delegate_open_popup(opts)
  return require("task.delegate").open_popup(opts)
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
  require("task.review").run(M.open)
end

function M.help()
  require("task.help").show(set_buf_lines)
end

function M.capture()
  ensure_setup()
  require("task.capture").open(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[b].task_filter ~= nil and vim.api.nvim_buf_is_valid(b) then
        refresh_buf(b)
      end
    end
  end)
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
