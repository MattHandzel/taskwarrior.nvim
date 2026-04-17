local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
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

-- Auto-setup guard: ensures setup() has been called (for lazy-loaded plugins)
local function ensure_setup()
  local config = require("task.config")
  if not next(config.options) then
    M.setup({})
  end
end

-- ---------------------------------------------------------------------------
-- Project detection + persistence (delegated to task.projects)
-- ---------------------------------------------------------------------------

local function detect_project()
  return require("task.projects").detect()
end

-- ---------------------------------------------------------------------------
-- Tab completion helpers (delegated to task.completion)
-- ---------------------------------------------------------------------------

local function get_tw_completions()
  return require("task.completion").get_tw_completions()
end

local function complete_filter(arg_lead)
  return require("task.completion").complete_filter(arg_lead)
end

-- ---------------------------------------------------------------------------
-- Buffer module delegation (render, set_buf_lines, refresh_buf, syntax,
-- keymaps, autocmds — see lua/task/buffer.lua)
-- ---------------------------------------------------------------------------

local function set_buf_lines(bufnr, text)
  require("task.buffer").set_buf_lines(bufnr, text)
end

local function refresh_buf(bufnr)
  require("task.buffer").refresh_buf(bufnr)
end

local function update_highlights(bufnr)
  require("task.buffer").update_highlights(bufnr)
end

local function apply_virtual_text(bufnr)
  require("task.buffer").apply_virtual_text(bufnr)
end

local function setup_buf_syntax(bufnr)
  require("task.buffer").setup_buf_syntax(bufnr)
end

local function setup_buf_keymaps(bufnr)
  require("task.buffer").setup_buf_keymaps(bufnr)
end

local function setup_buf_autocmds(bufnr)
  require("task.buffer").setup_buf_autocmds(bufnr, M._on_write)
end

-- ---------------------------------------------------------------------------
-- Write handler (delegated to task.apply)
-- ---------------------------------------------------------------------------

function M._on_write(bufnr)
  require("task.apply").on_write(bufnr, refresh_buf, M._do_apply)
end

function M._do_apply(bufnr, tmpfile, on_delete)
  require("task.apply").do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_buf)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

M.get_taskmd_path = get_taskmd_path

function M.open(filter_str)
  ensure_setup()
  local config = require("task.config")
  filter_str = filter_str or ""

  -- Auto-detect project filter from cwd when no filter is given
  if filter_str == "" then
    local project = detect_project()
    if project then
      filter_str = "project:" .. project
    end
  end

  local sort = config.options.sort or "urgency-"
  local group = config.options.group

  -- Reuse existing task buffer with same filter
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter == filter_str then
      vim.api.nvim_win_set_buf(0, b)
      vim.wo[0].conceallevel = 3
      vim.wo[0].concealcursor = "nvic"
      refresh_buf(b)
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

  set_buf_lines(bufnr, out)
  vim.bo[bufnr].modified = false

  vim.b[bufnr].task_filter = filter_str
  vim.b[bufnr].task_sort = sort
  vim.b[bufnr].task_group = group

  setup_buf_syntax(bufnr)
  setup_buf_keymaps(bufnr)
  setup_buf_autocmds(bufnr)
  apply_virtual_text(bufnr)

  vim.api.nvim_win_set_buf(0, bufnr)
  vim.wo[0].conceallevel = 3
  vim.wo[0].concealcursor = "nvic"

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

function M.filter(filter_str)
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].task_filter then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_filter = filter_str or ""
  refresh_buf(bufnr)
end

function M.refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].task_filter then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  refresh_buf(bufnr)
end

function M.undo()
  local bufnr = vim.api.nvim_get_current_buf()
  local count = vim.b[bufnr].task_last_action_count
  if not count or count == 0 then
    vim.notify("task.nvim: nothing to undo")
    return
  end

  vim.ui.select({ "Undo", "Cancel" }, {
    prompt = string.format("Undo %d action(s) from last save?", count),
  }, function(choice)
    if choice ~= "Undo" then return end

    local failed = 0
    for _ = 1, count do
      local _, ok = run("task rc.bulk=0 rc.confirmation=off undo")
      if not ok then failed = failed + 1 end
    end

    vim.b[bufnr].task_last_action_count = nil

    if failed > 0 then
      vim.notify(string.format("task.nvim: undo completed (%d failed)", failed), vim.log.levels.WARN)
    else
      vim.notify(string.format("task.nvim: undid %d action(s)", count))
    end

    refresh_buf(bufnr)
  end)
end

function M.sort(sort_spec)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_sort = sort_spec or "urgency-"
  refresh_buf(bufnr)
end

function M.group(group_field)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].task_group = (group_field and group_field ~= "none" and group_field ~= "") and group_field or nil
  refresh_buf(bufnr)
end

function M.project_add(name)
  require("task.projects").add(name)
end

function M.project_remove()
  require("task.projects").remove()
end

function M.project_list()
  require("task.projects").list()
end

-- Detect project for the current cwd (public API)
M.detect_project = detect_project

function M.delegate()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_get_current_line()
  local short_uuid = uuid_from_line(line)
  if not short_uuid then
    vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
    return
  end

  local out, ok = run(
    string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", short_uuid))
  if not ok or not out or out == "" then
    vim.notify("task.nvim: failed to export task", vim.log.levels.ERROR)
    return
  end

  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end

  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" or #tasks == 0 then
    vim.notify("task.nvim: failed to parse task", vim.log.levels.ERROR)
    return
  end

  local task = tasks[1]
  return task, short_uuid
end

-- ---------------------------------------------------------------------------
-- TaskDelegate — popup form + interactive terminal
-- ---------------------------------------------------------------------------

-- Format a single task block for inclusion in a multi-task prompt.
local function format_task_block(info, index, total)
  local task = info.task
  local short = info.short_uuid
  local uuid = task.uuid or short
  local desc = task.description or "unknown"
  local project = task.project or ""
  local tags = task.tags or {}
  local due = task.due or ""
  local priority = task.priority or ""
  local annotations = task.annotations or {}

  local lines = { string.format("=== Task %d/%d ===", index, total) }
  table.insert(lines, string.format("Short UUID: %s", short))
  table.insert(lines, string.format("Full UUID:  %s", uuid))
  table.insert(lines, string.format("Description: %s", desc))
  if project ~= "" then table.insert(lines, string.format("Project: %s", project)) end
  if priority ~= "" then table.insert(lines, string.format("Priority: %s", priority)) end
  if due ~= "" then table.insert(lines, string.format("Due: %s", due)) end
  if #tags > 0 then table.insert(lines, string.format("Tags: +%s", table.concat(tags, " +"))) end
  if #annotations > 0 then
    table.insert(lines, "Existing annotations:")
    for _, a in ipairs(annotations) do
      table.insert(lines, string.format("  - %s", (a.description or ""):gsub("\n", " ")))
    end
  end
  return table.concat(lines, "\n")
end

-- Build the full prompt text. `task_infos` is a list of
-- { task = <export_dict>, short_uuid = <8-char> }.
local function build_task_prompt(task_infos, extra_context)
  local n = #task_infos
  local p = {}
  local function add(s) table.insert(p, s) end

  add(string.format("You have been delegated %d task%s from Taskwarrior via task.nvim.",
    n, n == 1 and "" or "s"))
  add("")
  add("# How the user watches your progress")
  add("")
  add("The user sees Taskwarrior annotations, not this terminal. Annotate OFTEN")
  add("(every 3-5 minutes of real work) so progress is visible. Use these exact")
  add("annotation prefixes so the user can filter for them:")
  add("")
  add("  START     — your plan, posted before you begin the task")
  add("  PROGRESS  — what you just finished, posted along the way")
  add("  OUTPUT    — absolute path of any file you produced")
  add("  BLOCKED   — why you stopped (use only if you cannot finish)")
  add("  COMPLETE  — 1-sentence summary, posted once the task is finished")
  add("")
  add("# Protocol for every task below")
  add("")
  add("  1. Mark it active and post your plan:")
  add("       task <short_uuid> start")
  add("       task <short_uuid> annotate \"START: <1-2 sentence plan>\"")
  add("  2. Work, annotating milestones:")
  add("       task <short_uuid> annotate \"PROGRESS: <what you just did>\"")
  add("  3. Record any files you created:")
  add("       task <short_uuid> annotate \"OUTPUT: </abs/path>\"")
  add("  4. Finish with a completion annotation AND mark the task done:")
  add("       task <short_uuid> annotate \"COMPLETE: <1-sentence summary>\"")
  add("       task <short_uuid> done")
  add("  5. If you genuinely cannot finish, leave it pending and annotate why:")
  add("       task <short_uuid> annotate \"BLOCKED: <why>\"")
  add("       task <short_uuid> stop")
  add("")
  add("Do not skip annotations. The user's only view into your progress is the")
  add("annotation feed — silence looks like the delegation failed.")
  add("")

  for i, info in ipairs(task_infos) do
    add(format_task_block(info, i, n))
    add("")
  end

  if extra_context and extra_context ~= "" then
    add("# Additional context from the user")
    add("")
    add(extra_context)
    add("")
  end

  add("# Completion signal")
  add("")
  add("When you are finished with ALL tasks above (or have marked any unfinishable")
  add("ones as BLOCKED), print the following banner verbatim on its own lines so")
  add("the user can spot it at a glance in the terminal:")
  add("")
  add("    ==================================================")
  add(string.format("    [TASKDELEGATE COMPLETE] %d task(s) processed", n))
  add("    ==================================================")

  return table.concat(p, "\n")
end

-- Back-compat wrapper used internally; takes a single (task, short_uuid) pair.
local function build_task_context(task, short_uuid, extra_context)
  return build_task_prompt({ { task = task, short_uuid = short_uuid } }, extra_context)
end

local function run_claude_in_terminal(prompt, opts)
  local cfg = require("task.config").options.delegate or {}
  local command = opts.command or cfg.command or "claude"
  local flags = opts.flags or cfg.flags or ""
  local system_prompt_file = opts.system_prompt_file or cfg.system_prompt_file
  local model = opts.model or cfg.model
  local height_frac = cfg.height or 0.5

  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(vim.split(prompt, "\n", { plain = true }), tmpfile)

  -- Build the argv. Interactive mode (no -p) keeps claude's TUI attached to
  -- the terminal so the user can follow up. The prompt is passed as a
  -- positional argument via command substitution from a tmpfile (handles
  -- newlines / shell metacharacters safely).
  local parts = { command }
  if flags and flags ~= "" then table.insert(parts, flags) end
  if model and model ~= "" then
    table.insert(parts, string.format("--model %s", vim.fn.shellescape(model)))
  end
  if system_prompt_file and system_prompt_file ~= "" then
    table.insert(parts, string.format("--append-system-prompt \"$(cat %s)\"",
      vim.fn.shellescape(vim.fn.expand(system_prompt_file))))
  end

  -- Pass the prompt as the first user turn via positional argument (not
  -- stdin — claude refuses to start its TUI if stdin isn't a TTY). After
  -- claude exits, keep the pane alive so the user can read its output.
  local shell_cmd = string.format(
    "%s \"$(cat %s)\"; rc=$?; rm -f %s; echo; echo \"[TaskDelegate] claude exited ($rc). Press any key to close.\"; read -n 1",
    table.concat(parts, " "),
    vim.fn.shellescape(tmpfile),
    vim.fn.shellescape(tmpfile))

  local height = math.floor(vim.o.lines * height_frac)
  vim.cmd(string.format("botright %dnew", height))
  local term_buf = vim.api.nvim_get_current_buf()
  vim.bo[term_buf].bufhidden = "wipe"
  vim.fn.termopen(shell_cmd, {
    on_exit = function()
      vim.schedule(function() vim.notify("TaskDelegate: session ended") end)
    end,
  })
  vim.cmd("startinsert")
end

-- Collect tasks for delegation. Returns a list of { task, short_uuid }. When
-- `range` is nil, returns just the task under the cursor. When `range` is
-- {line1, line2}, returns every task line in that range that has a UUID.
function M.delegate_collect(range)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return nil
  end

  local short_uuids = {}
  if range then
    local lines = vim.api.nvim_buf_get_lines(bufnr, range[1] - 1, range[2], false)
    for _, line in ipairs(lines) do
      local u = uuid_from_line(line)
      if u then table.insert(short_uuids, u) end
    end
  else
    local u = uuid_from_line(vim.api.nvim_get_current_line())
    if u then table.insert(short_uuids, u) end
  end

  if #short_uuids == 0 then
    vim.notify("task.nvim: no task UUID on cursor/range", vim.log.levels.WARN)
    return nil
  end

  local filter = table.concat(short_uuids, " ")
  local out, ok = run(
    string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", filter))
  if not ok or not out or out == "" then
    vim.notify("task.nvim: failed to export tasks", vim.log.levels.ERROR)
    return nil
  end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" or #tasks == 0 then
    vim.notify("task.nvim: failed to parse tasks", vim.log.levels.ERROR)
    return nil
  end

  -- Preserve the order in which short_uuids appeared in the buffer.
  local by_short = {}
  for _, t in ipairs(tasks) do
    if t.uuid then by_short[t.uuid:sub(1, 8)] = t end
  end
  local result = {}
  for _, s in ipairs(short_uuids) do
    local t = by_short[s]
    if t then table.insert(result, { task = t, short_uuid = s }) end
  end
  return result
end

-- Build the exact shell command that would launch claude with the given
-- prompt, honoring the current config + per-invocation overrides.
local function build_claude_command(prompt, opts)
  opts = opts or {}
  local cfg = require("task.config").options.delegate or {}
  local command = opts.command or cfg.command or "claude"
  local flags = opts.flags or cfg.flags or ""
  local system_prompt_file = opts.system_prompt_file or cfg.system_prompt_file
  local model = opts.model or cfg.model

  local parts = { command }
  if flags and flags ~= "" then table.insert(parts, flags) end
  if model and model ~= "" then
    table.insert(parts, string.format("--model %s", vim.fn.shellescape(model)))
  end
  if system_prompt_file and system_prompt_file ~= "" then
    table.insert(parts, string.format("--append-system-prompt \"$(cat %s)\"",
      vim.fn.shellescape(vim.fn.expand(system_prompt_file))))
  end
  return string.format("%s %s", table.concat(parts, " "), vim.fn.shellescape(prompt))
end

-- :TaskDelegate copy | copy-command
-- Builds the prompt (or command) for the task under cursor OR the selected
-- range, copies it to both `+` and `"` registers, and reports byte count.
function M.delegate_copy(mode, opts)
  opts = opts or {}
  local infos = M.delegate_collect(opts.range)
  if not infos then return end

  local prompt = build_task_prompt(infos, opts.extra_context or "")
  local payload, label
  if mode == "command" then
    payload = build_claude_command(prompt, opts)
    label = "command"
  else
    payload = prompt
    label = "prompt"
  end

  pcall(vim.fn.setreg, "+", payload)
  pcall(vim.fn.setreg, '"', payload)
  vim.notify(string.format(
    "task.nvim: copied %s (%d bytes, %d task%s) to + register",
    label, #payload, #infos, #infos == 1 and "" or "s"))
  return payload
end

-- Open a floating popup to collect extra context + flags before launching claude.
-- opts.range = { line1, line2 } for multi-task (visual-range) delegation.
function M.delegate_open_popup(opts)
  opts = opts or {}
  local infos = M.delegate_collect(opts.range)
  if not infos then return end

  local cfg = require("task.config").options.delegate or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local initial_lines = {
    "## Extra context",
    "",
    "",
    "",
    "## Flags",
    string.format("flags: %s", cfg.flags or ""),
    string.format("model: %s", cfg.model or ""),
    string.format("system-prompt-file: %s", cfg.system_prompt_file or ""),
    "",
    "Press <CR> or :w to launch claude.  Press q or <Esc> to cancel.",
    "",
    "---",
  }
  if #infos == 1 then
    table.insert(initial_lines, string.format("Task: %s", infos[1].task.description or "unknown"))
    table.insert(initial_lines, string.format("UUID: %s", infos[1].task.uuid or infos[1].short_uuid))
  else
    table.insert(initial_lines, string.format("Delegating %d tasks:", #infos))
    for _, info in ipairs(infos) do
      table.insert(initial_lines, string.format("  [%s] %s",
        info.short_uuid, (info.task.description or ""):sub(1, 60)))
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

  local width = math.min(80, math.floor(vim.o.columns * 0.7))
  local height = math.min(#initial_lines + 4, math.floor(vim.o.lines * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = (require("task.config").options.border_style or "rounded"),
    title = #infos > 1
      and string.format(" TaskDelegate (%d tasks) ", #infos)
      or " TaskDelegate ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  vim.cmd("startinsert")

  local function parse_form()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local extra = {}
    local flags_line, model_line, spf_line
    local section = "header"
    for _, l in ipairs(lines) do
      if l:match("^## Extra context") then
        section = "extra"
      elseif l:match("^## Flags") then
        section = "flags"
      elseif section == "extra" then
        table.insert(extra, l)
      elseif section == "flags" then
        local f = l:match("^flags:%s*(.*)")
        local m = l:match("^model:%s*(.*)")
        local s = l:match("^system%-prompt%-file:%s*(.*)")
        if f then flags_line = f end
        if m then model_line = m end
        if s then spf_line = s end
      end
    end
    while extra[1] == "" do table.remove(extra, 1) end
    while extra[#extra] == "" do table.remove(extra) end
    return {
      extra_context = table.concat(extra, "\n"),
      flags = flags_line,
      model = model_line,
      system_prompt_file = spf_line,
    }
  end

  local function submit()
    local form = parse_form()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    local prompt = build_task_prompt(infos, form.extra_context)
    run_claude_in_terminal(prompt, {
      flags = form.flags,
      model = form.model,
      system_prompt_file = form.system_prompt_file,
    })
  end

  local function cancel()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    vim.notify("TaskDelegate: cancelled")
  end

  vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, nowait = true, silent = true })
  vim.api.nvim_buf_create_user_command(buf, "W", submit, {})
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = submit })
end

-- ---------------------------------------------------------------------------
-- TaskStart / TaskStop — toggle active (start) state on the task under cursor
-- ---------------------------------------------------------------------------

function M.start_stop(which)
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_get_current_line()
  local short_uuid = uuid_from_line(line)
  if not short_uuid then
    vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
    return
  end
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off %s %s", short_uuid, which)
  local _, ok = run(cmd)
  if ok then
    vim.notify(string.format("task.nvim: %s %s", which, short_uuid))
    if vim.b[bufnr].task_filter ~= nil then refresh_buf(bufnr) end
  else
    vim.notify(string.format("task.nvim: %s failed", which), vim.log.levels.ERROR)
  end
end

-- ---------------------------------------------------------------------------
-- Saved views (:TaskSave / :TaskLoad)
-- ---------------------------------------------------------------------------

local function views_file_path()
  local data_dir = vim.fn.stdpath("data") .. "/task.nvim"
  vim.fn.mkdir(data_dir, "p")
  return data_dir .. "/saved-views.json"
end

local function read_saved_views()
  local path = views_file_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or not content or #content == 0 then return {} end
  local joined = table.concat(content, "\n")
  local parsed_ok, data = pcall(vim.fn.json_decode, joined)
  if not parsed_ok or type(data) ~= "table" then return {} end
  return data
end

local function write_saved_views(data)
  local path = views_file_path()
  local encoded = vim.fn.json_encode(data)
  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
end

function M.view_list_names()
  local data = read_saved_views()
  local names = {}
  for k, _ in pairs(data) do table.insert(names, k) end
  table.sort(names)
  return names
end

function M.view_save(name)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  local function finish(chosen)
    if not chosen or chosen == "" then return end
    local views = read_saved_views()
    views[chosen] = {
      filter = vim.b[bufnr].task_filter or "",
      sort = vim.b[bufnr].task_sort or "",
      group = vim.b[bufnr].task_group or "",
    }
    write_saved_views(views)
    vim.notify(string.format("task.nvim: saved view %q", chosen))
  end
  if name then finish(name) else
    vim.ui.input({ prompt = "Save view as: " }, finish)
  end
end

function M.view_load(name)
  local function finish(chosen)
    if not chosen or chosen == "" then return end
    local views = read_saved_views()
    local v = views[chosen]
    if not v then
      vim.notify(string.format("task.nvim: no saved view %q", chosen), vim.log.levels.WARN)
      return
    end
    M.open(v.filter or "")
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.b[bufnr].task_filter ~= nil then
      if v.sort and v.sort ~= "" then vim.b[bufnr].task_sort = v.sort end
      if v.group and v.group ~= "" then vim.b[bufnr].task_group = v.group end
      refresh_buf(bufnr)
    end
    vim.notify(string.format("task.nvim: loaded view %q", chosen))
  end
  if name then
    finish(name)
  else
    local names = M.view_list_names()
    if #names == 0 then
      vim.notify("task.nvim: no saved views", vim.log.levels.WARN)
      return
    end
    vim.ui.select(names, { prompt = "Load view:" }, finish)
  end
end

-- ---------------------------------------------------------------------------
-- Guided review mode (:TaskReview)
-- ---------------------------------------------------------------------------

function M.review()
  local out, ok = run(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on status:pending export")
  if not ok or not out or out == "" then
    vim.notify("task.nvim: failed to export tasks", vim.log.levels.ERROR)
    return
  end
  local js = out
  local s = js:find("%[")
  if s and s > 1 then js = js:sub(s) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, js)
  if not parsed_ok or type(tasks) ~= "table" or #tasks == 0 then
    vim.notify("task.nvim: no pending tasks", vim.log.levels.INFO)
    return
  end
  -- Sort by urgency desc for review order
  table.sort(tasks, function(a, b) return (a.urgency or 0) > (b.urgency or 0) end)

  local idx = 1
  local function step()
    if idx > #tasks then
      vim.notify(string.format("task.nvim: review complete (%d tasks)", #tasks))
      return
    end
    local t = tasks[idx]
    local short = t.uuid and t.uuid:sub(1, 8) or ""
    local lines = {
      string.format("[%d/%d]  %s", idx, #tasks, t.description or ""),
      string.format("project:%s  urgency:%.1f", t.project or "(none)", t.urgency or 0),
    }
    if t.due then table.insert(lines, string.format("due:%s", t.due)) end
    if t.tags and #t.tags > 0 then table.insert(lines, "tags:" .. table.concat(t.tags, ",")) end
    local header = table.concat(lines, "\n") .. "\n"
    local choices = {
      "k  Keep (next)",
      "d  Defer (set wait:tomorrow)",
      "x  Done",
      "m  Modify (prompt)",
      "g  Go to task buffer",
      "q  Quit review",
    }
    vim.ui.select(choices, {
      prompt = header .. "Action:",
      format_item = function(i) return i end,
    }, function(choice)
      if not choice then return end
      local key = choice:sub(1, 1)
      if key == "k" then
        idx = idx + 1; step()
      elseif key == "d" then
        run(string.format("task rc.bulk=0 rc.confirmation=off %s modify wait:tomorrow", short))
        idx = idx + 1; step()
      elseif key == "x" then
        run(string.format("task rc.bulk=0 rc.confirmation=off %s done", short))
        idx = idx + 1; step()
      elseif key == "m" then
        vim.ui.input({ prompt = "Modify " .. short .. ": " }, function(input)
          if input and input ~= "" then
            local esc = input:gsub("'", "'\\''")
            run(string.format("task rc.bulk=0 rc.confirmation=off %s modify '%s'", short, esc))
          end
          idx = idx + 1; step()
        end)
      elseif key == "g" then
        M.open("uuid:" .. short)
      elseif key == "q" then
        vim.notify(string.format("task.nvim: review paused at %d/%d", idx, #tasks))
      end
    end)
  end
  step()
end

function M.help()
  require("task.help").show(set_buf_lines)
end

function M.capture()
  ensure_setup()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "taskmd"

  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor(vim.o.lines / 2) - 1,
    style = "minimal",
    border = "rounded",
    title = " Task Add ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.cmd("startinsert")

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd("stopinsert")
  end

  vim.keymap.set("i", "<CR>", function()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    close()
    if line and line ~= "" then
      -- Write to temp file and use taskmd apply to avoid shell escaping issues
      -- with special characters (dashes, parens, plus signs, etc.)
      local escaped = line:gsub("'", "'\\''")
      local _, ok = run("task rc.bulk=0 rc.confirmation=off add -- '" .. escaped .. "'")
      if ok then
        vim.notify("task.nvim: added task")
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].task_filter ~= nil and vim.api.nvim_buf_is_valid(b) then
            refresh_buf(b)
          end
        end
      else
        vim.notify("task.nvim: add failed", vim.log.levels.ERROR)
      end
    end
  end, { buffer = buf })

  vim.keymap.set("i", "<Esc>", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf })
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

function M._setup_commands()
  vim.api.nvim_create_user_command("Task", function(cmd_opts)
    M.open(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Open Taskwarrior tasks as markdown",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  vim.api.nvim_create_user_command("TaskFilter", function(cmd_opts)
    M.filter(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Change task filter",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  vim.api.nvim_create_user_command("TaskRefresh", function()
    M.refresh()
  end, { nargs = 0, desc = "Refresh task buffer" })

  vim.api.nvim_create_user_command("TaskUndo", function()
    M.undo()
  end, { nargs = 0, desc = "Undo last save" })

  vim.api.nvim_create_user_command("TaskSort", function(cmd_opts)
    M.sort(cmd_opts.args)
  end, {
    nargs = 1,
    desc = "Change task sort order (e.g. due+, urgency-)",
    complete = function(arg_lead)
      local fields = { "urgency-", "urgency+", "due+", "due-", "priority-",
                       "priority+", "project+", "project-", "description+" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  vim.api.nvim_create_user_command("TaskGroup", function(cmd_opts)
    M.group(cmd_opts.args)
  end, {
    nargs = "?",
    desc = "Change task grouping (field name or 'none')",
    complete = function(arg_lead)
      local fields = { "project", "priority", "status", "tag", "none" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  vim.api.nvim_create_user_command("TaskAdd", function()
    M.capture()
  end, { nargs = 0, desc = "Quick-capture a new task" })

  vim.api.nvim_create_user_command("TaskHelp", function()
    M.help()
  end, { nargs = 0, desc = "Show task.nvim help" })

  vim.api.nvim_create_user_command("TaskProjectAdd", function(cmd_opts)
    local name = cmd_opts.args ~= "" and cmd_opts.args or nil
    M.project_add(name)
  end, { nargs = "?", desc = "Register cwd as a Taskwarrior project" })

  vim.api.nvim_create_user_command("TaskProjectRemove", function()
    M.project_remove()
  end, { nargs = 0, desc = "Unregister cwd as a Taskwarrior project" })

  vim.api.nvim_create_user_command("TaskProjectList", function()
    M.project_list()
  end, { nargs = 0, desc = "List registered projects" })

  vim.api.nvim_create_user_command("TaskDelegate", function(cmd_opts)
    local arg = cmd_opts.args or ""
    local has_range = cmd_opts.range > 0 and cmd_opts.line1 ~= cmd_opts.line2
    local range = has_range and { cmd_opts.line1, cmd_opts.line2 } or nil
    if arg == "copy" then
      return M.delegate_copy("prompt", { range = range })
    elseif arg == "copy-command" then
      return M.delegate_copy("command", { range = range })
    else
      return M.delegate_open_popup({ range = range })
    end
  end, {
    nargs = "?",
    range = true,
    desc = "Delegate task(s) under cursor or selection to Claude",
    complete = function() return { "copy", "copy-command" } end,
  })

  vim.api.nvim_create_user_command("TaskStart", function()
    M.start_stop("start")
  end, { nargs = 0, desc = "Start (activate) task under cursor" })

  vim.api.nvim_create_user_command("TaskStop", function()
    M.start_stop("stop")
  end, { nargs = 0, desc = "Stop (deactivate) task under cursor" })

  vim.api.nvim_create_user_command("TaskSave", function(cmd_opts)
    M.view_save(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, { nargs = "?", desc = "Save current filter/sort/group as a named view" })

  vim.api.nvim_create_user_command("TaskLoad", function(cmd_opts)
    M.view_load(cmd_opts.args ~= "" and cmd_opts.args or nil)
  end, {
    nargs = "?",
    desc = "Load a saved view by name",
    complete = function(arg_lead)
      local names = M.view_list_names()
      local r = {}
      for _, n in ipairs(names) do
        if n:sub(1, #arg_lead) == arg_lead then table.insert(r, n) end
      end
      return r
    end,
  })

  vim.api.nvim_create_user_command("TaskReview", function()
    M.review()
  end, { nargs = 0, desc = "Walk through pending tasks one at a time" })

  vim.api.nvim_create_user_command("TaskDiffPreview", function(cmd_opts)
    local dp = require("task.diff_preview")
    local a = cmd_opts.args
    if a == "on" then dp.enable()
    elseif a == "off" then dp.disable()
    else dp.toggle() end
  end, {
    nargs = "?",
    desc = "Toggle live diff preview (virtual text)",
    complete = function() return { "on", "off", "toggle" } end,
  })

  -- Visualization commands
  local views = require("task.views")

  vim.api.nvim_create_user_command("TaskBurndown", function()
    views.burndown()
  end, { nargs = 0, desc = "Show burndown chart" })

  vim.api.nvim_create_user_command("TaskTree", function()
    views.tree()
  end, { nargs = 0, desc = "Show dependency tree" })

  vim.api.nvim_create_user_command("TaskSummary", function()
    views.summary()
  end, { nargs = 0, desc = "Show project summary" })

  vim.api.nvim_create_user_command("TaskCalendar", function()
    views.calendar()
  end, { nargs = 0, desc = "Show calendar view of due dates" })

  vim.api.nvim_create_user_command("TaskTags", function()
    views.tags()
  end, { nargs = 0, desc = "Show tag distribution" })
end

-- ---------------------------------------------------------------------------
-- Lua API (for other plugins)
-- ---------------------------------------------------------------------------

-- Completion functions exposed for vim.fn.input() completion callbacks
-- Signature: (ArgLead, CmdLine, CursorPos) -> list of strings
function M._complete_filter(arg_lead, cmd_line, _cursor_pos)
  -- cmd_line contains the full input; arg_lead is the word under cursor
  -- For multi-word filters, complete the last word
  local words = vim.split(cmd_line, "%s+")
  local last = words[#words] or ""
  return complete_filter(last)
end

function M._complete_sort(arg_lead, _cmd_line, _cursor_pos)
  local fields = { "urgency-", "urgency+", "due+", "due-", "priority-",
                   "priority+", "project+", "project-", "description+" }
  local results = {}
  for _, f in ipairs(fields) do
    if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
  end
  return results
end

function M._complete_group(arg_lead, _cmd_line, _cursor_pos)
  local fields = { "project", "priority", "status", "tag", "none" }
  local results = {}
  for _, f in ipairs(fields) do
    if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
  end
  return results
end

M.api = {}

M.api.export = function(filter_args)
  filter_args = filter_args or {}
  local filter_str = type(filter_args) == "table" and table.concat(filter_args, " ") or filter_args
  local cmd = string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export",
    filter_str)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return {} end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return {} end
  return tasks
end

M.api.get_task_on_cursor = function()
  local line = vim.api.nvim_get_current_line()
  local short_uuid = uuid_from_line(line)
  if not short_uuid then return nil end
  local tasks = M.api.export({ short_uuid })
  return tasks[1]
end

M.api.detect_project = detect_project
M.api.get_completions = get_tw_completions
M.api.refresh = function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].task_filter ~= nil and vim.api.nvim_buf_is_valid(b) then
      refresh_buf(b)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  require("task.config").setup(opts)

  local config = require("task.config")
  local gopts = { noremap = true, silent = true }

  -- Global keymaps
  if config.options.capture_key then
    vim.keymap.set("n", config.options.capture_key, M.capture,
      vim.tbl_extend("force", gopts, { desc = "task.nvim: Quick-capture task" }))
  end

  if config.options.open_key then
    vim.keymap.set("n", config.options.open_key, function() M.open() end,
      vim.tbl_extend("force", gopts, { desc = "task.nvim: Open tasks" }))
  end

  if config.options.project_add_key then
    vim.keymap.set("n", config.options.project_add_key, function()
      vim.ui.input({
        prompt = "Project name: ",
        default = vim.fn.fnamemodify(vim.fn.getcwd(), ":t"),
      }, function(name)
        if name and name ~= "" then M.project_add(name) end
      end)
    end, vim.tbl_extend("force", gopts, { desc = "task.nvim: Register cwd as project" }))
  end

  M._setup_commands()
end

return M
