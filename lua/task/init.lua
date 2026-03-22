local M = {}

local HELP_TEXT = [[
task.nvim — Taskwarrior as Markdown
====================================

COMMANDS
  :Task [filter...]     Open tasks matching filter
  :TaskFilter [filter]  Change the active filter and re-render
  :TaskRefresh          Re-render without changing filter
  :TaskUndo             Undo the last save (repeats task undo N times)
  :TaskHelp             Show this help

KEYBINDINGS (task buffers)
  <CR>   Toggle [ ] / [x] on the current line
  o      Insert a new task line below and enter insert mode
  O      Insert a new task line above and enter insert mode
  ga     Annotate the task on the current line (prompts for text)
  gf     Show exported task data for the task on the current line

SYNTAX
  - [ ] description [field:value...] [+tag...] <!-- uuid:XXXXXXXX -->
  - [x] completed task

FIELDS
  project: priority: due: scheduled: recur: wait: until: effort:
]]

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

local function render(filter, sort, group)
  local taskmd = get_taskmd_path()
  local config = require("task.config")

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
    vim.notify("task.nvim: render failed\n" .. out, vim.log.levels.ERROR)
    return nil
  end
  return out
end

local function set_buf_lines(bufnr, text)
  local lines = vim.split(text or "", "\n", { plain = true })
  -- strip trailing empty line that split may add
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

local function refresh_buf(bufnr)
  local filter = vim.b[bufnr].task_filter or ""
  local sort   = vim.b[bufnr].task_sort
  local group  = vim.b[bufnr].task_group
  local out = render(filter, sort, group)
  if not out then return end
  set_buf_lines(bufnr, out)
  vim.bo[bufnr].modified = false
end

local function setup_buf_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    -- Base markdown syntax
    vim.cmd("runtime! syntax/markdown.vim")

    -- Conceal UUIDs
    vim.cmd("syntax match TaskUUID /<!\\-\\-.*uuid:[0-9a-fA-F]\\{8\\}.*\\-\\->/ conceal")

    -- Priority highlighting
    vim.cmd("syntax match TaskPriorityH /priority:H/ containedin=ALL")
    vim.cmd("syntax match TaskPriorityM /priority:M/ containedin=ALL")
    vim.cmd("syntax match TaskPriorityL /priority:L/ containedin=ALL")

    -- Date highlighting
    vim.cmd("syntax match TaskDue /due:\\d\\{4\\}-\\d\\{2\\}-\\d\\{2\\}/ containedin=ALL")
    vim.cmd("syntax match TaskScheduled /scheduled:\\d\\{4\\}-\\d\\{2\\}-\\d\\{2\\}/ containedin=ALL")
    vim.cmd("syntax match TaskWait /wait:\\d\\{4\\}-\\d\\{2\\}-\\d\\{2\\}/ containedin=ALL")

    -- Tags
    vim.cmd("syntax match TaskTag /+\\w\\+/ containedin=ALL")

    -- Project (when not grouped)
    vim.cmd("syntax match TaskProject /project:\\S\\+/ containedin=ALL")

    -- Recurrence and effort
    vim.cmd("syntax match TaskRecur /recur:\\S\\+/ containedin=ALL")
    vim.cmd("syntax match TaskEffort /effort:\\S\\+/ containedin=ALL")

    -- Completed tasks (dim the whole line)
    vim.cmd("syntax match TaskCompleted /^- \\[x\\].*$/ containedin=ALL")

    -- Header comment (the <!-- taskmd ... --> line)
    vim.cmd("syntax match TaskHeader /^<!--.*-->$/ containedin=ALL")

    -- Link highlights to colors
    vim.cmd("highlight TaskPriorityH guifg=#f38ba8 gui=bold")  -- red
    vim.cmd("highlight TaskPriorityM guifg=#fab387 gui=bold")  -- peach/orange
    vim.cmd("highlight TaskPriorityL guifg=#a6e3a1")            -- green
    vim.cmd("highlight TaskDue guifg=#f9e2af")                  -- yellow
    vim.cmd("highlight TaskScheduled guifg=#f9e2af")
    vim.cmd("highlight TaskWait guifg=#9399b2")                 -- dim
    vim.cmd("highlight TaskTag guifg=#89b4fa")                  -- blue
    vim.cmd("highlight TaskProject guifg=#94e2d5")              -- teal
    vim.cmd("highlight TaskRecur guifg=#cba6f7")                -- mauve
    vim.cmd("highlight TaskEffort guifg=#9399b2")               -- dim
    vim.cmd("highlight TaskCompleted guifg=#585b70")            -- very dim (strikethrough feel)
    vim.cmd("highlight TaskHeader guifg=#45475a")               -- near-invisible
  end)
end

local function setup_buf_keymaps(bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Toggle [ ] / [x]
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local toggled
    if line:match("^%- %[x%]") then
      toggled = line:gsub("^%- %[x%]", "- [ ]", 1)
    elseif line:match("^%- %[ %]") then
      toggled = line:gsub("^%- %[ %]", "- [x]", 1)
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
        refresh_buf(bufnr)
      else
        vim.notify("task.nvim: annotation failed", vim.log.levels.ERROR)
      end
    end)
  end, opts)

  -- Show task export in split
  vim.keymap.set("n", "gf", function()
    local line = vim.api.nvim_get_current_line()
    local short_uuid = uuid_from_line(line)
    if not short_uuid then
      vim.notify("task.nvim: no UUID on this line", vim.log.levels.WARN)
      return
    end
    local out, ok = run(
      string.format("task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", short_uuid)
    )
    if not ok or out == "" then
      vim.notify("task.nvim: export failed", vim.log.levels.ERROR)
      return
    end
    local detail_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[detail_buf].buftype = "nofile"
    vim.bo[detail_buf].filetype = "json"
    set_buf_lines(detail_buf, out)
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, detail_buf)
  end, opts)
end

local function setup_buf_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("TaskNvim_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    group = group,
    callback = function()
      M._on_write(bufnr)
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
end

-- ---------------------------------------------------------------------------
-- Write handler
-- ---------------------------------------------------------------------------

function M._on_write(bufnr)
  local config = require("task.config")
  local taskmd = get_taskmd_path()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(lines, tmpfile)

  local on_delete = config.options.on_delete or "done"

  if config.options.confirm then
    local dry_cmd = string.format(
      "%s apply --dry-run --on-delete=%s %s",
      taskmd, on_delete, vim.fn.shellescape(tmpfile)
    )
    local dry_out, dry_ok = run(dry_cmd)
    if not dry_ok then
      vim.notify("task.nvim: dry-run failed\n" .. dry_out, vim.log.levels.ERROR)
      vim.fn.delete(tmpfile)
      return
    end

    local ok, decoded = pcall(vim.fn.json_decode, dry_out)
    if not ok or type(decoded) ~= "table" then
      vim.notify("task.nvim: could not parse dry-run output", vim.log.levels.ERROR)
      vim.fn.delete(tmpfile)
      return
    end

    local actions = decoded.actions or {}
    if #actions == 0 then
      vim.notify("task.nvim: no changes")
      vim.bo[bufnr].modified = false
      vim.fn.delete(tmpfile)
      return
    end

    local labels = {}
    for _, action in ipairs(actions) do
      local desc = action.description or (action.fields and action.fields.description) or ""
      if action.type == "add" then
        table.insert(labels, string.format("+ Add: %q", desc))
      elseif action.type == "modify" then
        local parts = {}
        for k, v in pairs(action.fields or {}) do
          table.insert(parts, string.format("%s -> %s", k, tostring(v)))
        end
        table.insert(labels, string.format("~ Modify: %q (%s)", desc, table.concat(parts, ", ")))
      elseif action.type == "done" then
        table.insert(labels, string.format("v Done: %q", desc))
      elseif action.type == "delete" then
        table.insert(labels, string.format("x Delete: %q", desc))
      end
    end

    local preview = table.concat(labels, "\n")
    vim.ui.select({ "Apply", "Cancel" }, {
      prompt = string.format("Apply %d change(s)?\n%s", #actions, preview),
    }, function(choice)
      if choice ~= "Apply" then
        vim.notify("task.nvim: cancelled")
        vim.fn.delete(tmpfile)
        return
      end
      M._do_apply(bufnr, taskmd, tmpfile, on_delete)
    end)
  else
    M._do_apply(bufnr, taskmd, tmpfile, on_delete)
  end
end

function M._do_apply(bufnr, taskmd, tmpfile, on_delete)
  local cmd = string.format(
    "%s apply --on-delete=%s %s",
    taskmd, on_delete, vim.fn.shellescape(tmpfile)
  )
  local out, ok = run(cmd)
  vim.fn.delete(tmpfile)

  if not ok then
    vim.notify("task.nvim: apply failed\n" .. out, vim.log.levels.ERROR)
    return
  end

  local parsed_ok, summary = pcall(vim.fn.json_decode, out)
  if parsed_ok and type(summary) == "table" then
    vim.b[bufnr].task_last_action_count = summary.action_count or 0
    local msg = string.format(
      "Applied: +%d added, ~%d modified, v%d done",
      summary.added or 0,
      summary.modified or 0,
      summary.completed or 0
    )
    if (summary.deleted or 0) > 0 then
      msg = msg .. string.format(", x%d deleted", summary.deleted)
    end
    vim.notify(msg)
  else
    vim.notify("task.nvim: applied (could not parse summary)")
    vim.b[bufnr].task_last_action_count = 0
  end

  refresh_buf(bufnr)
  vim.bo[bufnr].modified = false
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.open(filter_str)
  local config = require("task.config")
  filter_str = filter_str or ""
  local sort = config.options.sort or "urgency-"
  local group = config.options.group

  local out = render(filter_str, sort, group)
  if not out then return end

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "taskmd"

  set_buf_lines(bufnr, out)
  vim.bo[bufnr].modified = false

  vim.b[bufnr].task_filter = filter_str
  vim.b[bufnr].task_sort = sort
  vim.b[bufnr].task_group = group

  setup_buf_syntax(bufnr)
  setup_buf_keymaps(bufnr)
  setup_buf_autocmds(bufnr)

  vim.api.nvim_win_set_buf(0, bufnr)
  vim.wo[0].conceallevel = 3
  vim.wo[0].concealcursor = "nvic"
  vim.api.nvim_buf_set_name(bufnr, "Tasks: " .. filter_str)
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

function M.help()
  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[help_buf].buftype = "nofile"
  vim.bo[help_buf].filetype = "markdown"
  set_buf_lines(help_buf, HELP_TEXT)
  vim.bo[help_buf].modifiable = false
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, help_buf)
  vim.api.nvim_buf_set_name(help_buf, "task.nvim Help")
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

function M._setup_commands()
  vim.api.nvim_create_user_command("Task", function(cmd_opts)
    M.open(cmd_opts.args)
  end, { nargs = "*", desc = "Open Taskwarrior tasks as markdown" })

  vim.api.nvim_create_user_command("TaskFilter", function(cmd_opts)
    M.filter(cmd_opts.args)
  end, { nargs = "*", desc = "Change task filter" })

  vim.api.nvim_create_user_command("TaskRefresh", function()
    M.refresh()
  end, { nargs = 0, desc = "Refresh task buffer" })

  vim.api.nvim_create_user_command("TaskUndo", function()
    M.undo()
  end, { nargs = 0, desc = "Undo last save" })

  vim.api.nvim_create_user_command("TaskHelp", function()
    M.help()
  end, { nargs = 0, desc = "Show task.nvim help" })
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  require("task.config").setup(opts)
  M._setup_commands()
end

return M
