-- taskwarrior/query_blocks.lua — embed live Taskwarrior queries inside
-- arbitrary markdown buffers.
--
-- Syntax (designed to be invisible in rendered markdown):
--
--   <!-- taskmd query: FILTER_EXPRESSION -->
--   - [ ] foo  <!-- uuid:abc12345 -->
--   - [ ] bar  <!-- uuid:def67890 -->
--   <!-- taskmd endquery -->
--
-- On open / :TaskQueryRefresh, every block is re-rendered using the
-- taskwarrior.taskmd backend. The filter can include sort/group via `|` eg:
--
--   <!-- taskmd query: status:pending +urgent | sort:due+ | group:project -->
--
-- The block body is replaced between the open and close comments. Content
-- outside the blocks is untouched, so notes, prose, and multiple blocks per
-- buffer all work.
--
-- Mutations inside the block (checking a box, editing a description) are NOT
-- auto-applied to Taskwarrior — the blocks are currently read-only mirrors.
-- Users who want write-through should open `:Task <filter>` instead.

local M = {}

local OPEN_PAT  = "^%s*<!%-%-%s*taskmd%s+query:%s*(.-)%s*%-%->%s*$"
local CLOSE_PAT = "^%s*<!%-%-%s*taskmd%s+endquery%s*%-%->%s*$"

-- Parse `FILTER | sort:X | group:Y` into { filter, sort, group }.
local function parse_spec(raw)
  local parts = {}
  for p in (raw .. "|"):gmatch("([^|]*)|") do
    table.insert(parts, (p:gsub("^%s+", ""):gsub("%s+$", "")))
  end
  local out = { filter = parts[1] or "", sort = nil, group = nil }
  for i = 2, #parts do
    local key, val = parts[i]:match("^(%w+)%s*:%s*(.+)$")
    if key == "sort" then out.sort = val end
    if key == "group" then out.group = val end
  end
  return out
end

-- Render the tasks for a spec to a list of lines. Uses the Lua taskmd backend
-- directly so the format matches :Task buffers.
local function render_block(spec)
  local config = require("taskwarrior.config")
  local ok, tm = pcall(require, "taskwarrior.taskmd")
  if not ok then return { "<!-- taskmd backend unavailable -->" } end
  local filter_args = {}
  if spec.filter and spec.filter ~= "" then
    for w in spec.filter:gmatch("%S+") do table.insert(filter_args, w) end
  end
  local ok_r, out = pcall(tm.render, {
    filter = filter_args,
    sort = spec.sort or config.options.sort or "urgency-",
    group = spec.group or nil,
    fields = config.options.fields,
    urgency_coefficients = config.options.urgency_coefficients,
    urgency_value_mappers = config.options.urgency_value_mappers,
  })
  if not ok_r or type(out) ~= "string" then
    return { "<!-- taskmd query render failed -->" }
  end
  -- Strip the generated header comment (callers already see the block anchor).
  local lines = {}
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^<!%-%-.*taskmd") then
      table.insert(lines, line)
    end
  end
  -- Trim trailing blank lines for tidy diffs.
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

-- Scan a buffer for query blocks. Returns a list of
--   { open_line, close_line, spec }
-- with 0-based line numbers suitable for nvim_buf_set_lines.
function M.find_blocks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local open_idx, open_spec
  for i, line in ipairs(lines) do
    if open_idx == nil then
      local raw = line:match(OPEN_PAT)
      if raw then
        open_idx = i
        open_spec = parse_spec(raw)
      end
    else
      if line:match(CLOSE_PAT) then
        table.insert(blocks, {
          open_line = open_idx - 1,
          close_line = i - 1,
          spec = open_spec,
        })
        open_idx, open_spec = nil, nil
      end
    end
  end
  return blocks
end

-- Refresh all query blocks in `bufnr` (defaults to current buffer).
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local blocks = M.find_blocks(bufnr)
  -- Walk in reverse so earlier line numbers stay valid after replacements.
  table.sort(blocks, function(a, b) return a.open_line > b.open_line end)

  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  for _, block in ipairs(blocks) do
    local body = render_block(block.spec)
    vim.api.nvim_buf_set_lines(bufnr,
      block.open_line + 1, block.close_line, false, body)
  end
  vim.bo[bufnr].modifiable = was_modifiable
end

-- Refresh every open buffer that has at least one query block.
function M.refresh_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      local blocks = M.find_blocks(b)
      if #blocks > 0 then M.refresh(b) end
    end
  end
end

-- Wire autocmds: refresh on BufRead of any markdown buffer, and expose a
-- :TaskQueryRefresh user command.
function M.setup()
  local grp = vim.api.nvim_create_augroup("TaskwarriorQueryBlocks", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = grp,
    pattern = { "*.md", "*.markdown" },
    callback = function(args) M.refresh(args.buf) end,
  })
  vim.api.nvim_create_user_command("TaskQueryRefresh", function()
    M.refresh()
  end, { nargs = 0, desc = "Refresh embedded taskmd query blocks in this buffer" })
end

return M
