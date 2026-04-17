-- task/views.lua — Visualization views for task.nvim
local M = {}

-- Track open view buffers for refresh
M._open_views = {} -- { bufnr = { type = "burndown"|"tree"|..., render_fn = function } }

local function run(cmd)
  local out = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  return out, ok
end

local function export_tasks(filter)
  filter = filter or "status:pending or status:completed"
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", filter)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return {} end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return {} end
  return tasks
end

-- Highlight groups for views
local hl_ns = vim.api.nvim_create_namespace("task_views_hl")

local function define_view_highlights()
  vim.api.nvim_set_hl(0, "TaskViewTitle", { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "TaskViewSeparator", { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "TaskViewBar", { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "TaskViewBarHigh", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "TaskViewBarMed", { fg = "#fab387" })
  vim.api.nvim_set_hl(0, "TaskViewBarLow", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "TaskViewOverdue", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "TaskViewToday", { fg = "#a6e3a1", bold = true })
  vim.api.nvim_set_hl(0, "TaskViewDate", { fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "TaskViewProject", { fg = "#94e2d5" })
  vim.api.nvim_set_hl(0, "TaskViewTag", { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "TaskViewHeader", { fg = "#9399b2" })
  vim.api.nvim_set_hl(0, "TaskViewStat", { fg = "#cba6f7" })
  vim.api.nvim_set_hl(0, "TaskViewTreeConn", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "TaskViewUrgHigh", { fg = "#f38ba8" })
  vim.api.nvim_set_hl(0, "TaskViewUrgMed", { fg = "#fab387" })
  vim.api.nvim_set_hl(0, "TaskViewUrgLow", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "TaskViewHint", { fg = "#585b70", italic = true })
end

local function apply_view_highlights(bufnr, highlights)
  vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
  for _, hl in ipairs(highlights) do
    -- { line, col_start, col_end, group }
    pcall(vim.api.nvim_buf_set_extmark, bufnr, hl_ns, hl[1], hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end
end

local function open_scratch(name, lines, highlights, render_fn)
  define_view_highlights()

  -- Flatten any embedded newlines/carriage returns
  local clean = {}
  for _, l in ipairs(lines) do
    local flat = l:gsub("\r\n", " "):gsub("\n", " "):gsub("\r", " "):gsub("%z", "")
    table.insert(clean, flat)
  end

  -- Reuse existing view buffer if open
  for bufnr, info in pairs(M._open_views) do
    if vim.api.nvim_buf_is_valid(bufnr) and info.name == name then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, clean)
      vim.bo[bufnr].modifiable = false
      if highlights then apply_view_highlights(bufnr, highlights) end
      info.render_fn = render_fn
      return bufnr
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "task_view"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, clean)
  vim.bo[buf].modifiable = false

  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
  local ok = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok then
    local stale = vim.fn.bufnr(name)
    if stale ~= -1 and stale ~= buf then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
      pcall(vim.api.nvim_buf_set_name, buf, name)
    end
  end

  if highlights then apply_view_highlights(buf, highlights) end

  -- Track for refresh
  M._open_views[buf] = { name = name, render_fn = render_fn }

  vim.keymap.set("n", "q", function()
    M._open_views[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, noremap = true, silent = true })

  -- Clean up tracking on buffer wipe
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function() M._open_views[buf] = nil end,
  })

  return buf
end

local function tw_date_to_ymd(val)
  if not val then return nil end
  if val:match("^%d%d%d%d%d%d%d%dT") then
    local y, mo, d = val:match("^(%d%d%d%d)(%d%d)(%d%d)T")
    return string.format("%s-%s-%s", y, mo, d)
  end
  return val:match("^%d%d%d%d%-%d%d%-%d%d") and val:sub(1, 10) or nil
end

-- ---------------------------------------------------------------------------
-- Shared task-line renderer (used by tree and calendar views)
-- Returns (line_text, highlights[]) where each highlight = { col_start, col_end, hl_group }
-- @param task   table   taskwarrior export object
-- @param prefix string  leading whitespace / tree connectors (already rendered by caller)
-- ---------------------------------------------------------------------------

local function render_task_line(task, prefix)
  prefix = prefix or ""
  local hls = {}
  local col = #prefix

  -- status indicator: [x] dim, [>] green, [ ] neutral
  local status, status_hl
  if task.status == "completed" then
    status = "[x]"; status_hl = "TaskViewHeader"
  elseif task.start then
    status = "[>]"; status_hl = "TaskViewToday"
  else
    status = "[ ]"
  end
  if status_hl then table.insert(hls, { col, col + #status, status_hl }) end
  col = col + #status + 1 -- +1 for the space after status

  -- description (uncolored — let inline metadata pop)
  local desc = (task.description or ""):gsub("[\r\n]", " ")
  col = col + #desc

  -- !priority (red H / orange M / green L)
  local prio_s = ""
  if task.priority then
    prio_s = " !" .. task.priority
    local hl = task.priority == "H" and "TaskViewUrgHigh"
            or task.priority == "M" and "TaskViewUrgMed"
            or "TaskViewUrgLow"
    table.insert(hls, { col, col + #prio_s, hl })
    col = col + #prio_s
  end

  -- @project (teal)
  local proj_s = ""
  if task.project then
    proj_s = " @" .. task.project
    table.insert(hls, { col, col + #proj_s, "TaskViewProject" })
    col = col + #proj_s
  end

  -- +tags (blue)
  local tags_s = ""
  for _, tag in ipairs(task.tags or {}) do
    local s = " +" .. tag
    tags_s = tags_s .. s
    table.insert(hls, { col, col + #s, "TaskViewTag" })
    col = col + #s
  end

  -- due date (red overdue / green today / yellow future)
  local due_s = ""
  local due = tw_date_to_ymd(task.due)
  if due then
    due_s = " " .. due
    local today = os.date("!%Y-%m-%d")
    local hl = due < today and "TaskViewOverdue"
            or due == today and "TaskViewToday"
            or "TaskViewDate"
    table.insert(hls, { col, col + #due_s, hl })
    col = col + #due_s
  end

  -- urgency score
  local urg_s = ""
  if task.urgency then
    urg_s = string.format(" (%.1f)", task.urgency)
    local hl = task.urgency >= 8 and "TaskViewUrgHigh"
            or task.urgency >= 4 and "TaskViewUrgMed"
            or "TaskViewUrgLow"
    table.insert(hls, { col, col + #urg_s, hl })
  end

  local line = prefix .. status .. " " .. desc .. prio_s .. proj_s .. tags_s .. due_s .. urg_s
  return line, hls
end

-- ---------------------------------------------------------------------------
-- Refresh all open views
-- ---------------------------------------------------------------------------

function M.refresh_all()
  for bufnr, info in pairs(M._open_views) do
    if vim.api.nvim_buf_is_valid(bufnr) and info.render_fn then
      info.render_fn()
    else
      M._open_views[bufnr] = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Burndown Chart
-- ---------------------------------------------------------------------------

function M.burndown()
  local function do_render()
    local tasks = export_tasks("status:pending or status:completed")
    if #tasks == 0 then
      vim.notify("task.nvim: no tasks found for burndown")
      return
    end

    local events = {}
    for _, t in ipairs(tasks) do
      local entry_date = tw_date_to_ymd(t.entry)
      if entry_date then
        events[entry_date] = (events[entry_date] or 0) + 1
      end
      if t.status == "completed" then
        local end_date = tw_date_to_ymd(t["end"]) or tw_date_to_ymd(t.modified)
        if end_date then
          events[end_date] = (events[end_date] or 0) - 1
        end
      end
    end

    local dates = {}
    for d, _ in pairs(events) do table.insert(dates, d) end
    table.sort(dates)

    if #dates == 0 then
      vim.notify("task.nvim: no date data for burndown")
      return
    end

    local running = 0
    local data_points = {}
    for _, d in ipairs(dates) do
      running = running + events[d]
      table.insert(data_points, { date = d, pending = running })
    end

    local max_pending = 0
    for _, dp in ipairs(data_points) do
      if dp.pending > max_pending then max_pending = dp.pending end
    end

    local chart_height = 20
    local chart_width = math.min(#data_points, 60)
    local lines = { "task.nvim — Burndown Chart", string.rep("═", 60), "" }
    local highlights = {
      { 0, 0, #lines[1], "TaskViewTitle" },
      { 1, 0, #lines[2], "TaskViewSeparator" },
    }

    local sampled = {}
    if #data_points > chart_width then
      local step = #data_points / chart_width
      for i = 1, chart_width do
        table.insert(sampled, data_points[math.floor((i - 1) * step) + 1])
      end
    else
      sampled = data_points
    end

    if max_pending == 0 then max_pending = 1 end

    for row = chart_height, 1, -1 do
      local threshold = (row / chart_height) * max_pending
      local label = string.format("%4d │", math.floor(threshold))
      local bar = {}
      for _, dp in ipairs(sampled) do
        if dp.pending >= threshold then
          table.insert(bar, "█")
        else
          table.insert(bar, " ")
        end
      end
      local line = label .. table.concat(bar)
      table.insert(lines, line)
      local line_idx = #lines - 1

      -- Color the label
      table.insert(highlights, { line_idx, 0, 5, "TaskViewHeader" })
      table.insert(highlights, { line_idx, 5, 6, "TaskViewSeparator" })

      -- Color the bar based on height (red=high, yellow=mid, green=low)
      local bar_start = #label
      local bar_text = table.concat(bar)
      if #bar_text > 0 then
        local pct = row / chart_height
        local hl_group
        if pct > 0.66 then hl_group = "TaskViewBarHigh"
        elseif pct > 0.33 then hl_group = "TaskViewBarMed"
        else hl_group = "TaskViewBarLow" end
        table.insert(highlights, { line_idx, bar_start, bar_start + #bar_text, hl_group })
      end
    end

    -- X-axis
    local axis = "     └" .. string.rep("─", #sampled)
    table.insert(lines, axis)
    table.insert(highlights, { #lines - 1, 0, #axis, "TaskViewSeparator" })

    -- Date labels
    if #sampled > 0 then
      local first = sampled[1].date:sub(6)
      local last = sampled[#sampled].date:sub(6)
      local padding = #sampled - #first - #last
      if padding < 1 then padding = 1 end
      local date_line = "      " .. first .. string.rep(" ", padding) .. last
      table.insert(lines, date_line)
      local li = #lines - 1
      table.insert(highlights, { li, 6, 6 + #first, "TaskViewDate" })
      table.insert(highlights, { li, 6 + #first + padding, 6 + #first + padding + #last, "TaskViewDate" })
    end

    table.insert(lines, "")
    local cur_line = string.format("  Current pending: %d", data_points[#data_points].pending)
    table.insert(lines, cur_line)
    table.insert(highlights, { #lines - 1, 19, #cur_line, "TaskViewStat" })

    local tot_line = string.format("  Total tracked:   %d", #tasks)
    table.insert(lines, tot_line)
    table.insert(highlights, { #lines - 1, 19, #tot_line, "TaskViewStat" })

    local rng_line = string.format("  Date range:      %s → %s", dates[1], dates[#dates])
    table.insert(lines, rng_line)
    table.insert(highlights, { #lines - 1, 19, #rng_line, "TaskViewDate" })

    table.insert(lines, "")
    table.insert(lines, "  Press q to close")
    table.insert(highlights, { #lines - 1, 0, #lines[#lines], "TaskViewHint" })

    open_scratch("task.nvim Burndown", lines, highlights, do_render)
  end
  do_render()
end

-- ---------------------------------------------------------------------------
-- Dependency Tree
-- ---------------------------------------------------------------------------

function M.tree()
  local function do_render()
    local tasks = export_tasks("status:pending")
    if #tasks == 0 then
      vim.notify("task.nvim: no pending tasks")
      return
    end

    local children = {}
    local has_parent = {}
    for _, t in ipairs(tasks) do
      local deps = t.depends or {}
      if type(deps) == "string" then deps = { deps } end
      for _, dep_uuid in ipairs(deps) do
        if not children[dep_uuid] then children[dep_uuid] = {} end
        table.insert(children[dep_uuid], t)
        has_parent[t.uuid] = true
      end
    end

    local lines = { "task.nvim — Dependency Tree", string.rep("═", 60), "" }
    local highlights = {
      { 0, 0, #lines[1], "TaskViewTitle" },
      { 1, 0, #lines[2], "TaskViewSeparator" },
    }

    local roots = {}
    for _, t in ipairs(tasks) do
      if not has_parent[t.uuid] then
        table.insert(roots, t)
      end
    end

    local function render_tree(task, prefix, is_last)
      local connector = is_last and "└── " or "├── "
      local full_prefix = prefix .. connector
      local line, task_hls = render_task_line(task, full_prefix)
      table.insert(lines, line)
      local li = #lines - 1

      -- Color tree connectors (the prefix portion before task content)
      local conn_end = #prefix + #connector
      table.insert(highlights, { li, 0, conn_end, "TaskViewTreeConn" })

      -- Apply all task-line highlights
      for _, hl in ipairs(task_hls) do
        table.insert(highlights, { li, hl[1], hl[2], hl[3] })
      end

      local kids = children[task.uuid] or {}
      for i, kid in ipairs(kids) do
        local child_prefix = prefix .. (is_last and "    " or "│   ")
        render_tree(kid, child_prefix, i == #kids)
      end
    end

    if #roots == 0 then
      table.insert(lines, "  No dependency relationships found.")
      table.insert(lines, "  Add dependencies with: task UUID modify depends:OTHER_UUID")
    else
      for i, root in ipairs(roots) do
        render_tree(root, "", i == #roots)
      end
    end

    table.insert(lines, "")
    local stat = string.format("  %d tasks, %d with dependencies", #tasks, vim.tbl_count(has_parent))
    table.insert(lines, stat)
    table.insert(highlights, { #lines - 1, 0, #stat, "TaskViewStat" })
    table.insert(lines, "")
    table.insert(lines, "  Press q to close")
    table.insert(highlights, { #lines - 1, 0, #lines[#lines], "TaskViewHint" })

    open_scratch("task.nvim Dependencies", lines, highlights, do_render)
  end
  do_render()
end

-- ---------------------------------------------------------------------------
-- Project Summary
-- ---------------------------------------------------------------------------

function M.summary()
  local function do_render()
    local pending = export_tasks("status:pending")
    local completed = export_tasks("status:completed")

    local projects = {}
    local function count(tasks, status_key)
      for _, t in ipairs(tasks) do
        local p = t.project or "(none)"
        if not projects[p] then
          projects[p] = { pending = 0, completed = 0, overdue = 0, high = 0 }
        end
        projects[p][status_key] = projects[p][status_key] + 1
        if status_key == "pending" then
          if t.priority == "H" then
            projects[p].high = projects[p].high + 1
          end
          local due = tw_date_to_ymd(t.due)
          if due and due < os.date("!%Y-%m-%d") then
            projects[p].overdue = projects[p].overdue + 1
          end
        end
      end
    end

    count(pending, "pending")
    count(completed, "completed")

    local sorted = {}
    for name, data in pairs(projects) do
      table.insert(sorted, { name = name, data = data })
    end
    table.sort(sorted, function(a, b) return a.data.pending > b.data.pending end)

    local lines = { "task.nvim — Project Summary", string.rep("═", 70), "" }
    local highlights = {
      { 0, 0, #lines[1], "TaskViewTitle" },
      { 1, 0, #lines[2], "TaskViewSeparator" },
    }

    local hdr = string.format("  %-25s %8s %8s %8s %8s", "Project", "Pending", "Done", "Overdue", "High")
    table.insert(lines, hdr)
    table.insert(highlights, { #lines - 1, 0, #hdr, "TaskViewHeader" })

    local sep = "  " .. string.rep("─", 65)
    table.insert(lines, sep)
    table.insert(highlights, { #lines - 1, 0, #sep, "TaskViewSeparator" })

    local total_p, total_c, total_o, total_h = 0, 0, 0, 0
    for _, entry in ipairs(sorted) do
      local d = entry.data
      total_p = total_p + d.pending
      total_c = total_c + d.completed
      total_o = total_o + d.overdue
      total_h = total_h + d.high

      local bar_len = math.min(d.pending, 20)
      local bar = string.rep("█", bar_len)
      local line = string.format("  %-25s %8d %8d %8d %8d  %s",
        entry.name:sub(1, 25), d.pending, d.completed, d.overdue, d.high, bar)
      table.insert(lines, line)
      local li = #lines - 1

      -- Color project name
      table.insert(highlights, { li, 2, 2 + math.min(#entry.name, 25), "TaskViewProject" })
      -- Color bar
      local bar_start = #line - #bar
      if #bar > 0 then
        local bar_hl = d.overdue > 0 and "TaskViewBarHigh" or (d.high > 0 and "TaskViewBarMed" or "TaskViewBar")
        table.insert(highlights, { li, bar_start, #line, bar_hl })
      end
      -- Color overdue count if > 0
      if d.overdue > 0 then
        local overdue_str = string.format("%8d", d.overdue)
        local overdue_col = 2 + 25 + 8 + 8 -- after project + pending + done
        table.insert(highlights, { li, overdue_col, overdue_col + 8, "TaskViewOverdue" })
      end
    end

    table.insert(lines, sep)
    table.insert(highlights, { #lines - 1, 0, #sep, "TaskViewSeparator" })

    local total_line = string.format("  %-25s %8d %8d %8d %8d", "TOTAL", total_p, total_c, total_o, total_h)
    table.insert(lines, total_line)
    table.insert(highlights, { #lines - 1, 0, #total_line, "TaskViewStat" })

    table.insert(lines, "")
    local rate = total_c > 0 and (total_c / (total_p + total_c) * 100) or 0
    local rate_line = string.format("  Completion rate: %.0f%%", rate)
    table.insert(lines, rate_line)
    table.insert(highlights, { #lines - 1, 19, #rate_line, "TaskViewStat" })

    table.insert(lines, "")
    table.insert(lines, "  Press q to close")
    table.insert(highlights, { #lines - 1, 0, #lines[#lines], "TaskViewHint" })

    open_scratch("task.nvim Summary", lines, highlights, do_render)
  end
  do_render()
end

-- ---------------------------------------------------------------------------
-- Calendar View
-- ---------------------------------------------------------------------------

function M.calendar()
  local function do_render()
    local tasks = export_tasks("status:pending")
    if #tasks == 0 then
      vim.notify("task.nvim: no pending tasks")
      return
    end

    local by_date = {}
    local no_due = {}
    for _, t in ipairs(tasks) do
      local due = tw_date_to_ymd(t.due)
      if due then
        if not by_date[due] then by_date[due] = {} end
        table.insert(by_date[due], t)
      else
        table.insert(no_due, t)
      end
    end

    local date_list = {}
    for d, _ in pairs(by_date) do table.insert(date_list, d) end
    table.sort(date_list)

    local today = os.date("!%Y-%m-%d")
    local lines = { "task.nvim — Calendar View", string.rep("═", 60), "" }
    local highlights = {
      { 0, 0, #lines[1], "TaskViewTitle" },
      { 1, 0, #lines[2], "TaskViewSeparator" },
    }

    for _, date in ipairs(date_list) do
      local marker = ""
      local date_hl = "TaskViewDate"
      if date < today then marker = " ⚠ OVERDUE"; date_hl = "TaskViewOverdue" end
      if date == today then marker = " ← TODAY"; date_hl = "TaskViewToday" end
      local date_line = string.format("  %s%s", date, marker)
      table.insert(lines, date_line)
      table.insert(highlights, { #lines - 1, 2, #date_line, date_hl })

      local sep = "  " .. string.rep("─", 40)
      table.insert(lines, sep)
      table.insert(highlights, { #lines - 1, 0, #sep, "TaskViewSeparator" })

      for _, t in ipairs(by_date[date]) do
        local line, task_hls = render_task_line(t, "    ")
        table.insert(lines, line)
        local li = #lines - 1
        for _, hl in ipairs(task_hls) do
          table.insert(highlights, { li, hl[1], hl[2], hl[3] })
        end
      end
      table.insert(lines, "")
    end

    if #no_due > 0 then
      table.insert(lines, "  No due date")
      table.insert(highlights, { #lines - 1, 2, #lines[#lines], "TaskViewHeader" })
      local sep = "  " .. string.rep("─", 40)
      table.insert(lines, sep)
      table.insert(highlights, { #lines - 1, 0, #sep, "TaskViewSeparator" })
      for _, t in ipairs(no_due) do
        local line, task_hls = render_task_line(t, "    ")
        table.insert(lines, line)
        local li = #lines - 1
        for _, hl in ipairs(task_hls) do
          table.insert(highlights, { li, hl[1], hl[2], hl[3] })
        end
      end
      table.insert(lines, "")
    end

    local due_count = 0
    for _, dt in pairs(by_date) do due_count = due_count + #dt end
    local stat = string.format("  %d tasks with due dates, %d without", due_count, #no_due)
    table.insert(lines, stat)
    table.insert(highlights, { #lines - 1, 0, #stat, "TaskViewStat" })
    table.insert(lines, "")
    table.insert(lines, "  Press q to close")
    table.insert(highlights, { #lines - 1, 0, #lines[#lines], "TaskViewHint" })

    open_scratch("task.nvim Calendar", lines, highlights, do_render)
  end
  do_render()
end

-- ---------------------------------------------------------------------------
-- Tags View
-- ---------------------------------------------------------------------------

function M.tags()
  local function do_render()
    local tasks = export_tasks("status:pending")

    local by_tag = {}
    for _, t in ipairs(tasks) do
      for _, tag in ipairs(t.tags or {}) do
        if not by_tag[tag] then by_tag[tag] = {} end
        table.insert(by_tag[tag], t)
      end
    end

    local sorted = {}
    for tag, list in pairs(by_tag) do
      table.insert(sorted, { tag = tag, count = #list })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)

    local lines = { "task.nvim — Tags", string.rep("═", 50), "" }
    local highlights = {
      { 0, 0, #lines[1], "TaskViewTitle" },
      { 1, 0, #lines[2], "TaskViewSeparator" },
    }

    local max_count = sorted[1] and sorted[1].count or 1

    for _, entry in ipairs(sorted) do
      local bar_len = math.max(1, math.floor(entry.count / max_count * 30))
      local bar = string.rep("█", bar_len)
      local line = string.format("  +%-20s %3d  %s", entry.tag, entry.count, bar)
      table.insert(lines, line)
      local li = #lines - 1

      -- Color tag name
      table.insert(highlights, { li, 2, 3 + math.min(#entry.tag, 20), "TaskViewTag" })
      -- Color count
      table.insert(highlights, { li, 23, 26, "TaskViewStat" })
      -- Color bar with gradient
      local bar_start = 28
      local pct = entry.count / max_count
      local bar_hl
      if pct > 0.66 then bar_hl = "TaskViewBarHigh"
      elseif pct > 0.33 then bar_hl = "TaskViewBarMed"
      else bar_hl = "TaskViewBarLow" end
      table.insert(highlights, { li, bar_start, bar_start + #bar, bar_hl })
    end

    if #sorted == 0 then
      table.insert(lines, "  No tags found on pending tasks.")
    end

    table.insert(lines, "")
    table.insert(lines, "  Press q to close")
    table.insert(highlights, { #lines - 1, 0, #lines[#lines], "TaskViewHint" })

    open_scratch("task.nvim Tags", lines, highlights, do_render)
  end
  do_render()
end

return M
