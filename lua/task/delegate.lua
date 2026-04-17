local M = {}

local function run(cmd)
  local out = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  return out, ok
end

local function uuid_from_line(line)
  return line:match("<!%-%-.*uuid:([0-9a-fA-F]+).*%-%->")
end

-- Legacy single-task export helper (back-compat for M.delegate in init.lua).
function M.delegate_one()
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
  return tasks[1], short_uuid
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
function M.collect(range)
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
function M.copy(mode, opts)
  opts = opts or {}
  local infos = M.collect(opts.range)
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
function M.open_popup(opts)
  opts = opts or {}
  local infos = M.collect(opts.range)
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

return M
