local M = {}

-- ---------------------------------------------------------------------------
-- Shared utilities (same as init.lua copies — no circular dep)
-- ---------------------------------------------------------------------------

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

-- Resolve the checkbox glyph for a slot, or nil if no icon should render
-- (parser-faithful "- [ ]" stays visible).
--
-- Returns the raw glyph string without padding; the caller is responsible
-- for placing it (currently as inline virt_text alongside a conceal extmark
-- that hides the literal "- [ ]" prefix).
--
-- Suppressed when `icons = false` (forced ASCII) or when `icons = "auto"`
-- and `vim.g.have_nerd_font` is unset.
local function checkbox_overlay_text(slot)
  if not slot then return nil end
  local config = require("taskwarrior.config")
  local user = config.options.icons
  if user == false then return nil end
  if user == "auto" and not vim.g.have_nerd_font then return nil end

  local glyph
  if type(user) == "table" and type(user[slot]) == "string" then
    glyph = user[slot]
  else
    glyph = require("taskwarrior.icons").get(slot)
  end
  if not glyph or glyph == "" then return nil end
  return glyph
end

M._checkbox_overlay_text = checkbox_overlay_text  -- exported for testing

-- ---------------------------------------------------------------------------
-- Buffer line utilities
-- ---------------------------------------------------------------------------

function M.set_buf_lines(bufnr, text)
  local lines = vim.split(text or "", "\n", { plain = true })
  -- strip trailing empty line that split may add
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- ---------------------------------------------------------------------------
-- Render: produce markdown text for a filter/sort/group
-- ---------------------------------------------------------------------------

local function render(filter, sort, group)
  local config = require("taskwarrior.config")

  -- Try the Lua backend first unless the user explicitly asked for python.
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "taskwarrior.taskmd")
    if ok_m then
      local filter_args = {}
      if filter and filter ~= "" then
        for w in filter:gmatch("%S+") do table.insert(filter_args, w) end
      end
      local ok_r, result = pcall(tm.render, {
        filter = filter_args,
        sort = sort or config.options.sort or "urgency-",
        group = (group ~= "" and group) or nil,
        fields = config.options.fields,
        urgency_coefficients = config.options.urgency_coefficients,
        urgency_value_mappers = config.options.urgency_value_mappers,
      })
      if ok_r and type(result) == "string" then
        return result
      end
      vim.notify("taskwarrior.nvim: Lua backend render failed (" .. tostring(result) .. "); falling back to Python",
        vim.log.levels.WARN)
    end
  end

  local taskmd = get_taskmd_path()
  local cmd = { taskmd, "render" }
  if filter and filter ~= "" then
    for word in filter:gmatch("%S+") do
      table.insert(cmd, word)
    end
  end
  table.insert(cmd, "--sort=" .. (sort or config.options.sort or "urgency-"))
  if group and group ~= "" then
    table.insert(cmd, "--group=" .. group)
  end
  if config.options.fields then
    table.insert(cmd, "--fields=" .. config.options.fields)
  end

  local out, ok = run(table.concat(cmd, " "))
  if not ok then
    vim.notify("taskwarrior.nvim: render failed\n" .. out, vim.log.levels.ERROR)
    return nil
  end
  return out
end

M.render = render

-- ---------------------------------------------------------------------------
-- Custom sort: re-order task lines within groups by custom_urgency
-- ---------------------------------------------------------------------------

local function apply_custom_sort(bufnr)
  local config = require("taskwarrior.config")
  if not config.options.custom_urgency then return end

  -- Export tasks to get full data for the custom function
  local filter = vim.b[bufnr].task_filter or ""
  local export_filter = filter ~= "" and filter or "status:pending"
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", export_filter)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return end

  -- Apply multiplicative urgency coefficients (same logic as taskmd.lua render).
  -- Non-numeric values go through user-configurable mappers.
  local coeffs = config.options.urgency_coefficients
  if coeffs and next(coeffs) then
    local tm_ok, tm = pcall(require, "taskwarrior.taskmd")
    local user_mappers = config.options.urgency_value_mappers
    for _, t in ipairs(tasks) do
      local adj = 0
      for field, coeff in pairs(coeffs) do
        local mapper = tm_ok and tm.resolve_value_mapper(field, user_mappers) or tonumber
        local val = mapper(t[field])
        if type(val) == "number" then adj = adj + val * coeff end
      end
      if adj ~= 0 then t.urgency = (t.urgency or 0) + adj end
    end
  end

  -- Build UUID → custom urgency map
  local urgency_map = {}
  for _, t in ipairs(tasks) do
    if t.uuid then
      local custom_urg = config.options.custom_urgency(t)
      urgency_map[t.uuid:sub(1, 8)] = custom_urg or 0
    end
  end

  -- Re-sort lines within each group
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local groups = {} -- list of { header_lines = {}, task_lines = {} }
  local current = { header_lines = {}, task_lines = {} }

  for _, line in ipairs(lines) do
    if line:match("^## ") then
      if #current.task_lines > 0 or #current.header_lines > 0 then
        table.insert(groups, current)
      end
      current = { header_lines = { line }, task_lines = {} }
    elseif line:match("^%- %[") then
      table.insert(current.task_lines, line)
    else
      if #current.task_lines > 0 then
        -- Non-task line after tasks = separator, start new section
        table.insert(current.task_lines, line)
      else
        table.insert(current.header_lines, line)
      end
    end
  end
  if #current.task_lines > 0 or #current.header_lines > 0 then
    table.insert(groups, current)
  end

  -- Sort task lines within each group by custom urgency (descending)
  for _, g in ipairs(groups) do
    table.sort(g.task_lines, function(a, b)
      local uuid_a = uuid_from_line(a)
      local uuid_b = uuid_from_line(b)
      local urg_a = uuid_a and urgency_map[uuid_a] or 0
      local urg_b = uuid_b and urgency_map[uuid_b] or 0
      return urg_a > urg_b
    end)
  end

  -- Reassemble
  local new_lines = {}
  for _, g in ipairs(groups) do
    for _, l in ipairs(g.header_lines) do table.insert(new_lines, l) end
    for _, l in ipairs(g.task_lines) do table.insert(new_lines, l) end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

-- ---------------------------------------------------------------------------
-- Namespaces (module-level singletons)
-- ---------------------------------------------------------------------------

local hl_ns = vim.api.nvim_create_namespace("taskwarrior_hl")
local vt_ns = vim.api.nvim_create_namespace("taskwarrior_vt")

-- Paint the checkbox visuals on a single line: a conceal extmark over the
-- literal "- [ ]" prefix (5 cells → 0 cells visible) plus an inline
-- virt_text extmark inserting "icon " (2 cells) at col 0. Net: text starts
-- ~3 cells closer to the margin than the raw markdown.
--
-- Both extmarks live in `vt_ns` so the apply_virtual_text clear-namespace
-- call wipes them on every refresh. Idempotent — calling twice on the same
-- line just replaces the extmarks.
--
-- Returns true if a paint was applied (overlay enabled), false otherwise.
local function paint_checkbox_line(bufnr, lnum, line)
  if not line then
    line = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
  end
  local box = line:match("^%- %[([ x>])%]")
  if not box then return false end
  local slot, hl
  if box == " " then slot, hl = "checkbox_pending", "taskmdCheckboxPending"
  elseif box == ">" then slot, hl = "checkbox_started", "taskmdCheckboxActive"
  elseif box == "x" then slot, hl = "checkbox_done", "taskmdCheckboxDone"
  end
  local glyph = checkbox_overlay_text(slot)
  if not glyph then return false end
  -- Hide the literal "- [ ] " (5-char checkbox + 1 trailing space, bytes
  -- 0..5 inclusive). The conceal extmark relies on the buffer's
  -- conceallevel = 3 which is set in setup_buf_autocmds' BufWinEnter.
  -- Only hide if there's actually something at byte 5 to hide; on an empty
  -- "- [ ]" line (no trailing space yet, e.g. fresh insert) we hide just
  -- the 5-char prefix.
  local has_trailing_space = vim.api.nvim_buf_get_text(
    bufnr, lnum, 5, lnum, 6, {})[1] == " "
  vim.api.nvim_buf_set_extmark(bufnr, vt_ns, lnum, 0, {
    end_row = lnum,
    end_col = has_trailing_space and 6 or 5,
    conceal = "",
  })
  -- Insert the icon at col 0 as inline virt_text. Trailing space provides
  -- a single-cell separator before the description.
  vim.api.nvim_buf_set_extmark(bufnr, vt_ns, lnum, 0, {
    virt_text = { { glyph, hl }, { " ", "" } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  })
  return true
end

M._paint_checkbox_line = paint_checkbox_line  -- exported for testing

-- ---------------------------------------------------------------------------
-- Virtual text (urgency + annotation count)
-- ---------------------------------------------------------------------------

-- Resolve an urgency value to a highlight group using the user's
-- config.urgency_colors breakpoints. Rows are { threshold, hl } tuples
-- (in the config they're tables with named keys). First row whose threshold
-- is <= urgency wins. Returns the hl group name; materializes inline table
-- specs into ad-hoc groups on demand.
local function urgency_hl(urgency)
  local config = require("taskwarrior.config")
  local bands = config.options.urgency_colors
  if not bands or not urgency then return "Comment" end
  for _, band in ipairs(bands) do
    if urgency >= band.threshold then
      if type(band.hl) == "string" then return band.hl end
      if type(band.hl) == "table" then
        local gname = string.format("TaskUrgBand_%d",
          math.floor(band.threshold * 100))
        pcall(vim.api.nvim_set_hl, 0, gname, band.hl)
        return gname
      end
    end
  end
  return "Comment"
end

M.urgency_hl = urgency_hl

-- ---------------------------------------------------------------------------
-- Contextual date formatter: "2026-04-21" → "today" / "in 3d · Fri" / "2d overdue".
-- Returns (label, hl_group) or nil if the input is unparseable.
-- Hard rule from the UI research: NEVER rewrite the buffer text — the
-- absolute date stays as-is, the relative form rides alongside as
-- virtual text.
-- ---------------------------------------------------------------------------
local WEEKDAY_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function today_ymd()
  return os.date("!%Y-%m-%d")
end

local function ymd_to_epoch(ymd)
  local y, mo, d = ymd:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                   hour = 12, min = 0, sec = 0 })
end

local function relative_date(ymd)
  if not ymd then return nil end
  local target = ymd_to_epoch(ymd)
  if not target then return nil end
  local now = ymd_to_epoch(today_ymd())
  local delta_days = math.floor((target - now) / 86400 + 0.5)

  if delta_days < -1 then
    return string.format("%dd overdue", -delta_days), "TaskDueOverdue"
  end
  if delta_days == -1 then
    return "1d overdue", "TaskDueOverdue"
  end
  if delta_days == 0 then
    return "today", "TaskDueToday"
  end
  if delta_days == 1 then
    return "tomorrow", "TaskDueSoon"
  end
  if delta_days >= 2 and delta_days <= 6 then
    local dow = tonumber(os.date("!%w", target)) + 1 -- 1-based
    return string.format("in %dd · %s", delta_days, WEEKDAY_SHORT[dow]), "TaskDue"
  end
  if delta_days >= 7 and delta_days <= 13 then
    local dow = tonumber(os.date("!%w", target)) + 1
    return "next " .. WEEKDAY_SHORT[dow], "TaskDue"
  end
  if delta_days <= 60 then
    return string.format("in %dw", math.floor(delta_days / 7)), "TaskSubtle"
  end
  return string.format("in %dmo", math.floor(delta_days / 30)), "TaskSubtle"
end

M._relative_date = relative_date  -- exported for e2e testing

local function apply_virtual_text(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, vt_ns, 0, -1)
  local filter = vim.b[bufnr].task_filter or ""
  local export_filter = filter ~= "" and filter or "status:pending"
  local cmd = string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", export_filter)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return end

  -- Handle warnings before JSON
  local json_start = out:find("%[")
  if json_start and json_start > 1 then
    out = out:sub(json_start)
  end

  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return end

  local config = require("taskwarrior.config")
  local icons = require("taskwarrior.icons")
  local meta = {}
  for _, t in ipairs(tasks) do
    if t.uuid then
      local urg = t.urgency
      if config.options.custom_urgency then
        local cok, custom = pcall(config.options.custom_urgency, t)
        if cok then urg = custom end
      end
      meta[t.uuid:sub(1, 8)] = {
        urgency = urg,
        annotations = t.annotations and #t.annotations or 0,
        due = t.due,
        start = t["start"],
        priority = t.priority,
        effort = t.effort,
      }
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    paint_checkbox_line(bufnr, i - 1, line)

    local short_uuid = uuid_from_line(line)
    if short_uuid and meta[short_uuid] then
      local m = meta[short_uuid]
      local chunks = {}

      -- 1. Relative-date chip (leftmost, most actionable info)
      if config.options.relative_dates ~= false then
        local due_from_line = line:match("due:(%d%d%d%d%-%d%d%-%d%d)")
        if due_from_line then
          local label, hl = relative_date(due_from_line)
          if label then
            table.insert(chunks, { label, hl })
          end
        end
      end

      -- 2. Overdue badge — opt-in (off by default) because the relative-
      -- date label already carries the "Nd overdue" message in the same
      -- slot. Users who want a high-contrast alarm enable `overdue_badge`.
      if config.options.overdue_badge and m.due then
        local y, mo, d = m.due:match("^(%d%d%d%d)(%d%d)(%d%d)")
        if y then
          local iso = y .. "-" .. mo .. "-" .. d
          if iso < today_ymd() then
            if #chunks > 0 then table.insert(chunks, { "  ", "Comment" }) end
            local badge = icons.get("badge_overdue")
            table.insert(chunks, { " " .. badge .. " ", "TaskOverdueBadge" })
          end
        end
      end

      -- 2b. Started-elapsed chip — if the task is active, show how long
      -- it's been running. TW stores `start` as `YYYYMMDDTHHMMSSZ` (UTC).
      --
      -- Converting UTC components to a real epoch requires adding the
      -- local-to-UTC offset, because os.time(table) interprets the table
      -- as LOCAL time. The offset is `os.time() - os.time(os.date("!*t"))`,
      -- which is negative for timezones west of UTC.
      if m.start then
        local y, mo, d, H, Mi, S = m.start:match(
          "^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)")
        if y then
          -- `isdst = false` is load-bearing: `os.date("!*t")` always sets
          -- isdst=false (UTC has no DST), so the offset below is computed
          -- under isdst=false. Leaving isdst nil on this table would make
          -- Lua apply DST for the parsed time in summer, producing a
          -- 1-hour mismatch on systems in DST-observing timezones.
          local as_local = os.time({
            year = tonumber(y), month = tonumber(mo), day = tonumber(d),
            hour = tonumber(H), min = tonumber(Mi), sec = tonumber(S),
            isdst = false,
          })
          local tz_offset = os.time() - os.time(os.date("!*t"))
          local started_at = as_local + tz_offset
          local elapsed = math.max(0, os.time() - started_at)
          local elapsed_label
          if elapsed < 60 then
            elapsed_label = string.format("%ds", elapsed)
          elseif elapsed < 3600 then
            elapsed_label = string.format("%dm", math.floor(elapsed / 60))
          else
            elapsed_label = string.format("%dh%02dm",
              math.floor(elapsed / 3600),
              math.floor((elapsed % 3600) / 60))
          end
          if #chunks > 0 then table.insert(chunks, { "  ", "Comment" }) end
          local icon = icons.get("status_started")
          table.insert(chunks, { icon .. " " .. elapsed_label, "TaskAccent" })
        end
      end

      -- 3. Urgency bar glyph + number — opt-in. Off by default because
      -- a raw numeric urgency competes for attention with the more
      -- actionable signals (priority sign, relative date). Users who
      -- want the score visible enable `show_urgency = true`.
      if config.options.show_urgency and m.urgency then
        if #chunks > 0 then table.insert(chunks, { "  ", "Comment" }) end
        if config.options.urgency_bar ~= false then
          local slot = icons.urgency_bar_slot(m.urgency)
          if slot then
            table.insert(chunks, { icons.get(slot) .. " ", urgency_hl(m.urgency) })
          end
        end
        table.insert(chunks, {
          string.format("%.1f", m.urgency),
          urgency_hl(m.urgency),
        })
      end

      -- 4. Annotation count
      if m.annotations > 0 then
        if #chunks > 0 then table.insert(chunks, { "  ", "Comment" }) end
        local note_icon = icons.get("status_note")
        table.insert(chunks, {
          string.format("%s %d", note_icon, m.annotations),
          "TaskSubtle",
        })
      end

      if #chunks > 0 then
        -- `right_align` draws at the window's right edge; with `wrap=true`
        -- and long task lines it overwrites the literal text on the
        -- first wrap segment. `eol` places the chips immediately after
        -- the line's last character, so they always follow content,
        -- spilling onto an extra wrap line if needed rather than stomping
        -- on it. Padding separator keeps the chips visually detached.
        table.insert(chunks, 1, { "  ", "Comment" })
        vim.api.nvim_buf_set_extmark(bufnr, vt_ns, i - 1, 0, {
          virt_text = chunks,
          virt_text_pos = "eol",
        })
      end

      -- Sign column: priority (col 1) and status (col 2).
      -- The sign-column extmarks live in the same namespace; `sign_text` is
      -- limited to 2 display cells per extmark, so we emit two separate
      -- extmarks to get both priority and status showing.
      local prio_slot
      if m.priority == "H" then prio_slot = "priority_h"
      elseif m.priority == "M" then prio_slot = "priority_m"
      elseif m.priority == "L" then prio_slot = "priority_l"
      end
      if prio_slot then
        vim.api.nvim_buf_set_extmark(bufnr, vt_ns, i - 1, 0, {
          sign_text = icons.get(prio_slot),
          sign_hl_group = "Task" .. prio_slot:sub(1, 1):upper() .. prio_slot:sub(2):gsub("_(.)", function(c) return c:upper() end),
          priority = 10,
        })
      end
      local status_slot
      if m.start then status_slot = "status_started"
      else
        local ymd_due = line:match("due:(%d%d%d%d%-%d%d%-%d%d)")
        if ymd_due and ymd_due < today_ymd() then
          status_slot = "status_overdue"
        end
      end
      if status_slot then
        local sign_hl = status_slot == "status_started"
          and "TaskStarted" or "TaskUrgent"
        vim.api.nvim_buf_set_extmark(bufnr, vt_ns, i - 1, 0, {
          sign_text = icons.get(status_slot),
          sign_hl_group = sign_hl,
          priority = 11,
        })
      end
    end
  end

  -- Header stats slots (below the taskmd comment header).
  local stats = config.options.header_stats
  if stats and type(stats) == "table" and #stats > 0 then
    local slot_chunks = {}
    for _, fn in ipairs(stats) do
      local sok, text = pcall(fn, tasks)
      if sok and type(text) == "string" and text ~= "" then
        if #slot_chunks > 0 then
          table.insert(slot_chunks, { "  ·  ", "Comment" })
        end
        table.insert(slot_chunks, { text, "TaskViewStat" })
      end
    end
    if #slot_chunks > 0 and lines[1] and lines[1]:match("^<!%-%-.*taskmd") then
      -- eol so it doesn't overlap header text on narrow windows.
      table.insert(slot_chunks, 1, { "  ", "Comment" })
      vim.api.nvim_buf_set_extmark(bufnr, vt_ns, 0, 0, {
        virt_text = slot_chunks,
        virt_text_pos = "eol",
      })
    end
  end
end

M.apply_virtual_text = apply_virtual_text

-- ---------------------------------------------------------------------------
-- Highlight definitions and application
-- ---------------------------------------------------------------------------

-- Palette organized by semantic role. Six colors max, per UI research.
-- Users override with `urgency_colors` / `tag_colors`; these are the
-- baseline highlight groups everything else references.
local function define_highlights()
  -- New role-based groups (for reuse in views, virt-text, etc.)
  vim.api.nvim_set_hl(0, "TaskAccent", { fg = "#89b4fa", bold = true })   -- active/focus
  vim.api.nvim_set_hl(0, "TaskUrgent", { fg = "#f38ba8", bold = true })   -- overdue/H
  vim.api.nvim_set_hl(0, "TaskWarn",   { fg = "#fab387" })                 -- M/due-soon
  vim.api.nvim_set_hl(0, "TaskInfo",   { fg = "#f9e2af" })                 -- due-future
  vim.api.nvim_set_hl(0, "TaskTagHL",  { fg = "#cba6f7" })                 -- +tags (mauve)
  vim.api.nvim_set_hl(0, "TaskSubtle", { fg = "#6c7086" })                 -- UDAs/wait/effort

  -- Field-specific groups link to the role groups above. Overriding
  -- a role instantly recolors every field that uses it.
  vim.api.nvim_set_hl(0, "TaskPriorityH",   { link = "TaskUrgent" })
  vim.api.nvim_set_hl(0, "TaskPriorityM",   { link = "TaskWarn"   })
  vim.api.nvim_set_hl(0, "TaskPriorityL",   { link = "TaskSubtle" }) -- was green (misleading)
  vim.api.nvim_set_hl(0, "TaskDue",         { link = "TaskInfo"   })
  vim.api.nvim_set_hl(0, "TaskDueSoon",     { link = "TaskWarn"   })
  vim.api.nvim_set_hl(0, "TaskDueToday",    { fg = "#fab387", bold = true })
  vim.api.nvim_set_hl(0, "TaskDueOverdue",  { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "TaskScheduled",   { fg = "#f9e2af", italic = true })
  vim.api.nvim_set_hl(0, "TaskWait",        { fg = "#6c7086", italic = true })
  vim.api.nvim_set_hl(0, "TaskTag",         { link = "TaskTagHL" })
  vim.api.nvim_set_hl(0, "TaskProject",     { link = "TaskSubtle" }) -- was teal, too loud
  vim.api.nvim_set_hl(0, "TaskRecur",       { link = "TaskTagHL" })
  vim.api.nvim_set_hl(0, "TaskEffort",      { link = "TaskSubtle" })
  -- Strikethrough for completed — reads as "done, ignorable" at a glance
  vim.api.nvim_set_hl(0, "TaskCompleted",   { fg = "#6c7086", strikethrough = true })
  vim.api.nvim_set_hl(0, "TaskHeader",      { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "TaskGroupHeader", { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "TaskCheckbox",    { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "TaskCheckboxDone",{ fg = "#585b70" })
  vim.api.nvim_set_hl(0, "TaskStarted",     { link = "TaskAccent" })
  -- Overdue right-align pill uses an inverted-fg style so it pops against
  -- normal right-align virt-text.
  vim.api.nvim_set_hl(0, "TaskOverdueBadge",{ fg = "#1e1e2e", bg = "#f38ba8", bold = true })
end

-- Highlight patterns: { lua pattern, highlight group, is_prefix_match }
-- Order matters for whole-line matches (completed must come first)
-- Tags are handled separately (see highlight_line) so we can require a word
-- boundary before the `+` — otherwise `housing+food` would light up `+food`.
local HL_PATTERNS = {
  { "priority:H",              "TaskPriorityH" },
  { "priority:M",              "TaskPriorityM" },
  { "priority:L",              "TaskPriorityL" },
  { "scheduled:%d%d%d%d%-%d%d%-%d%d", "TaskScheduled" },
  { "wait:%d%d%d%d%-%d%d%-%d%d",      "TaskWait" },
  { "recur:%S+",               "TaskRecur" },
  { "effort:%S+",              "TaskEffort" },
  { "project:%S+",             "TaskProject" },
}

-- Check if a date string (YYYY-MM-DD) is in the past
local function is_overdue(date_str)
  local today = os.date("!%Y-%m-%d")
  return date_str < today
end

-- Apply highlights to a single line
local function highlight_line(bufnr, line_nr, line)
  -- Header comment line — concealed entirely. Users don't need to see the
  -- <!-- taskmd filter: ... | sort: ... | rendered_at: ... --> metadata, only
  -- the tasks themselves. Filter/sort/group are shown via statusline if the
  -- user configures it, and :TaskHelp lists the active settings.
  if line:match("^<!%-%-.*taskmd") then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = #line, hl_group = "TaskHeader",
      conceal = "",
    })
    return
  end

  -- Group header (## ...)
  if line:match("^## ") then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = #line, hl_group = "TaskGroupHeader",
    })
    return
  end

  -- Completed task — dim entire line
  if line:match("^%- %[x%]") then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = #line, hl_group = "TaskCompleted",
    })
    return
  end

  -- Started/active task — highlight with accent color
  if line:match("^%- %[>%]") then
    local cb_s, cb_e = line:find("^%- %[>%]")
    if cb_s then
      vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
        end_col = cb_e, hl_group = "TaskStarted",
      })
    end
    -- Don't return — still highlight fields on this line
  end

  -- Checkbox
  local cb_start, cb_end = line:find("^%- %[ %]")
  if cb_start then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, {
      end_col = cb_end, hl_group = "TaskCheckbox",
    })
  end

  -- UUID concealment
  local uuid_start, uuid_end = line:find("<!%-%- uuid:[0-9a-fA-F]+ %-%->")
  if uuid_start then
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, uuid_start - 1, {
      end_col = uuid_end, conceal = "",
    })
  end

  -- Due dates (special: overdue = red, future = yellow)
  local pos = 1
  while true do
    local s, e, date = line:find("due:(%d%d%d%d%-%d%d%-%d%d)", pos)
    if not s then break end
    local hl = is_overdue(date) and "TaskDueOverdue" or "TaskDue"
    vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, s - 1, {
      end_col = e, hl_group = hl,
    })
    pos = e + 1
  end

  -- All other patterns
  for _, pat in ipairs(HL_PATTERNS) do
    pos = 1
    while true do
      local s, e = line:find(pat[1], pos)
      if not s then break end
      vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, s - 1, {
        end_col = e, hl_group = pat[2],
      })
      pos = e + 1
    end
  end

  -- Tags: +word, but only when the `+` is at start-of-line or preceded by a
  -- non-word character. Prevents "housing+food" from highlighting "+food".
  -- Honors config.tag_colors for per-tag overrides (e.g. +urgent → ErrorMsg).
  local config = require("taskwarrior.config")
  local tag_colors = config.options.tag_colors or {}
  pos = 1
  while true do
    local s, e = line:find("%+[%w_-]+", pos)
    if not s then break end
    local prev = s > 1 and line:sub(s - 1, s - 1) or ""
    if prev == "" or not prev:match("[%w_]") then
      local tag_literal = line:sub(s, e)
      local override = tag_colors[tag_literal]
      local hl_group = "TaskTag"
      if type(override) == "string" then
        hl_group = override
      elseif type(override) == "table" then
        -- Materialize an ad-hoc highlight group for this tag. Name is stable
        -- across invocations so we avoid re-defining on every redraw.
        local gname = "TaskTag_" .. tag_literal:gsub("[^%w]", "_")
        pcall(vim.api.nvim_set_hl, 0, gname, override)
        hl_group = gname
      end
      vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, s - 1, {
        end_col = e, hl_group = hl_group,
      })
    end
    pos = e + 1
  end
end

-- Re-highlight entire buffer
local function update_highlights(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    highlight_line(bufnr, i - 1, line)
  end
end

M.update_highlights = update_highlights

-- Debounced highlight update
local highlight_timer = nil
local function schedule_highlight_update(bufnr)
  if highlight_timer then
    vim.fn.timer_stop(highlight_timer)
  end
  highlight_timer = vim.fn.timer_start(50, function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        update_highlights(bufnr)
      end
    end)
    highlight_timer = nil
  end)
end

-- ---------------------------------------------------------------------------
-- refresh_buf: re-render and re-highlight a task buffer
-- ---------------------------------------------------------------------------

function M.refresh_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local filter = vim.b[bufnr].task_filter or ""
  local sort   = vim.b[bufnr].task_sort
  local group  = vim.b[bufnr].task_group
  local out = render(filter, sort, group)
  if not out then return end
  M.set_buf_lines(bufnr, out)
  apply_custom_sort(bufnr)
  update_highlights(bufnr)
  apply_virtual_text(bufnr)
  vim.bo[bufnr].modified = false
  -- Update header-protection cache with the freshly-rendered header so the
  -- TextChanged guard doesn't revert to the previous filter/sort/group.
  vim.b[bufnr].taskmd_header_cache = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "TaskwarriorRefresh" })
  -- Refresh any open visualization views
  pcall(function() require("taskwarrior.views").refresh_all() end)
end

-- ---------------------------------------------------------------------------
-- Buffer syntax setup (highlights + autocmd for re-highlight on change)
-- ---------------------------------------------------------------------------

function M.setup_buf_syntax(bufnr)
  define_highlights()
  update_highlights(bufnr)

  -- Set up autocmds for dynamic re-highlighting on text changes
  local hl_group = vim.api.nvim_create_augroup("TaskwarriorHL_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    group = hl_group,
    callback = function()
      schedule_highlight_update(bufnr)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Buffer keymaps
-- ---------------------------------------------------------------------------

function M.setup_buf_keymaps(bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Smart j/k: do screen-line movement (gj/gk) for wrapped-line navigation,
  -- but if the cursor gets stuck on a phantom screen line created by the
  -- concealed UUID comment at the end of task lines, fall back to buffer-line
  -- movement. With a count (e.g. 5j), always use buffer-line movement.
  for _, key in ipairs({ "j", "k" }) do
    vim.keymap.set("n", key, function()
      if vim.v.count > 0 then
        vim.cmd("normal! " .. vim.v.count .. key)
        return
      end
      local before = vim.api.nvim_win_get_cursor(0)
      vim.cmd("normal! g" .. key)
      local after = vim.api.nvim_win_get_cursor(0)
      if after[1] == before[1] and after[2] == before[2] then
        vim.cmd("normal! " .. key)
      end
    end, opts)
  end

  -- Cycle task state: [ ] → [>] → [x] → [ ]
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local toggled
    if line:match("^%- %[ %]") then
      toggled = line:gsub("^%- %[ %]", "- [>]", 1)
    elseif line:match("^%- %[>%]") then
      toggled = line:gsub("^%- %[>%]", "- [x]", 1)
    elseif line:match("^%- %[x%]") then
      toggled = line:gsub("^%- %[x%]", "- [ ]", 1)
    else
      return
    end
    vim.api.nvim_set_current_line(toggled)
    -- Repaint the checkbox synchronously: nvim_set_current_line clears
    -- extmarks on the line, and the next apply_virtual_text run only fires
    -- on save. Without this, the user sees the raw "- [>]" / "- [x]"
    -- markdown for a frame between the line edit and the next render.
    local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
    paint_checkbox_line(bufnr, lnum, toggled)
  end, opts)

  -- Insert task below
  vim.keymap.set("n", "o", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "- [ ] " })
    vim.api.nvim_win_set_cursor(0, { row + 1, 6 })
    paint_checkbox_line(bufnr, row, "- [ ] ")
    vim.cmd("startinsert!")
  end, opts)

  -- Insert task above
  vim.keymap.set("n", "O", function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "- [ ] " })
    vim.api.nvim_win_set_cursor(0, { row + 1, 6 })
    paint_checkbox_line(bufnr, row, "- [ ] ")
    vim.cmd("startinsert!")
  end, opts)

  -- Annotate
  vim.keymap.set("n", "ga", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("taskwarrior.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    vim.ui.input({ prompt = "Annotation: " }, function(text)
      if not text or text == "" then return end
      local _, ok = run(
        string.format("task rc.bulk=0 rc.confirmation=off %s annotate %s",
          short_uuid, vim.fn.shellescape(text))
      )
      if ok then
        vim.notify("taskwarrior.nvim: annotation added")
        M.refresh_buf(bufnr)
      else
        vim.notify("taskwarrior.nvim: annotation failed", vim.log.levels.ERROR)
      end
    end)
  end, opts)

  -- Modify/append mode: press gm to modify task attributes via prompt
  vim.keymap.set("n", "gm", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("taskwarrior.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    vim.ui.input({
      prompt = "Modify (e.g. +tag project:foo due:tomorrow): ",
      completion = "custom,v:lua.require'taskwarrior'._complete_modify",
    }, function(input)
      if not input or input == "" then return end
      local escaped = input:gsub("'", "'\\''")
      local _, ok = run(
        string.format("task rc.bulk=0 rc.confirmation=off %s modify '%s'",
          short_uuid, escaped)
      )
      if ok then
        vim.notify("taskwarrior.nvim: modified")
        M.refresh_buf(bufnr)
      else
        vim.notify("taskwarrior.nvim: modify failed", vim.log.levels.ERROR)
      end
    end)
  end, opts)

  -- Filter presets from config
  local config = require("taskwarrior.config")
  for _, preset in ipairs(config.options.filters or {}) do
    if preset.key and preset.filter then
      vim.keymap.set("n", preset.key, function()
        vim.b[bufnr].task_filter = preset.filter
        M.refresh_buf(bufnr)
        vim.notify("taskwarrior.nvim: filter → " .. (preset.label or preset.filter))
      end, { buffer = bufnr, noremap = true, silent = true,
             desc = "taskwarrior.nvim: " .. (preset.label or preset.filter) })
    end
  end

  -- Buffer-local filter key (uses input() for tab completion support)
  local config2 = require("taskwarrior.config")
  if config2.options.filter_key then
    vim.keymap.set("n", config2.options.filter_key, function()
      -- Use vim.fn.input with completion so <Tab> works
      local ok, input = pcall(vim.fn.input, {
        prompt = "Filter: ",
        default = vim.b[bufnr].task_filter or "",
        completion = "customlist,v:lua.require'taskwarrior'._complete_filter",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_filter = input
      M.refresh_buf(bufnr)
      vim.notify("taskwarrior.nvim: filter → " .. (input ~= "" and input or "(all pending)"))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "taskwarrior.nvim: Change filter" })
  end

  -- Buffer-local sort key
  if config2.options.sort_key then
    vim.keymap.set("n", config2.options.sort_key, function()
      local ok, input = pcall(vim.fn.input, {
        prompt = "Sort: ",
        default = vim.b[bufnr].task_sort or "urgency-",
        completion = "customlist,v:lua.require'taskwarrior'._complete_sort",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_sort = input
      M.refresh_buf(bufnr)
      vim.notify("taskwarrior.nvim: sort → " .. input)
    end, { buffer = bufnr, noremap = true, silent = true, desc = "taskwarrior.nvim: Change sort" })
  end

  -- Buffer-local group key
  if config2.options.group_key then
    vim.keymap.set("n", config2.options.group_key, function()
      local ok, input = pcall(vim.fn.input, {
        prompt = "Group by (empty=none): ",
        default = vim.b[bufnr].task_group or "",
        completion = "customlist,v:lua.require'taskwarrior'._complete_group",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_group = (input ~= "" and input ~= "none") and input or nil
      M.refresh_buf(bufnr)
      vim.notify("taskwarrior.nvim: group → " .. (input ~= "" and input or "(none)"))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "taskwarrior.nvim: Change grouping" })
  end

  -- Show full task info in a centered floating window.
  vim.keymap.set("n", "gf", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("taskwarrior.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    local out, ok = run(
      string.format("task rc.bulk=0 rc.confirmation=off %s info", short_uuid)
    )
    if not ok or out == "" then
      vim.notify("taskwarrior.nvim: info failed", vim.log.levels.ERROR)
      return
    end
    local detail_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[detail_buf].buftype = "nofile"
    M.set_buf_lines(detail_buf, out)
    vim.bo[detail_buf].modifiable = false

    local cfg = require("taskwarrior.config")
    local w = math.min(vim.o.columns - 4, 100)
    local lines = vim.api.nvim_buf_get_lines(detail_buf, 0, -1, false)
    local h = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))
    local win = vim.api.nvim_open_win(detail_buf, true, {
      relative = "editor",
      width = w,
      height = h,
      row = math.floor((vim.o.lines - h) / 2),
      col = math.floor((vim.o.columns - w) / 2),
      style = "minimal",
      border = cfg.options.border_style or "rounded",
      title = " Task " .. short_uuid .. " ",
      title_pos = "center",
    })
    vim.keymap.set("n", "q", function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = detail_buf, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = detail_buf, nowait = true, silent = true })
  end, opts)

  -- Field-specific modify pickers. Prefix `M` + one letter so it composes
  -- with `gm` (free-form modify) without collisions.
  vim.keymap.set("n", "MM", function()
    require("taskwarrior.modify").modify_project()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Modify project" }))
  vim.keymap.set("n", "Mp", function()
    require("taskwarrior.modify").modify_priority()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Modify priority" }))
  vim.keymap.set("n", "MP", function()
    require("taskwarrior.modify").modify_project()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Modify project (alias of MM)" }))
  vim.keymap.set("n", "MD", function()
    require("taskwarrior.modify").modify_due()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Modify due date" }))
  vim.keymap.set("n", "Mt", function()
    require("taskwarrior.modify").modify_tag()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Add tag" }))

  -- Task-level shortcuts
  vim.keymap.set("n", ">>", function()
    require("taskwarrior.modify").append()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Append to description" }))
  vim.keymap.set("n", "<<", function()
    require("taskwarrior.modify").prepend()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Prepend to description" }))
  vim.keymap.set("n", "yt", function()
    require("taskwarrior.modify").duplicate()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Duplicate task" }))
  vim.keymap.set("n", "dD", function()
    require("taskwarrior.modify").purge()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Purge (irreversible)" }))
  vim.keymap.set("n", "gA", function()
    require("taskwarrior.modify").denotate()
  end, vim.tbl_extend("force", opts, { desc = "taskwarrior.nvim: Remove annotation" }))
end

-- ---------------------------------------------------------------------------
-- Buffer autocmds
-- on_write_fn: callback(bufnr) called on BufWriteCmd (M._on_write from init)
-- ---------------------------------------------------------------------------

function M.setup_buf_autocmds(bufnr, on_write_fn)
  local group = vim.api.nvim_create_augroup("Taskwarrior_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    group = group,
    callback = function()
      on_write_fn(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    group = group,
    callback = function()
      vim.wo[0].conceallevel = 3
      vim.wo[0].concealcursor = "nvic"
      -- Wrap prevents horizontal-scroll disorientation on j/k with long task
      -- lines. Without wrap, curswant preservation causes the viewport to
      -- shift horizontally, making it look like j "doesn't work".
      vim.wo[0].wrap = true
    end,
  })

  -- Protect header line: if user edits line 1 (the <!-- taskmd ... --> comment),
  -- restore it on the next TextChanged event. The cached header lives on the
  -- buffer (vim.b) so :TaskFilter/:TaskSort/:TaskRefresh can update it when
  -- they re-render; otherwise a stale closure would revert the new header on
  -- the next edit.
  vim.b[bufnr].taskmd_header_cache = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = bufnr,
    group = group,
    callback = function()
      local cached = vim.b[bufnr].taskmd_header_cache or ""
      local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
      if first_line ~= cached and cached:match("^<!%-%-.*taskmd") then
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { cached })
        vim.notify("taskwarrior.nvim: header is read-only (use :TaskFilter to change filter)", vim.log.levels.WARN)
      end
    end,
  })

  -- Update header cache when buffer is refreshed (filter/sort/group changes).
  -- User events don't carry buffer context, so this autocmd fires for every
  -- task buffer's TaskwarriorRefresh — guard against stale closures over wiped
  -- buffers, and self-clean the augroup if the buffer is gone.
  vim.api.nvim_create_autocmd("User", {
    pattern = "TaskwarriorRefresh",
    group = group,
    callback = function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return
      end
      pcall(function()
        vim.b[bufnr].taskmd_header_cache =
          vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
        header_cache = vim.b[bufnr].taskmd_header_cache
      end)
    end,
  })

  -- Periodic refresh of the relative-date virt-text so buffers that stay
  -- open across midnight or mealtime still read correctly. We only need
  -- to re-run apply_virtual_text (cheap — one `task export` call) rather
  -- than a full render.
  local cfg_rf = require("taskwarrior.config").options.relative_date_refresh_ms
  if cfg_rf and cfg_rf > 0 then
    vim.api.nvim_create_autocmd("CursorHold", {
      buffer = bufnr,
      group = group,
      callback = function()
        if vim.api.nvim_buf_is_valid(bufnr) then apply_virtual_text(bufnr) end
      end,
    })
  end

  -- Cursor clamping: keep cursor before the UUID comment region.
  --
  -- Only clamp on HORIZONTAL motions (same row as previous CursorMoved). On
  -- vertical motions (j/k/G/gg/<C-d>/etc.) the cursor lands wherever vim
  -- decided based on curswant — clamping there resets curswant to the clamped
  -- column, which causes the very next j/k to snap to that column and makes
  -- it feel like j "doesn't work" after a row where the cursor was near the
  -- concealed UUID region (especially after $ or across blank/group lines).
  local config = require("taskwarrior.config")
  if config.options.clamp_cursor then
    vim.b[bufnr].taskmd_last_row = nil
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      group = group,
      callback = function()
        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        local prev_row = vim.b[bufnr].taskmd_last_row
        vim.b[bufnr].taskmd_last_row = row
        -- Row changed → vertical motion. Record and return; do not touch the
        -- cursor, so curswant is preserved for subsequent j/k.
        if prev_row ~= row then return end
        local line = vim.api.nvim_get_current_line()
        local uuid_start = line:find(" <!%-%- uuid:")
        if uuid_start and col >= uuid_start - 1 then
          vim.api.nvim_win_set_cursor(0, { row, uuid_start - 2 })
        end
      end,
    })
  end
end

-- ---------------------------------------------------------------------------
-- open_task_buf: create (or reuse) a task buffer for the given filter.
-- on_write_fn: callback(bufnr) for BufWriteCmd (M._on_write from init)
-- detect_project_fn: callback() -> project_name|nil
-- ---------------------------------------------------------------------------

function M.open_task_buf(filter_str, on_write_fn, detect_project_fn)
  local config = require("taskwarrior.config")
  filter_str = filter_str or ""

  -- Pull the full per-cwd project entry so we can honor an optional saved
  -- `view` / `filter` / `sort` without a second lookup.
  local cwd_entry
  local ok_p, projects_mod = pcall(require, "taskwarrior.projects")
  if ok_p then cwd_entry = projects_mod.detect_entry() end

  -- Auto-detect project filter from cwd when no filter is given
  if filter_str == "" then
    if cwd_entry and cwd_entry.filter and cwd_entry.filter ~= "" then
      filter_str = cwd_entry.filter
    elseif cwd_entry and cwd_entry.name then
      filter_str = "project:" .. cwd_entry.name
    elseif detect_project_fn then
      local project = detect_project_fn()
      if project then filter_str = "project:" .. project end
    end
  end

  -- If the cwd entry names a saved view, load its filter/sort/group overrides
  -- *unless* the caller passed an explicit filter.
  if cwd_entry and cwd_entry.view and (not filter_str or filter_str == ""
      or filter_str == "project:" .. (cwd_entry.name or "")) then
    local ok_v, views_mod = pcall(require, "taskwarrior.saved_views")
    if ok_v then
      local v = views_mod._get(cwd_entry.view)
      if v then
        if v.filter and v.filter ~= "" then filter_str = v.filter end
        cwd_entry._view_sort = v.sort
        cwd_entry._view_group = v.group
      end
    end
  end

  local sort = (cwd_entry and cwd_entry._view_sort)
               or config.options.sort or "urgency-"
  local group = (cwd_entry and cwd_entry._view_group) or config.options.group

  -- Reuse existing task buffer with same filter
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter == filter_str then
      vim.api.nvim_win_set_buf(0, b)
      vim.wo[0].conceallevel = 3
      vim.wo[0].concealcursor = "nvic"
      vim.wo[0].wrap = true
      -- Reserve two sign cells for priority + status glyphs. `auto:2` only
      -- shows the column when a sign is present, so tasks with no priority
      -- or status don't waste horizontal space.
      vim.wo[0].signcolumn = "auto:2"
      M.refresh_buf(b)
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

  M.set_buf_lines(bufnr, out)
  vim.bo[bufnr].modified = false

  vim.b[bufnr].task_filter = filter_str
  vim.b[bufnr].task_sort = sort
  vim.b[bufnr].task_group = group

  M.setup_buf_syntax(bufnr)
  M.setup_buf_keymaps(bufnr)
  M.setup_buf_autocmds(bufnr, on_write_fn)
  apply_virtual_text(bufnr)

  vim.api.nvim_win_set_buf(0, bufnr)
  vim.wo[0].conceallevel = 3
  vim.wo[0].concealcursor = "nvic"
  vim.wo[0].wrap = true

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

-- ---------------------------------------------------------------------------
-- open_float: render the task buffer in a centered floating window.
-- Used by :TaskFloat. The floating window is ephemeral — closing it with `q`
-- (buffer-local) or `<Esc>` drops the buffer; the underlying task state lives
-- in Taskwarrior, not in the window.
-- ---------------------------------------------------------------------------

function M.open_float(filter_str)
  local config = require("taskwarrior.config")
  filter_str = filter_str or ""

  local main = require("taskwarrior")
  -- Reuse the open-task-buf pipeline to get a fully-wired acwrite buffer
  -- (syntax, keymaps, autocmds). Then pop it into a float rather than the
  -- current window.
  local scratch = vim.api.nvim_create_buf(true, false)
  vim.bo[scratch].buftype = "acwrite"
  vim.bo[scratch].filetype = "taskmd"
  vim.bo[scratch].swapfile = false
  vim.bo[scratch].bufhidden = "wipe"

  local sort = config.options.sort or "urgency-"
  local group = config.options.group
  local out = render(filter_str, sort, group)
  if not out then return end
  M.set_buf_lines(scratch, out)
  vim.bo[scratch].modified = false
  vim.b[scratch].task_filter = filter_str
  vim.b[scratch].task_sort = sort
  vim.b[scratch].task_group = group

  M.setup_buf_syntax(scratch)
  M.setup_buf_keymaps(scratch)
  M.setup_buf_autocmds(scratch, main._on_write)

  local w = math.min(vim.o.columns - 4, 120)
  local h = math.min(vim.o.lines - 4, math.max(20, math.floor(vim.o.lines * 0.8)))
  local win = vim.api.nvim_open_win(scratch, true, {
    relative = "editor",
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    style = "minimal",
    border = config.options.border_style or "rounded",
    title = " Tasks: " .. (filter_str ~= "" and filter_str or "(all pending)") .. " ",
    title_pos = "center",
  })
  vim.wo[win].conceallevel = 3
  vim.wo[win].concealcursor = "nvic"
  vim.wo[win].wrap = true

  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = scratch, nowait = true, silent = true })

  apply_virtual_text(scratch)
end

return M
