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

function M.get_tw_completions()
  local config = require("taskwarrior.config")
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "taskwarrior.taskmd")
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

function M.complete_filter(arg_lead)
  local completions = M.get_tw_completions()
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

return M
