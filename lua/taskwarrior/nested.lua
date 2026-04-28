-- taskwarrior/nested.lua — treat indented `- [ ]` children of a task line as
-- `depends:` of the parent.
--
-- The full "automatically wire up depends: from markdown indentation at save
-- time" approach would require the parser and diff layer to carry indentation
-- as a first-class semantic axis, which is a large change. This module
-- implements the user-invoked version:
--
--   :TaskLinkChildren   → scan the buffer for indented task lines directly
--                         underneath the task on the cursor, add depends:
--                         CHILD_UUID to the parent for each, and refresh.
--
-- :TaskUnlinkChildren does the inverse, removing depends entries that point
-- at the direct children.

local M = {}

local function run(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error == 0
end

local function uuid_from_line(line)
  return line:match("<!%-%-.*uuid:([0-9a-fA-F]+).*%-%->")
end

-- Return the leading-whitespace width of a line (measured in columns where a
-- tab counts as 1 — consistent with the way vim reports indent).
local function indent_of(line)
  local lead = line:match("^(%s*)") or ""
  return #lead
end

-- Collect the children of the cursor task: contiguous `- [ ]`/`- [x]`/`- [>]`
-- lines with strictly greater indent than the parent, stopping at the first
-- sibling (same indent) or non-task line.
local function collect_children()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parent_line = all[row]
  if not parent_line then return nil, {} end
  local parent_uuid = uuid_from_line(parent_line)
  if not parent_uuid then return nil, {} end
  local parent_indent = indent_of(parent_line)

  local children = {}
  for i = row + 1, #all do
    local line = all[i]
    if not line:match("^%s*%- %[[ x>]%]") then break end
    local ind = indent_of(line)
    if ind <= parent_indent then break end
    local uuid = uuid_from_line(line)
    if uuid then table.insert(children, uuid) end
  end
  return parent_uuid, children
end

function M.link_children()
  local notify = require("taskwarrior.notify")
  local parent, children = collect_children()
  if not parent then
    notify("warn", "taskwarrior.nvim: cursor is not on a task", vim.log.levels.WARN)
    return
  end
  if #children == 0 then
    notify("warn", "taskwarrior.nvim: no indented children", vim.log.levels.WARN)
    return
  end
  local depends = table.concat(children, ",")
  local _, ok = run(string.format(
    "task rc.bulk=0 rc.confirmation=off %s modify depends:%s", parent, depends))
  if ok then
    notify("modify", string.format(
      "taskwarrior.nvim: linked %d child task%s → %s",
      #children, #children > 1 and "s" or "", parent:sub(1, 8)))
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.b[bufnr].task_filter ~= nil then
      pcall(function() require("taskwarrior.buffer").refresh_buf(bufnr) end)
    end
  else
    notify("error", "taskwarrior.nvim: link failed", vim.log.levels.ERROR)
  end
end

function M.unlink_children()
  local notify = require("taskwarrior.notify")
  local parent, children = collect_children()
  if not parent then
    notify("warn", "taskwarrior.nvim: cursor is not on a task", vim.log.levels.WARN)
    return
  end
  if #children == 0 then return end
  -- TW's remove-dependency syntax requires `-` on EACH UUID:
  --   depends:-uuid1,-uuid2   (remove both)
  --   depends:-uuid1,uuid2    (remove uuid1, ADD uuid2 — NOT what we want)
  local minus = {}
  for _, uuid in ipairs(children) do
    table.insert(minus, "-" .. uuid)
  end
  local _, ok = run(string.format(
    "task rc.bulk=0 rc.confirmation=off %s modify depends:%s",
    parent, table.concat(minus, ",")))
  if ok then
    notify("modify", "taskwarrior.nvim: unlinked children")
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.b[bufnr].task_filter ~= nil then
      pcall(function() require("taskwarrior.buffer").refresh_buf(bufnr) end)
    end
  end
end

return M
