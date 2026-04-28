-- taskwarrior/bulk.lua — :TaskBulkModify. Apply the same `task modify SPEC`
-- to every task line in a visual/line range. Each UUID is modified in its
-- own subprocess so taskwarrior's bulk-confirmation prompt is sidestepped
-- entirely (rc.bulk=0 + one invocation per task).

local M = {}

local function uuid_from_line(line)
  return line:match("<!%-%-.*uuid:([0-9a-fA-F]+).*%-%->")
end

local function run(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error == 0
end

-- range: { line1, line2 } (1-based, inclusive)
-- spec:  the modify spec, e.g. "+triage project:inbox"
function M.modify(range, spec)
  if not spec or spec == "" then
    require("taskwarrior.notify")("warn",
      "taskwarrior.nvim: TaskBulkModify needs a modify spec",
      vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local l1, l2 = range[1] or 1, range[2] or 1
  if l2 < l1 then l1, l2 = l2, l1 end
  local lines = vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false)

  local uuids = {}
  for _, line in ipairs(lines) do
    local u = uuid_from_line(line)
    if u then table.insert(uuids, u) end
  end
  if #uuids == 0 then
    require("taskwarrior.notify")("warn",
      "taskwarrior.nvim: no tasks in selection", vim.log.levels.WARN)
    return
  end

  local failed = 0
  for _, u in ipairs(uuids) do
    local _, ok = run(string.format(
      "task rc.bulk=0 rc.confirmation=off %s modify %s", u, spec))
    if not ok then failed = failed + 1 end
  end
  local msg = string.format("taskwarrior.nvim: modified %d task%s",
    #uuids - failed, (#uuids - failed) ~= 1 and "s" or "")
  if failed > 0 then msg = msg .. " (" .. failed .. " failed)" end
  require("taskwarrior.notify")("modify", msg)

  if vim.b[bufnr].task_filter ~= nil then
    pcall(function() require("taskwarrior.buffer").refresh_buf(bufnr) end)
  end
end

return M
