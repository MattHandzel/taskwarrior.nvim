-- Statusline component for taskwarrior.nvim.
-- Usage (lualine):
--   require("lualine").setup({ sections = { lualine_x = {
--     require("taskwarrior.statusline").component
--   } } })
-- Or raw:
--   vim.o.statusline = '%!v:lua.require("taskwarrior.statusline").render()'

local M = {}

local _cache = { text = "", expires_at = 0 }
local CACHE_SECS = 15

local function now()
  return vim.loop.now() / 1000
end

local function compute()
  local today = os.date("!%Y-%m-%d")
  local out = vim.fn.system(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on status:pending export")
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local ok, tasks = pcall(vim.fn.json_decode, out)
  if not ok or type(tasks) ~= "table" then return "" end

  local overdue = 0
  local next_due, next_due_date, next_desc
  local active
  for _, t in ipairs(tasks) do
    if t.start then active = t end
    if t.due then
      local ymd = t.due:sub(1, 4) .. "-" .. t.due:sub(5, 6) .. "-" .. t.due:sub(7, 8)
      if ymd < today then
        overdue = overdue + 1
      elseif not next_due or ymd < next_due_date then
        next_due = t
        next_due_date = ymd
        next_desc = t.description
      end
    end
  end

  local parts = {}
  if active then
    table.insert(parts, string.format("▶ %s", (active.description or ""):sub(1, 24)))
  end
  if overdue > 0 then
    table.insert(parts, string.format("%d overdue", overdue))
  end
  if next_due_date then
    local desc = (next_desc or ""):sub(1, 20)
    table.insert(parts, string.format("next %s: %s", next_due_date, desc))
  end
  if #parts == 0 then return "" end
  return "task: " .. table.concat(parts, " · ")
end

function M.render()
  local t = now()
  if _cache.expires_at > t then return _cache.text end
  _cache.text = compute() or ""
  _cache.expires_at = t + CACHE_SECS
  return _cache.text
end

function M.invalidate()
  _cache.expires_at = 0
end

-- lualine-compatible component
M.component = M.render

return M
