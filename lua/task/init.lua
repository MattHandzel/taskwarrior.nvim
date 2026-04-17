local M = {}

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

-- Auto-setup guard
local function ensure_setup()
  local config = require("task.config")
  if not next(config.options) then M.setup({}) end
end

local function detect_project()    return require("task.projects").detect() end
local function get_tw_completions() return require("task.completion").get_tw_completions() end
local function complete_filter(a)  return require("task.completion").complete_filter(a) end
local function set_buf_lines(b, t) require("task.buffer").set_buf_lines(b, t) end
local function refresh_buf(b)      require("task.buffer").refresh_buf(b) end

function M._on_write(bufnr)
  require("task.apply").on_write(bufnr, refresh_buf, M._do_apply)
end

function M._do_apply(bufnr, tmpfile, on_delete)
  require("task.apply").do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_buf)
end

M.get_taskmd_path = get_taskmd_path

function M.open(filter_str)
  ensure_setup()
  require("task.buffer").open_task_buf(filter_str, M._on_write, detect_project)
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
  require("task.apply").undo(bufnr, refresh_buf)
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

M.detect_project = detect_project

function M.delegate()
  return require("task.delegate").delegate_one()
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

function M.view_list_names()
  return require("task.saved_views").list_names()
end

function M.view_save(name)
  require("task.saved_views").save(name)
end

function M.view_load(name)
  require("task.saved_views").load(name, M.open, refresh_buf)
end

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

-- Omnifunc bridge — capture buffer sets omnifunc to a v:lua expression that
-- needs this method on the top-level require("task") module.
function M._capture_omnifunc(findstart, base)
  return require("task.capture").omnifunc(findstart, base)
end

function M._setup_commands()
  require("task.commands").setup(M, complete_filter)
end

-- Completion callbacks (ArgLead, CmdLine, CursorPos) -> list of strings
function M._complete_filter(arg_lead, cmd_line, _cursor_pos)
  local words = vim.split(cmd_line, "%s+")
  return complete_filter(words[#words] or "")
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
