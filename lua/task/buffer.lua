local M = {}

-- ---------------------------------------------------------------------------
-- Shared utilities (same as init.lua copies — no circular dep)
-- ---------------------------------------------------------------------------

local function get_taskmd_path()
  local config = require("task.config")
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
  local config = require("task.config")

  -- Try the Lua backend first unless the user explicitly asked for python.
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "task.taskmd")
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
      })
      if ok_r and type(result) == "string" then
        return result
      end
      vim.notify("task.nvim: Lua backend render failed (" .. tostring(result) .. "); falling back to Python",
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

  -- Pass urgency coefficients as rc overrides so TW uses them for sorting
  for field, coeff in pairs(config.options.urgency_coefficients or {}) do
    table.insert(cmd, string.format("rc.urgency.uda.%s.coefficient=%s", field, tostring(coeff)))
  end

  local out, ok = run(table.concat(cmd, " "))
  if not ok then
    vim.notify("task.nvim: render failed\n" .. out, vim.log.levels.ERROR)
    return nil
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Custom sort: re-order task lines within groups by custom_urgency
-- ---------------------------------------------------------------------------

local function apply_custom_sort(bufnr)
  local config = require("task.config")
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

local hl_ns = vim.api.nvim_create_namespace("task_nvim_hl")
local vt_ns = vim.api.nvim_create_namespace("task_nvim_vt")

-- ---------------------------------------------------------------------------
-- Virtual text (urgency + annotation count)
-- ---------------------------------------------------------------------------

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

  local config = require("task.config")
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
      }
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local short_uuid = uuid_from_line(line)
    if short_uuid and meta[short_uuid] then
      local m = meta[short_uuid]
      local parts = {}
      if m.urgency then
        table.insert(parts, string.format("%.1f", m.urgency))
      end
      if m.annotations > 0 then
        table.insert(parts, string.format("[%d note%s]",
          m.annotations, m.annotations > 1 and "s" or ""))
      end
      if #parts > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, vt_ns, i - 1, 0, {
          virt_text = { { table.concat(parts, "  "), "Comment" } },
          virt_text_pos = "right_align",
        })
      end
    end
  end
end

M.apply_virtual_text = apply_virtual_text

-- ---------------------------------------------------------------------------
-- Highlight definitions and application
-- ---------------------------------------------------------------------------

local function define_highlights()
  vim.api.nvim_set_hl(0, "TaskPriorityH", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "TaskPriorityM", { fg = "#fab387", bold = true })
  vim.api.nvim_set_hl(0, "TaskPriorityL", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "TaskDue", { fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "TaskDueOverdue", { fg = "#f38ba8", bold = true })
  vim.api.nvim_set_hl(0, "TaskScheduled", { fg = "#f9e2af" })
  vim.api.nvim_set_hl(0, "TaskWait", { fg = "#9399b2" })
  vim.api.nvim_set_hl(0, "TaskTag", { fg = "#89b4fa" })
  vim.api.nvim_set_hl(0, "TaskProject", { fg = "#94e2d5" })
  vim.api.nvim_set_hl(0, "TaskRecur", { fg = "#cba6f7" })
  vim.api.nvim_set_hl(0, "TaskEffort", { fg = "#9399b2" })
  vim.api.nvim_set_hl(0, "TaskCompleted", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "TaskHeader", { fg = "#45475a" })
  vim.api.nvim_set_hl(0, "TaskGroupHeader", { fg = "#cdd6f4", bold = true })
  vim.api.nvim_set_hl(0, "TaskCheckbox", { fg = "#a6e3a1" })
  vim.api.nvim_set_hl(0, "TaskCheckboxDone", { fg = "#585b70" })
  vim.api.nvim_set_hl(0, "TaskStarted", { fg = "#89b4fa", bold = true })
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
  pos = 1
  while true do
    local s, e = line:find("%+[%w_-]+", pos)
    if not s then break end
    local prev = s > 1 and line:sub(s - 1, s - 1) or ""
    if prev == "" or not prev:match("[%w_]") then
      vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, s - 1, {
        end_col = e, hl_group = "TaskTag",
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
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "TaskNvimRefresh" })
  -- Refresh any open visualization views
  pcall(function() require("task.views").refresh_all() end)
end

-- ---------------------------------------------------------------------------
-- Buffer syntax setup (highlights + autocmd for re-highlight on change)
-- ---------------------------------------------------------------------------

function M.setup_buf_syntax(bufnr)
  define_highlights()
  update_highlights(bufnr)

  -- Set up autocmds for dynamic re-highlighting on text changes
  local hl_group = vim.api.nvim_create_augroup("TaskNvimHL_" .. bufnr, { clear = true })

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
  end, opts)

  -- Insert task below
  vim.keymap.set("n", "o", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "- [ ] " })
    vim.api.nvim_win_set_cursor(0, { row + 1, 6 })
    vim.cmd("startinsert!")
  end, opts)

  -- Insert task above
  vim.keymap.set("n", "O", function()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "- [ ] " })
    vim.api.nvim_win_set_cursor(0, { row + 1, 6 })
    vim.cmd("startinsert!")
  end, opts)

  -- Annotate
  vim.keymap.set("n", "ga", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    vim.ui.input({ prompt = "Annotation: " }, function(text)
      if not text or text == "" then return end
      local _, ok = run(
        string.format("task rc.bulk=0 rc.confirmation=off %s annotate %s",
          short_uuid, vim.fn.shellescape(text))
      )
      if ok then
        vim.notify("task.nvim: annotation added")
        M.refresh_buf(bufnr)
      else
        vim.notify("task.nvim: annotation failed", vim.log.levels.ERROR)
      end
    end)
  end, opts)

  -- Modify/append mode: press gm to modify task attributes via prompt
  vim.keymap.set("n", "gm", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    vim.ui.input({
      prompt = "Modify (e.g. +tag project:foo due:tomorrow): ",
      completion = "custom,v:lua.require'task'._complete_modify",
    }, function(input)
      if not input or input == "" then return end
      local escaped = input:gsub("'", "'\\''")
      local _, ok = run(
        string.format("task rc.bulk=0 rc.confirmation=off %s modify '%s'",
          short_uuid, escaped)
      )
      if ok then
        vim.notify("task.nvim: modified")
        M.refresh_buf(bufnr)
      else
        vim.notify("task.nvim: modify failed", vim.log.levels.ERROR)
      end
    end)
  end, opts)

  -- Filter presets from config
  local config = require("task.config")
  for _, preset in ipairs(config.options.filters or {}) do
    if preset.key and preset.filter then
      vim.keymap.set("n", preset.key, function()
        vim.b[bufnr].task_filter = preset.filter
        M.refresh_buf(bufnr)
        vim.notify("task.nvim: filter → " .. (preset.label or preset.filter))
      end, { buffer = bufnr, noremap = true, silent = true,
             desc = "task.nvim: " .. (preset.label or preset.filter) })
    end
  end

  -- Buffer-local filter key (uses input() for tab completion support)
  local config2 = require("task.config")
  if config2.options.filter_key then
    vim.keymap.set("n", config2.options.filter_key, function()
      -- Use vim.fn.input with completion so <Tab> works
      local ok, input = pcall(vim.fn.input, {
        prompt = "Filter: ",
        default = vim.b[bufnr].task_filter or "",
        completion = "customlist,v:lua.require'task'._complete_filter",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_filter = input
      M.refresh_buf(bufnr)
      vim.notify("task.nvim: filter → " .. (input ~= "" and input or "(all pending)"))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "task.nvim: Change filter" })
  end

  -- Buffer-local sort key
  if config2.options.sort_key then
    vim.keymap.set("n", config2.options.sort_key, function()
      local ok, input = pcall(vim.fn.input, {
        prompt = "Sort: ",
        default = vim.b[bufnr].task_sort or "urgency-",
        completion = "customlist,v:lua.require'task'._complete_sort",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_sort = input
      M.refresh_buf(bufnr)
      vim.notify("task.nvim: sort → " .. input)
    end, { buffer = bufnr, noremap = true, silent = true, desc = "task.nvim: Change sort" })
  end

  -- Buffer-local group key
  if config2.options.group_key then
    vim.keymap.set("n", config2.options.group_key, function()
      local ok, input = pcall(vim.fn.input, {
        prompt = "Group by (empty=none): ",
        default = vim.b[bufnr].task_group or "",
        completion = "customlist,v:lua.require'task'._complete_group",
      })
      if not ok or input == nil then return end
      vim.b[bufnr].task_group = (input ~= "" and input ~= "none") and input or nil
      M.refresh_buf(bufnr)
      vim.notify("task.nvim: group → " .. (input ~= "" and input or "(none)"))
    end, { buffer = bufnr, noremap = true, silent = true, desc = "task.nvim: Change grouping" })
  end

  -- Show full task info in split
  vim.keymap.set("n", "gf", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    local out, ok = run(
      string.format("task rc.bulk=0 rc.confirmation=off %s info", short_uuid)
    )
    if not ok or out == "" then
      vim.notify("task.nvim: info failed", vim.log.levels.ERROR)
      return
    end
    local detail_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[detail_buf].buftype = "nofile"
    M.set_buf_lines(detail_buf, out)
    vim.bo[detail_buf].modifiable = false
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, detail_buf)
  end, opts)
end

-- ---------------------------------------------------------------------------
-- Buffer autocmds
-- on_write_fn: callback(bufnr) called on BufWriteCmd (M._on_write from init)
-- ---------------------------------------------------------------------------

function M.setup_buf_autocmds(bufnr, on_write_fn)
  local group = vim.api.nvim_create_augroup("TaskNvim_" .. bufnr, { clear = true })

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
        vim.notify("task.nvim: header is read-only (use :TaskFilter to change filter)", vim.log.levels.WARN)
      end
    end,
  })

  -- Update header cache when buffer is refreshed (filter/sort/group changes)
  vim.api.nvim_create_autocmd("User", {
    pattern = "TaskNvimRefresh",
    group = group,
    callback = function()
      header_cache = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
    end,
  })

  -- Cursor clamping: keep cursor before the UUID comment region.
  --
  -- Only clamp on HORIZONTAL motions (same row as previous CursorMoved). On
  -- vertical motions (j/k/G/gg/<C-d>/etc.) the cursor lands wherever vim
  -- decided based on curswant — clamping there resets curswant to the clamped
  -- column, which causes the very next j/k to snap to that column and makes
  -- it feel like j "doesn't work" after a row where the cursor was near the
  -- concealed UUID region (especially after $ or across blank/group lines).
  local config = require("task.config")
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

return M
