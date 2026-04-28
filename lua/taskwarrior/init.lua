local M = {}

local function get_taskmd_path()
  local config = require("taskwarrior.config")
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
  local config = require("taskwarrior.config")
  if not next(config.options) then M.setup({}) end
end

local function detect_project()    return require("taskwarrior.projects").detect() end
local function get_tw_completions() return require("taskwarrior.completion").get_tw_completions() end
local function complete_filter(a)  return require("taskwarrior.completion").complete_filter(a) end
local function set_buf_lines(b, t) require("taskwarrior.buffer").set_buf_lines(b, t) end
local function refresh_buf(b)      require("taskwarrior.buffer").refresh_buf(b) end

function M._on_write(bufnr)
  require("taskwarrior.apply").on_write(bufnr, refresh_buf, M._do_apply)
end

function M._do_apply(bufnr, tmpfile, on_delete, opts)
  require("taskwarrior.apply").do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_buf, opts)
end

M.get_taskmd_path = get_taskmd_path

function M.open(filter_str)
  ensure_setup()
  require("taskwarrior.buffer").open_task_buf(filter_str, M._on_write, detect_project)
end

function M.filter(filter_str)
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].task_filter then
    vim.notify("taskwarrior.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_filter = filter_str or ""
  refresh_buf(bufnr)
end

function M.refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].task_filter then
    vim.notify("taskwarrior.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  refresh_buf(bufnr)
end

function M.undo()
  local bufnr = vim.api.nvim_get_current_buf()
  require("taskwarrior.apply").undo(bufnr, refresh_buf)
end

function M.sort(sort_spec)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("taskwarrior.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_sort = sort_spec or "urgency-"
  refresh_buf(bufnr)
end

function M.group(group_field)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("taskwarrior.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_group = (group_field and group_field ~= "none" and group_field ~= "") and group_field or nil
  refresh_buf(bufnr)
end

function M.project_add(name)
  require("taskwarrior.projects").add(name)
end

function M.project_remove()
  require("taskwarrior.projects").remove()
end

function M.project_list()
  require("taskwarrior.projects").list()
end

M.detect_project = detect_project

function M.delegate()
  return require("taskwarrior.delegate").delegate_one()
end

function M.delegate_collect(range)
  return require("taskwarrior.delegate").collect(range)
end

function M.delegate_copy(mode, opts)
  return require("taskwarrior.delegate").copy(mode, opts)
end

function M.delegate_open_popup(opts)
  return require("taskwarrior.delegate").open_popup(opts)
end

function M.start_stop(which)
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_get_current_line()
  local short_uuid = uuid_from_line(line)
  if not short_uuid then
    vim.notify("taskwarrior.nvim: no UUID on this line", vim.log.levels.WARN)
    return
  end
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off %s %s", short_uuid, which)
  local _, ok = run(cmd)
  if ok then
    vim.notify(string.format("taskwarrior.nvim: %s %s", which, short_uuid))
    if vim.b[bufnr].task_filter ~= nil then refresh_buf(bufnr) end
  else
    vim.notify(string.format("taskwarrior.nvim: %s failed", which), vim.log.levels.ERROR)
  end
end

function M.view_list_names()
  return require("taskwarrior.saved_views").list_names()
end

function M.view_save(name)
  require("taskwarrior.saved_views").save(name)
end

function M.view_load(name)
  require("taskwarrior.saved_views").load(name, M.open, refresh_buf)
end

function M.review()
  require("taskwarrior.review").run(M.open)
end

function M.help()
  require("taskwarrior.help").show(set_buf_lines)
end

function M.capture()
  ensure_setup()
  require("taskwarrior.capture").open(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[b].task_filter ~= nil and vim.api.nvim_buf_is_valid(b) then
        refresh_buf(b)
      end
    end
  end)
end

-- -------------------------------------------------------------------------
-- Task-level modify operations (module thin-forward; see modify.lua).
-- -------------------------------------------------------------------------

function M.append(text)      require("taskwarrior.modify").append(text)   end
function M.prepend(text)     require("taskwarrior.modify").prepend(text)  end
function M.duplicate()       require("taskwarrior.modify").duplicate()    end
function M.purge(filter)     require("taskwarrior.modify").purge(filter)  end
function M.denotate()        require("taskwarrior.modify").denotate()     end
function M.modify_project()  require("taskwarrior.modify").modify_project()  end
function M.modify_priority() require("taskwarrior.modify").modify_priority() end
function M.modify_due()      require("taskwarrior.modify").modify_due()      end
function M.modify_tag()      require("taskwarrior.modify").modify_tag()      end

function M.modify_field_by_name(field)
  require("taskwarrior.modify").modify_field_by_name(field)
end

function M.bulk_modify(range, spec)
  require("taskwarrior.bulk").modify(range, spec)
end

function M.report(name)      require("taskwarrior.report").open(name, M.open) end
function M.report_names()    return require("taskwarrior.report").names() end
function M.float()           require("taskwarrior.buffer").open_float() end
function M.graph()           require("taskwarrior.graph").open() end
function M.inbox()           require("taskwarrior.inbox").run() end
function M.export(path)      require("taskwarrior.export").write(path) end
function M.sync()            require("taskwarrior.sync").run() end

-- Omnifunc bridge — capture buffer sets omnifunc to a v:lua expression that
-- needs this method on the top-level require("taskwarrior") module.
function M._capture_omnifunc(findstart, base)
  return require("taskwarrior.capture").omnifunc(findstart, base)
end

function M._setup_commands()
  require("taskwarrior.commands").setup(M, complete_filter)
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
  require("taskwarrior.config").setup(opts)

  local config = require("taskwarrior.config")
  local gopts = { noremap = true, silent = true }

  -- Global keymaps
  if config.options.capture_key then
    vim.keymap.set("n", config.options.capture_key, M.capture,
      vim.tbl_extend("force", gopts, { desc = "taskwarrior.nvim: Quick-capture task" }))
  end

  if config.options.open_key then
    vim.keymap.set("n", config.options.open_key, function() M.open() end,
      vim.tbl_extend("force", gopts, { desc = "taskwarrior.nvim: Open tasks" }))
  end

  if config.options.project_add_key then
    vim.keymap.set("n", config.options.project_add_key, function()
      vim.ui.input({
        prompt = "Project name: ",
        default = vim.fn.fnamemodify(vim.fn.getcwd(), ":t"),
      }, function(name)
        if name and name ~= "" then M.project_add(name) end
      end)
    end, vim.tbl_extend("force", gopts, { desc = "taskwarrior.nvim: Register cwd as project" }))
  end

  M._setup_commands()

  -- Optional: auto-stop running Taskwarrior timers after N ms idle.
  pcall(function() require("taskwarrior.granulation").setup() end)

  -- Refresh embedded `<!-- taskmd query: ... -->` blocks inside markdown
  -- buffers on read/write. Completely passive — only affects markdown files
  -- that contain at least one block.
  pcall(function() require("taskwarrior.query_blocks").setup() end)
end

return M
