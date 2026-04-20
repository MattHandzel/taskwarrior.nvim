-- taskmd.lua — pure-Lua port of the bin/taskmd Python CLI.
--
-- This module implements the markdown↔Taskwarrior bridge in Lua, so the
-- neovim plugin can operate with no Python dependency. It is a line-for-line
-- port of bin/taskmd so behavior matches the Python tests.
--
-- Public API (mirrors the Python module):
--   M.tw_date_to_human(val)           M.human_date_to_tw(val)
--   M.format_effort(val)              M.parse_effort(val)
--   M.parse_task_line(line, extra)    M.serialize_task_line(task, opts)
--   M.compute_diff(parsed, base, opts)
--   M.parse_group_context(lines, parsed)
--   M.tw_export(filter_args)          M.tw_add / modify / done / delete / start / stop
--   M.tw_udas()                       M.tw_completions()
--   M.render(args)                    M.apply(content, args)
--   M.KNOWN_FIELDS, M.LIST_FIELDS, M.DATE_FIELDS

local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

M.KNOWN_FIELDS = { "project", "priority", "due", "scheduled", "recur", "wait", "until", "effort", "depends" }
M.LIST_FIELDS = { depends = true }
M.DATE_FIELDS = { due = true, scheduled = true, wait = true, ["until"] = true }

local KNOWN_FIELDS = M.KNOWN_FIELDS
local LIST_FIELDS = M.LIST_FIELDS
local DATE_FIELDS = M.DATE_FIELDS

local BASE_RC = { "rc.bulk=0", "rc.confirmation=off" }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

local function list_to_set(list)
  local s = {}
  for _, x in ipairs(list) do s[x] = true end
  return s
end

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sorted_keys(t)
  local keys = {}
  for k, _ in pairs(t) do table.insert(keys, k) end
  table.sort(keys)
  return keys
end

local function is_list(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

-- ---------------------------------------------------------------------------
-- Date / effort formatting (mirrors Python functions by the same name)
-- ---------------------------------------------------------------------------

-- TW's ISO format: 20260322T134834Z
function M.tw_date_to_human(val)
  if type(val) ~= "string" then return val end
  if val:match("^%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ$") then
    return string.format("%s-%s-%s", val:sub(1, 4), val:sub(5, 6), val:sub(7, 8))
  end
  return val
end

function M.human_date_to_tw(val)
  if type(val) ~= "string" then return val end
  if val:match("^%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ$") then return val end
  local y, mo, d = val:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then return string.format("%s%s%sT000000Z", y, mo, d) end
  return val
end

function M.format_effort(val)
  if type(val) ~= "string" then val = tostring(val) end
  if not val:match("^[Pp][Tt]") then return val end
  -- Extract each component independently; anchor to the suffix letter so a
  -- bare `PT30M` doesn't wrongly see `30` as an hour value due to greedy
  -- %d* backtracking into the H slot.
  local H = val:match("^[Pp][Tt](%d+)[Hh]")
  local M_ = val:match("[Hh](%d+)[Mm]") or val:match("^[Pp][Tt](%d+)[Mm]")
  local S = val:match("[Mm](%d+)[Ss]")
            or val:match("[Hh](%d+)[Ss]")
            or val:match("^[Pp][Tt](%d+)[Ss]")
  if not (H or M_ or S) then return val end
  local parts = {}
  if H then parts[#parts + 1] = H .. "h" end
  if M_ then parts[#parts + 1] = M_ .. "m" end
  if S then parts[#parts + 1] = S .. "s" end
  return table.concat(parts)
end

function M.parse_effort(val)
  if type(val) ~= "string" then val = tostring(val) end
  if val:sub(1, 2):upper() == "PT" then return val end
  local H = val:match("^(%d+)[Hh]")
  local M_ = val:match("[Hh](%d+)[Mm]") or val:match("^(%d+)[Mm]")
  local S = val:match("(%d+)[Ss]$")
  if not (H or M_ or S) then return val end
  local r = "PT"
  if H then r = r .. H .. "H" end
  if M_ then r = r .. M_ .. "M" end
  if S then r = r .. S .. "S" end
  return r
end

-- Default value-to-number mappers keyed by field name. Used when the user
-- has not configured `urgency_value_mappers`. Keep this list focused on
-- cases where the TW-native storage format isn't directly numeric.
-- Users can override any entry via `require("taskwarrior").setup{ urgency_value_mappers = {...} }`.
M.DEFAULT_URGENCY_VALUE_MAPPERS = {}

-- Resolves the mapper for a given field, given a (possibly nil) user override.
-- - user_mappers == nil   → use DEFAULT_URGENCY_VALUE_MAPPERS[field] or tonumber
-- - user_mappers ~= nil   → use user_mappers[field] or tonumber (no defaults)
-- This keeps "I didn't set it" (use defaults) distinct from "I set {}" (disable defaults).
function M.resolve_value_mapper(field, user_mappers)
  if user_mappers ~= nil then
    return user_mappers[field] or tonumber
  end
  return M.DEFAULT_URGENCY_VALUE_MAPPERS[field] or tonumber
end

-- Convert an ISO 8601 duration ("PT1H30M", "PT45M", "PT2H") or a plain number
-- to minutes as a number. Returns nil for unparseable input. Registered as
-- the default mapper for the `effort` UDA below; users can override.
function M.effort_to_minutes(val)
  if val == nil then return nil end
  if type(val) == "number" then return val end
  val = tostring(val)
  local n = tonumber(val)
  if n then return n end
  if val:sub(1, 2):upper() ~= "PT" then return nil end
  local H = tonumber(val:match("(%d+)[Hh]") or "") or 0
  local M_ = tonumber(val:match("[Hh](%d+)[Mm]") or val:match("^[Pp][Tt](%d+)[Mm]") or "") or 0
  local S = tonumber(val:match("(%d+)[Ss]") or "") or 0
  if H == 0 and M_ == 0 and S == 0 then return nil end
  return H * 60 + M_ + S / 60
end

-- Register the built-in mapper for `effort`. Users can override via
-- setup{ urgency_value_mappers = { effort = my_function } } — setting
-- to `{}` disables all defaults including this one.
M.DEFAULT_URGENCY_VALUE_MAPPERS.effort = M.effort_to_minutes

-- ---------------------------------------------------------------------------
-- Taskwarrior adapter (subprocess via vim.fn.system)
-- ---------------------------------------------------------------------------

local function run(argv)
  if not vim or not vim.fn then
    error("taskmd.lua requires the vim global (must run inside neovim)")
  end
  local out = vim.fn.system(argv)
  return out, vim.v.shell_error
end

-- Rewrite +tag → tags.has:tag and -tag → tags.hasnt:tag so TW3's expression
-- parser doesn't misparse tags with hyphens.  E.g. +EXP-0011 gets split into
-- (+EXP) minus (0011) by TW3; tags.has:EXP-0011 is unambiguous.
local function normalize_tag_filters(args)
  local out = {}
  for _, arg in ipairs(args or {}) do
    local incl = arg:match("^%+([A-Za-z_][A-Za-z0-9_-]*)$")
    if incl then
      out[#out + 1] = "tags.has:" .. incl
    else
      local excl = arg:match("^%-([A-Za-z_][A-Za-z0-9_-]*)$")
      if excl then
        out[#out + 1] = "tags.hasnt:" .. excl
      else
        out[#out + 1] = arg
      end
    end
  end
  return out
end

-- Disambiguate the `m` suffix on duration literals in filter args. TW3
-- interprets bare `Nm` as N MONTHS, not N minutes — so `effort<10m` matches
-- every task (none are older than 10 months in duration). Rewriting to
-- `10min` makes it mean what users expect.
--
-- Targets: any token of the form `<lhs><op><digits>m` where op is a
-- comparison operator (`<`, `<=`, `>`, `>=`, `=`, or `.<word>:`). Pure tokens
-- like `+10m` (a tag) or `10m` (literal) are left alone.
local function normalize_duration_minutes(args)
  local out = {}
  for _, arg in ipairs(args or {}) do
    local rewritten = arg:gsub(
      "^([%w_]+)(<=?)(%d+%.?%d*)m$",
      function(field, op, num) return field .. op .. num .. "min" end
    )
    if rewritten == arg then
      rewritten = arg:gsub(
        "^([%w_]+)(>=?)(%d+%.?%d*)m$",
        function(field, op, num) return field .. op .. num .. "min" end
      )
    end
    if rewritten == arg then
      rewritten = arg:gsub(
        "^([%w_]+)(=)(%d+%.?%d*)m$",
        function(field, op, num) return field .. op .. num .. "min" end
      )
    end
    if rewritten == arg then
      rewritten = arg:gsub(
        "^([%w_]+)(%.[a-z]+:)(%d+%.?%d*)m$",
        function(field, op, num) return field .. op .. num .. "min" end
      )
    end
    out[#out + 1] = rewritten
  end
  return out
end

function M.tw_export(filter_args)
  local argv = { "task" }
  for _, a in ipairs(BASE_RC) do argv[#argv + 1] = a end
  argv[#argv + 1] = "rc.json.array=on"
  for _, a in ipairs(normalize_tag_filters(normalize_duration_minutes(filter_args))) do argv[#argv + 1] = a end
  argv[#argv + 1] = "export"
  local text, rc = run(argv)
  if rc ~= 0 and rc ~= 1 then
    error("task export failed: " .. tostring(text))
  end
  if not text or text == "" then return {} end
  local i = text:find("%[")
  if i and i > 1 then text = text:sub(i) end
  if not i then return {} end
  local ok, parsed = pcall(vim.fn.json_decode, text)
  if not ok or type(parsed) ~= "table" then return {} end
  return parsed
end

local function fields_to_args(fields)
  local args = {}
  for key, val in pairs(fields) do
    if key == "tags" then
      if type(val) == "table" then
        for _, t in ipairs(val) do args[#args + 1] = "+" .. t end
      end
    elseif key == "_removed_tags" then
      if type(val) == "table" then
        for _, t in ipairs(val) do args[#args + 1] = "-" .. t end
      end
    elseif key == "status" then
      -- skip
    elseif val == "" then
      args[#args + 1] = key .. ":"
    elseif DATE_FIELDS[key] then
      args[#args + 1] = key .. ":" .. M.human_date_to_tw(val)
    elseif key == "effort" then
      args[#args + 1] = "effort:" .. M.parse_effort(val)
    elseif LIST_FIELDS[key] then
      if type(val) == "table" then
        args[#args + 1] = key .. ":" .. table.concat(val, ",")
      else
        args[#args + 1] = key .. ":" .. tostring(val)
      end
    else
      args[#args + 1] = key .. ":" .. tostring(val)
    end
  end
  return args
end
M._fields_to_args = fields_to_args

function M.tw_add(desc, fields)
  local argv = { "task" }
  for _, a in ipairs(BASE_RC) do argv[#argv + 1] = a end
  argv[#argv + 1] = "add"
  argv[#argv + 1] = "description:" .. desc
  for _, a in ipairs(fields_to_args(fields or {})) do argv[#argv + 1] = a end
  local out, _ = run(argv)
  local uuid = (out or ""):match("[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+")
  return uuid or ""
end

function M.tw_modify(uuid, fields)
  fields = deep_copy(fields or {})
  local desc = fields.description
  fields.description = nil
  local parts = fields_to_args(fields)
  if desc ~= nil then parts[#parts + 1] = "description:" .. desc end
  if #parts == 0 then return end
  local argv = { "task" }
  for _, a in ipairs(BASE_RC) do argv[#argv + 1] = a end
  argv[#argv + 1] = uuid
  argv[#argv + 1] = "modify"
  for _, a in ipairs(parts) do argv[#argv + 1] = a end
  run(argv)
end

local function simple_tw(verb)
  return function(uuid)
    local argv = { "task" }
    for _, a in ipairs(BASE_RC) do argv[#argv + 1] = a end
    argv[#argv + 1] = uuid
    argv[#argv + 1] = verb
    run(argv)
  end
end

M.tw_done   = simple_tw("done")
M.tw_delete = simple_tw("delete")
M.tw_start  = simple_tw("start")
M.tw_stop   = simple_tw("stop")

function M.tw_udas()
  local out, _ = run({ "task", "_udas" })
  local known = list_to_set(KNOWN_FIELDS)
  known["priority"] = true
  local result = {}
  for line in (out or ""):gmatch("[^\r\n]+") do
    local u = trim(line)
    if u ~= "" and not known[u] then result[#result + 1] = u end
  end
  return result
end

function M.tw_completions()
  local p_out = run({ "task", "_projects" })
  local t_out = run({ "task", "_tags" })
  local function lines(s)
    local out = {}
    for line in (s or ""):gmatch("[^\r\n]+") do
      local v = trim(line)
      if v ~= "" then out[#out + 1] = v end
    end
    return out
  end
  return { projects = lines(p_out), tags = lines(t_out), fields = { unpack(KNOWN_FIELDS) } }
end

-- ---------------------------------------------------------------------------
-- Markdown parser
-- ---------------------------------------------------------------------------

-- All known field names (concat as a lookup set).
local function field_set(extra_fields)
  local s = list_to_set(KNOWN_FIELDS)
  for _, f in ipairs(extra_fields or {}) do s[f] = true end
  return s
end

-- Split `rest` into whitespace-separated tokens (Python's str.split()).
-- Tokenizer that treats `key:"value with spaces"` as a single token. Without
-- this, UDA values containing whitespace get split and the right-to-left
-- metadata scan breaks, causing field text to be mistaken for description
-- and duplicated on round-trip.
local function tokenize(s)
  local tokens = {}
  local i, len = 1, #s
  while i <= len do
    while i <= len and s:sub(i, i):match("%s") do i = i + 1 end
    if i > len then break end
    local start = i
    local in_quotes = false
    while i <= len do
      local c = s:sub(i, i)
      if in_quotes then
        if c == '"' then in_quotes = false end
        i = i + 1
      elseif c:match("%s") then
        break
      elseif c == '"' then
        in_quotes = true
        i = i + 1
      else
        i = i + 1
      end
    end
    tokens[#tokens + 1] = s:sub(start, i - 1)
  end
  return tokens
end

local TASK_LINE_PATTERN = "^%- %[([ >x])%] (.+)$"
local UUID_COMMENT_PATTERN = "<!%-%-%s*uuid:([0-9a-fA-F]+)%s*%-%->"

-- Greedy parse for quick-capture input: extracts known field:value tokens and
-- +tags from ANYWHERE in the line (not just the end), leaving the rest as
-- description. Use this for :TaskAdd where the user may type metadata in the
-- middle of a free-form sentence. Returns (description, fields, tags).
--
-- Safe against false positives because field names are a fixed list. URLs
-- (`https://x`), times (`16:9`), and code fences don't match because their
-- prefix (`https`, `16`, `` ``` ``) isn't in the known-field set.
function M.parse_capture(line, extra_fields)
  if type(line) ~= "string" then return "", {}, {} end
  local known = field_set(extra_fields)
  local tokens = tokenize(line)
  local desc_toks = {}
  local fields = {}
  local tags = {}
  for _, tok in ipairs(tokens) do
    local fname, fval = tok:match('^([%w_]+):"(.-)"$')
    if not fname then
      fname, fval = tok:match("^([%w_]+):(%S+)$")
    end
    local tag_name = tok:match("^%+([%w_%-]+)$")
    if fname and known[fname] and fval and fval ~= "" then
      if DATE_FIELDS[fname] then
        fields[fname] = M.human_date_to_tw(fval)
      elseif fname == "effort" then
        fields[fname] = M.parse_effort(fval)
      elseif LIST_FIELDS[fname] then
        local items = {}
        for item in fval:gmatch("[^,]+") do
          if item ~= "" then items[#items + 1] = item end
        end
        fields[fname] = items
      else
        fields[fname] = fval
      end
    elseif tag_name then
      tags[#tags + 1] = tag_name
    else
      desc_toks[#desc_toks + 1] = tok
    end
  end
  if #tags > 0 then
    local seen, uniq = {}, {}
    for _, t in ipairs(tags) do
      if not seen[t] then seen[t] = true; uniq[#uniq + 1] = t end
    end
    table.sort(uniq)
    fields.tags = uniq
  end
  return table.concat(desc_toks, " "), fields
end

function M.parse_task_line(line, extra_fields)
  if type(line) ~= "string" then return nil end
  local stripped = line:gsub("^%s+", ""):gsub("%s+$", "")
  local status_char, rest = stripped:match(TASK_LINE_PATTERN)
  if not status_char then return nil end

  local status = status_char == "x" and "completed" or "pending"

  local short_uuid
  local uuid_start = rest:find(UUID_COMMENT_PATTERN)
  if uuid_start then
    short_uuid = rest:match(UUID_COMMENT_PATTERN)
    rest = rest:sub(1, uuid_start - 1):gsub("%s+$", "")
  end

  local known = field_set(extra_fields)
  local tokens = tokenize(rest)
  local fields = {}
  local tags = {}
  local desc_end = #tokens + 1  -- Lua is 1-indexed; description is tokens[1..desc_end-1]
  local metadata_positions = {}

  -- Scan right-to-left
  for i = #tokens, 1, -1 do
    local tok = tokens[i]
    -- Match key:"value with spaces" first, then key:value
    local fname, fval = tok:match('^([%w_]+):"(.-)"$')
    if not fname then
      fname, fval = tok:match("^([%w_]+):(%S+)$")
    end
    local tag_name = tok:match("^%+([%w_%-]+)$")
    if fname and known[fname] then
      if DATE_FIELDS[fname] then
        fields[fname] = M.human_date_to_tw(fval)
      elseif fname == "effort" then
        fields[fname] = M.parse_effort(fval)
      elseif LIST_FIELDS[fname] then
        local items = {}
        for item in fval:gmatch("[^,]+") do
          if item ~= "" then items[#items + 1] = item end
        end
        table.sort(items)
        fields[fname] = items
      else
        fields[fname] = fval
      end
      metadata_positions[#metadata_positions + 1] = i
    elseif tag_name then
      tags[#tags + 1] = tag_name
      metadata_positions[#metadata_positions + 1] = i
    else
      break -- stop at first unrecognized token; everything to the left is description
    end
  end

  if #metadata_positions > 0 then
    local min_pos = metadata_positions[1]
    for _, p in ipairs(metadata_positions) do
      if p < min_pos then min_pos = p end
    end
    desc_end = min_pos
  end

  local desc_parts = {}
  for i = 1, desc_end - 1 do desc_parts[#desc_parts + 1] = tokens[i] end
  local description = table.concat(desc_parts, " ")

  if #tags > 0 then
    -- Dedup + sort
    local seen = {}
    local uniq = {}
    for _, t in ipairs(tags) do
      if not seen[t] then seen[t] = true; uniq[#uniq + 1] = t end
    end
    table.sort(uniq)
    fields.tags = uniq
  end

  local task = {
    status = status,
    description = description,
  }
  for k, v in pairs(fields) do task[k] = v end
  if short_uuid then task._short_uuid = short_uuid end
  if status_char == ">" then task._started = true end
  return task
end

-- ---------------------------------------------------------------------------
-- Markdown serializer
-- ---------------------------------------------------------------------------

function M.serialize_task_line(task, opts)
  opts = opts or {}
  local fields_filter = opts.fields_filter    -- list or nil
  local omit_group_field = opts.omit_group_field
  local extra_fields = opts.extra_fields or {}

  local status_char
  if task.status == "completed" then
    status_char = "x"
  elseif task.start then
    status_char = ">"
  else
    status_char = " "
  end
  -- vim.NIL (JSON null) and non-string values must not reach :gsub
  local raw_desc = task.description
  local desc = (type(raw_desc) == "string" and raw_desc or ""):gsub("\n", " "):gsub("\r", "")
  local parts = { desc }

  local filter_set = nil
  if fields_filter then
    filter_set = list_to_set(fields_filter)
  end
  local function include(f)
    if omit_group_field and f == omit_group_field then return false end
    return filter_set == nil or filter_set[f]
  end

  local all_fields = {}
  for _, f in ipairs(KNOWN_FIELDS) do all_fields[#all_fields + 1] = f end
  for _, f in ipairs(extra_fields) do all_fields[#all_fields + 1] = f end

  for _, field in ipairs(all_fields) do
    if task[field] ~= nil and include(field) then
      local val = task[field]
      if DATE_FIELDS[field] then
        val = M.tw_date_to_human(val)
      elseif field == "effort" then
        val = M.format_effort(tostring(val))
      elseif LIST_FIELDS[field] then
        if type(val) == "string" then
          local items = {}
          for item in val:gmatch("[^,]+") do
            if item ~= "" then items[#items + 1] = item end
          end
          val = items
        end
        if type(val) ~= "table" or #val == 0 then
          val = nil
        else
          local sorted_items = { unpack(val) }
          table.sort(sorted_items)
          local shorts = {}
          for _, v in ipairs(sorted_items) do shorts[#shorts + 1] = tostring(v):sub(1, 8) end
          val = table.concat(shorts, ",")
        end
      end
      if val ~= nil then
        local sval = tostring(val)
        -- Quote multi-word values so the parser doesn't misread them as
        -- description. Strip any existing quotes to keep the encoding simple.
        if sval:match("%s") then
          sval = '"' .. sval:gsub('"', "") .. '"'
        end
        parts[#parts + 1] = string.format("%s:%s", field, sval)
      end
    end
  end

  if include("tags") and type(task.tags) == "table" then
    local t = { unpack(task.tags) }
    table.sort(t)
    for _, tag in ipairs(t) do
      parts[#parts + 1] = "+" .. tag
    end
  end

  local line = "- [" .. status_char .. "] " .. table.concat(parts, " ")
  local uuid = task.uuid
  if uuid and uuid ~= "" then
    line = line .. string.format(" <!-- uuid:%s -->", tostring(uuid):sub(1, 8))
  end
  return line
end

-- ---------------------------------------------------------------------------
-- Diff engine
-- ---------------------------------------------------------------------------

local function strip_private(task)
  local out = {}
  for k, v in pairs(task) do
    if not (tostring(k):sub(1, 1) == "_") and k ~= "status" and k ~= "description" then
      out[k] = v
    end
  end
  return out
end

local function values_equal(a, b)
  if a == b then return true end
  if type(a) == "table" and type(b) == "table" then
    if #a ~= #b then return false end
    local sa, sb = { unpack(a) }, { unpack(b) }
    table.sort(sa); table.sort(sb)
    for i = 1, #sa do if tostring(sa[i]) ~= tostring(sb[i]) then return false end end
    return true
  end
  return false
end

function M._normalize_base(base, extra_fields, omit_group_field)
  local line = M.serialize_task_line(base, {
    omit_group_field = omit_group_field,
    extra_fields = extra_fields,
  })
  local parsed = M.parse_task_line(line, extra_fields)
  if parsed == nil then
    return {
      description = (base.description or ""):gsub("\n", " "):gsub("\r", ""),
      status = base.status or "pending",
    }
  end
  if omit_group_field and base[omit_group_field] ~= nil then
    parsed[omit_group_field] = base[omit_group_field]
  end
  return parsed
end

function M.compute_diff(parsed_lines, base_tasks, opts)
  opts = opts or {}
  local on_delete = opts.on_delete or "done"
  local extra_fields = opts.extra_fields or {}
  local omit_group_field = opts.omit_group_field

  local uuid_map = {}
  for _, t in ipairs(base_tasks) do
    if t.uuid then uuid_map[t.uuid] = t end
  end
  local short_to_full = {}
  for full, _ in pairs(uuid_map) do
    short_to_full[tostring(full):sub(1, 8)] = full
  end
  local seen = {}
  local actions = {}

  local normalized = {}
  for uid, base in pairs(uuid_map) do
    normalized[uid] = M._normalize_base(base, extra_fields, omit_group_field)
  end

  for _, lt in ipairs(parsed_lines) do
    local short = lt._short_uuid
    local full_uuid = short and short_to_full[short] or nil

    if full_uuid and seen[full_uuid] then
      -- Duplicate UUID → treat as add
      local clean = strip_private(lt)
      local add_a = { type = "add", description = lt.description or "", fields = clean }
      if lt._started then add_a._post_start = true end
      if lt.status == "completed" then add_a._post_done = true end
      actions[#actions + 1] = add_a
    elseif full_uuid then
      seen[full_uuid] = true
      local base = uuid_map[full_uuid]
      local norm = normalized[full_uuid]
      local task_fields = strip_private(lt)
      local norm_fields = strip_private(norm)

      local new_status = lt.status or "pending"
      local old_status = base.status or "pending"
      local new_started = lt._started and true or false
      local old_started = base.start and true or false

      if new_status == "completed" and old_status == "pending" then
        if old_started then
          actions[#actions + 1] = { type = "stop", uuid = full_uuid, fields = {} }
        end
        actions[#actions + 1] = { type = "done", uuid = full_uuid, fields = {} }
      elseif new_status == "pending" and old_status == "completed" then
        actions[#actions + 1] = { type = "modify", uuid = full_uuid, fields = { status = "pending" } }
      elseif new_status == "pending" and old_status == "pending" then
        if new_started and not old_started then
          actions[#actions + 1] = { type = "start", uuid = full_uuid, fields = {} }
        elseif not new_started and old_started then
          actions[#actions + 1] = { type = "stop", uuid = full_uuid, fields = {} }
        end
      end

      local changed = {}
      local all_field_keys = {}
      local seen_keys = {}
      for k, _ in pairs(task_fields) do
        if not seen_keys[k] then seen_keys[k] = true; all_field_keys[#all_field_keys + 1] = k end
      end
      for k, _ in pairs(norm_fields) do
        if not seen_keys[k] then seen_keys[k] = true; all_field_keys[#all_field_keys + 1] = k end
      end

      for _, field in ipairs(all_field_keys) do
        local user_val = task_fields[field]
        local norm_val = norm_fields[field]
        if not values_equal(user_val, norm_val) then
          if DATE_FIELDS[field] and user_val and norm_val and
             M.tw_date_to_human(tostring(user_val)) == M.tw_date_to_human(tostring(norm_val)) then
            -- equal modulo format
          elseif norm_val == nil and user_val ~= nil then
            changed[field] = user_val
          elseif user_val == nil and norm_val ~= nil then
            if field == "tags" then
              local base_tags = base.tags
              if type(base_tags) == "table" and #base_tags > 0 then
                changed.tags = {}
                changed._removed_tags = { unpack(base_tags) }
              end
            else
              changed[field] = ""
            end
          elseif tostring(user_val) ~= tostring(norm_val) then
            changed[field] = user_val
          end
        end
      end

      local user_desc = lt.description or ""
      local norm_desc = norm.description or ""
      if user_desc ~= norm_desc then
        changed.description = user_desc
      end

      local has_changes = false
      for _ in pairs(changed) do has_changes = true; break end
      if has_changes then
        actions[#actions + 1] = { type = "modify", uuid = full_uuid, fields = changed }
      end
    else
      -- No UUID on this line → new task
      local clean = strip_private(lt)
      local add_a = { type = "add", description = lt.description or "", fields = clean }
      if lt._started then add_a._post_start = true end
      if lt.status == "completed" then add_a._post_done = true end
      actions[#actions + 1] = add_a
    end
  end

  for full_uuid, base in pairs(uuid_map) do
    if not seen[full_uuid] then
      local desc = base.description or ""
      if on_delete == "delete" then
        actions[#actions + 1] = { type = "delete", uuid = full_uuid, description = desc, fields = {} }
      else
        actions[#actions + 1] = { type = "done", uuid = full_uuid, description = desc, fields = {} }
      end
    end
  end

  return actions
end

-- ---------------------------------------------------------------------------
-- Group context injection for new tasks under ## headers
-- ---------------------------------------------------------------------------

function M.parse_group_context(lines, parsed_lines)
  local group_field
  for _, line in ipairs(lines) do
    local g = line:match("<!%-%- taskmd.*group:%s*(%S+)")
    if g then
      group_field = g:gsub("|$", "")
      group_field = trim(group_field)
      break
    end
  end
  if not group_field or group_field == "" then return parsed_lines end

  local current_group
  local task_idx = 1
  for _, line in ipairs(lines) do
    local stripped = trim(line)
    local g = stripped:match("^## (.+)$")
    if g then
      current_group = trim(g)
      if current_group == "(none)" then current_group = nil end
    elseif stripped:match(TASK_LINE_PATTERN) then
      if task_idx <= #parsed_lines and current_group then
        local t = parsed_lines[task_idx]
        if t[group_field] == nil then
          t[group_field] = current_group
        end
      end
      task_idx = task_idx + 1
    end
  end
  return parsed_lines
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

local function now_iso()
  local t = os.date("!*t")
  return string.format("%04d-%02d-%02dT%02d:%02d:%02d",
    t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function collapse_recurring(tasks)
  local seen_parents = {}
  local out = {}
  for _, t in ipairs(tasks) do
    local parent = t.parent
    if parent and t.status == "pending" then
      local existing = seen_parents[parent]
      if not existing or (t.due or "") < (existing.due or "") then
        seen_parents[parent] = t
      end
    else
      out[#out + 1] = t
    end
  end
  for _, t in pairs(seen_parents) do out[#out + 1] = t end
  return out
end

-- args = { filter=list, sort=str, group=str|nil, fields=str|nil, no_collapse=bool,
--          urgency_coefficients=table|nil }
-- Returns true if any element in `args` sets or filters the `status` field.
-- Matches bare `status:pending`, `status.any:`, `status.not:completed`, etc.
local function filter_has_status(args)
  for _, a in ipairs(args or {}) do
    if type(a) == "string" and a:match("^status[:.]") then return true end
  end
  return false
end

function M.render(args)
  args = args or {}
  local filter_args = args.filter or {}
  -- Default to pending tasks unless the caller explicitly filters by status.
  -- This keeps `:TaskFilter effort.before:1h` from returning completed tasks.
  -- Users who want all statuses can pass `status.any:` or `status:pending status:completed`.
  if not filter_has_status(filter_args) then
    table.insert(filter_args, 1, "status:pending")
  end
  local sort_spec = args.sort or "urgency-"
  local group_field = args.group
  local fields_filter
  if args.fields and args.fields ~= "" then
    fields_filter = {}
    for f in args.fields:gmatch("[^,]+") do fields_filter[#fields_filter + 1] = trim(f) end
  end

  local udas = M.tw_udas()
  local tasks = M.tw_export(filter_args)

  if not args.no_collapse then tasks = collapse_recurring(tasks) end

  -- Apply multiplicative urgency coefficients: urgency += value * coefficient.
  -- Non-numeric UDA values go through `resolve_value_mapper` so users can
  -- configure how each field's raw value is coerced to a number.
  local coeffs = args.urgency_coefficients
  if coeffs and next(coeffs) then
    local user_mappers = args.urgency_value_mappers
    for _, task in ipairs(tasks) do
      local adj = 0
      for field, coeff in pairs(coeffs) do
        local mapper = M.resolve_value_mapper(field, user_mappers)
        local val = mapper(task[field])
        if type(val) == "number" then adj = adj + val * coeff end
      end
      if adj ~= 0 then task.urgency = (task.urgency or 0) + adj end
    end
  end

  local descending = sort_spec:sub(-1) == "-"
  local sort_field = sort_spec:gsub("[+-]$", "")
  table.sort(tasks, function(a, b)
    local va, vb = a[sort_field], b[sort_field]
    local ma, mb = va == nil, vb == nil
    if ma and mb then return false end
    if ma ~= mb then return ma < mb end  -- missing sorts last (ma=true → larger)
    if type(va) == "number" and type(vb) == "number" then
      if descending then return va > vb else return va < vb end
    end
    if descending then return tostring(va) > tostring(vb) else return tostring(va) < tostring(vb) end
  end)

  local filter_str = table.concat(filter_args, " ")
  local group_part = group_field and (" | group: " .. group_field) or ""
  local udas_part = (#udas > 0) and (" | udas: " .. table.concat(udas, ",")) or ""
  local header = string.format(
    "<!-- taskmd filter: %s | sort: %s%s%s | rendered_at: %s -->",
    filter_str, sort_spec, group_part, udas_part, now_iso())

  local lines = { header, "" }
  if group_field then
    local groups = {}
    local order = {}
    for _, task in ipairs(tasks) do
      local key = tostring(task[group_field] or "(none)")
      if not groups[key] then
        groups[key] = {}
        order[#order + 1] = key
      end
      table.insert(groups[key], task)
    end
    for _, group_val in ipairs(order) do
      lines[#lines + 1] = "## " .. group_val
      lines[#lines + 1] = ""
      for _, task in ipairs(groups[group_val]) do
        lines[#lines + 1] = M.serialize_task_line(task, {
          fields_filter = fields_filter,
          omit_group_field = group_field,
          extra_fields = udas,
        })
      end
      lines[#lines + 1] = ""
    end
  else
    for _, task in ipairs(tasks) do
      lines[#lines + 1] = M.serialize_task_line(task, {
        fields_filter = fields_filter,
        extra_fields = udas,
      })
    end
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------------

local HEADER_PATTERN =
  "<!%-%-%s*taskmd filter:%s*(.-)%s*|" ..
  "%s*sort:%s*(.-)%s*|" ..
  "(.-)" ..
  "%s*rendered_at:%s*(.-)%s*%-%->"

local function parse_header(line)
  local filter_str, sort_spec, middle, rendered_at = line:match(HEADER_PATTERN)
  if not filter_str then return nil end
  local group_field, udas_str
  if middle and middle ~= "" then
    group_field = middle:match("group:%s*([^|]+)")
    udas_str = middle:match("udas:%s*([^|]+)")
    if group_field then group_field = trim(group_field) end
    if udas_str then udas_str = trim(udas_str) end
  end
  return {
    filter_args = filter_str and (function()
      local out = {}
      for a in filter_str:gmatch("%S+") do out[#out + 1] = a end
      return out
    end)() or {},
    sort_spec = trim(sort_spec or "urgency-"),
    group_field = group_field,
    udas_str = udas_str,
    rendered_at = trim(rendered_at or ""),
  }
end

-- parse ISO timestamp into a unix-seconds number (UTC). Returns nil on failure.
local function iso_to_unix(s)
  if not s or s == "" then return nil end
  -- Accept YYYY-MM-DDTHH:MM:SS[Z|+00:00] or TW format YYYYMMDDTHHMMSSZ
  local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)")
  if not y then
    y, mo, d, h, mi, se = s:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z?$")
  end
  if not y then return nil end
  -- Use os.time but force UTC: compute local offset and adjust.
  local t = { year = tonumber(y), month = tonumber(mo), day = tonumber(d),
              hour = tonumber(h), min = tonumber(mi), sec = tonumber(se) }
  local local_time = os.time(t)
  -- os.time treats table as local; adjust for UTC offset
  local utc_offset = os.difftime(os.time(), os.time(os.date("!*t", os.time())))
  return local_time + utc_offset
end

-- args = { file=str (optional), content=str (if provided, used instead), on_delete=str, force=bool, dry_run=bool }
-- Returns the summary dict.
function M.apply(args)
  args = args or {}
  local content = args.content
  if not content and args.file then
    local fh, err = io.open(args.file, "r")
    if not fh then return { error = "cannot read file: " .. tostring(err) } end
    content = fh:read("*a")
    fh:close()
  end
  if not content then return { error = "no content or file provided" } end

  local lines = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end

  local header
  for _, line in ipairs(lines) do
    header = parse_header(line)
    if header then break end
  end

  if not header and not args.force then
    return { error =
      "refusing to apply: no valid '<!-- taskmd filter: ... | sort: ... | " ..
      "rendered_at: ... -->' header found. Re-render with 'taskmd render' to " ..
      "regenerate the header, or pass --force to apply anyway (dangerous: " ..
      "tasks not present in the file will be marked done)."
    }
  end

  local filter_args = header and header.filter_args or {}
  local group_field = header and header.group_field
  local rendered_at = header and header.rendered_at
  local extra_fields = {}
  if header and header.udas_str then
    for u in header.udas_str:gmatch("[^,]+") do
      local t = trim(u); if t ~= "" then extra_fields[#extra_fields + 1] = t end
    end
  end

  local parsed_lines = {}
  for _, line in ipairs(lines) do
    local task = M.parse_task_line(line, extra_fields)
    if task then parsed_lines[#parsed_lines + 1] = task end
  end
  parsed_lines = M.parse_group_context(lines, parsed_lines)

  local base_tasks = M.tw_export(filter_args)
  base_tasks = collapse_recurring(base_tasks)

  local conflicts = {}
  if not args.force and rendered_at and rendered_at ~= "" then
    local ra = iso_to_unix(rendered_at)
    if ra then
      for _, task in ipairs(base_tasks) do
        local mod = task.modified
        if mod then
          local md = iso_to_unix(mod)
          if md and md > ra then
            conflicts[#conflicts + 1] = task.uuid or "unknown"
          end
        end
      end
    end
  end

  local diff = M.compute_diff(parsed_lines, base_tasks, {
    on_delete = args.on_delete or "done",
    extra_fields = extra_fields,
    omit_group_field = group_field,
  })

  if args.dry_run then
    return { actions = diff, conflicts = conflicts }
  end

  local summary = {
    added = 0, modified = 0, completed = 0, deleted = 0,
    errors = {}, action_count = #diff, conflicts = conflicts,
  }

  local order = { "add", "modify", "start", "stop", "done", "delete" }
  for _, atype in ipairs(order) do
    for _, action in ipairs(diff) do
      if action.type == atype then
        local ok, err = pcall(function()
          if atype == "add" then
            local new_uuid = M.tw_add(action.description, action.fields)
            summary.added = summary.added + 1
            if new_uuid ~= "" and action._post_done then
              M.tw_done(new_uuid); summary.completed = summary.completed + 1
            elseif new_uuid ~= "" and action._post_start then
              M.tw_start(new_uuid)
            end
          elseif atype == "modify" then
            M.tw_modify(action.uuid, action.fields); summary.modified = summary.modified + 1
          elseif atype == "start" then
            M.tw_start(action.uuid); summary.modified = summary.modified + 1
          elseif atype == "stop" then
            M.tw_stop(action.uuid); summary.modified = summary.modified + 1
          elseif atype == "done" then
            M.tw_done(action.uuid); summary.completed = summary.completed + 1
          elseif atype == "delete" then
            M.tw_delete(action.uuid); summary.deleted = summary.deleted + 1
          end
        end)
        if not ok then
          summary.errors[#summary.errors + 1] = { action = action, error = tostring(err) }
        end
      end
    end
  end

  return summary
end

return M
