-- nvim-cmp completion source for task.nvim.
-- Usage:
--   require("cmp").register_source("task", require("task.cmp").new())
--
-- Triggers on these contexts inside task.nvim buffers (filetype=taskmd):
--   - `project:` → completes registered project names
--   - `+`        → completes known tag names
--   - bare word  → completes field names (project:, priority:, due:, etc.)

local source = {}

local KNOWN_FIELDS = {
  "project:", "priority:", "due:", "scheduled:", "recur:",
  "wait:", "until:", "effort:", "depends:",
}

local PRIORITY_VALUES = { "H", "M", "L" }

local _cache = { projects = nil, tags = nil, udas = nil, mtime = 0 }

local function refresh_cache()
  -- Cheap: only re-fetch every 10s
  local now = vim.loop.now() / 1000
  if _cache.mtime + 10 > now and _cache.projects then return end
  _cache.mtime = now
  local function lines(cmd)
    local out = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then return {} end
    local r = {}
    for _, l in ipairs(out) do
      l = l:gsub("%s+$", "")
      if l ~= "" then table.insert(r, l) end
    end
    return r
  end
  _cache.projects = lines("task _projects 2>/dev/null")
  _cache.tags = lines("task _tags 2>/dev/null")
  _cache.udas = lines("task _udas 2>/dev/null")
end

function source.new()
  refresh_cache()
  return setmetatable({}, { __index = source })
end

function source:is_available()
  return vim.bo.filetype == "taskmd"
end

function source:get_trigger_characters()
  return { ":", "+" }
end

function source:complete(params, callback)
  refresh_cache()
  local line = params.context.cursor_before_line or ""
  local items = {}

  -- After `project:` → complete project names
  local proj_prefix = line:match("project:(%S*)$")
  if proj_prefix ~= nil then
    for _, p in ipairs(_cache.projects or {}) do
      if p:sub(1, #proj_prefix) == proj_prefix then
        table.insert(items, { label = p, kind = 9 }) -- Module
      end
    end
    return callback({ items = items, isIncomplete = false })
  end

  -- After `priority:` → complete H/M/L
  local prio_prefix = line:match("priority:(%S*)$")
  if prio_prefix ~= nil then
    for _, p in ipairs(PRIORITY_VALUES) do
      if p:sub(1, #prio_prefix) == prio_prefix then
        table.insert(items, { label = p, kind = 20 }) -- EnumMember
      end
    end
    return callback({ items = items, isIncomplete = false })
  end

  -- After `+` → complete tag names (but not inside a word, which would be
  -- something like "housing+food" where we do NOT want to suggest tags)
  local tag_prefix = line:match("([%+])([%w_-]*)$")
  if tag_prefix then
    local last_col = #line - #tag_prefix
    local prev_char = last_col > 0 and line:sub(last_col, last_col) or ""
    if prev_char == "" or prev_char:match("[%s]") then
      local prefix = line:match("%+([%w_-]*)$") or ""
      for _, t in ipairs(_cache.tags or {}) do
        if t:sub(1, #prefix) == prefix then
          table.insert(items, { label = "+" .. t, insertText = t, kind = 14 }) -- Keyword
        end
      end
      return callback({ items = items, isIncomplete = false })
    end
  end

  -- Otherwise suggest field names. Match a bare prefix at cursor.
  local word_prefix = line:match("(%w+)$") or ""
  for _, f in ipairs(KNOWN_FIELDS) do
    if f:sub(1, #word_prefix) == word_prefix then
      table.insert(items, { label = f, kind = 5 }) -- Field
    end
  end
  -- Also offer UDA fields (e.g. utility:, effort_minutes:)
  for _, u in ipairs(_cache.udas or {}) do
    local lbl = u .. ":"
    if lbl:sub(1, #word_prefix) == word_prefix then
      table.insert(items, { label = lbl, kind = 5 })
    end
  end
  return callback({ items = items, isIncomplete = false })
end

return source
