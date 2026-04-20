local M = {}

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

-- Backup the Taskwarrior data directory before applying changes. Best-effort:
-- failures are reported but do not block the apply.
local function backup_taskdata()
  local config = require("taskwarrior.config")
  if not config.options.auto_backup then return end
  local ok, taskdata_raw = pcall(vim.fn.system, "task _get rc.data.location 2>/dev/null")
  if not ok then return end
  local taskdata = tostring(taskdata_raw or ""):gsub("%s+$", "")
  if taskdata == "" or vim.fn.isdirectory(taskdata) ~= 1 then return end
  local data = vim.fn.stdpath("data")
  local dest_root = data .. "/taskwarrior.nvim/backups"
  -- Migrate from pre-rename data dir (task.nvim → taskwarrior.nvim, v1.3.0).
  local old_root = data .. "/task.nvim/backups"
  if vim.fn.isdirectory(old_root) == 1 and vim.fn.isdirectory(dest_root) == 0 then
    vim.fn.mkdir(data .. "/taskwarrior.nvim", "p")
    pcall(vim.loop.fs_rename, old_root, dest_root)
  end
  vim.fn.mkdir(dest_root, "p")
  local stamp = os.date("%Y-%m-%d-%H%M%S")
  local dest = dest_root .. "/" .. stamp
  local copy_ok, copy_err = pcall(function()
    vim.fn.system(string.format("cp -a %s %s",
      vim.fn.shellescape(taskdata), vim.fn.shellescape(dest)))
  end)
  if not copy_ok then
    vim.notify("taskwarrior.nvim: auto-backup failed (" .. tostring(copy_err) .. ")",
      vim.log.levels.WARN)
    return
  end
  -- Prune: keep the N most recent.
  local keep = tonumber(config.options.auto_backup_keep) or 10
  if keep < 1 then keep = 1 end
  local entries = vim.fn.glob(dest_root .. "/*", true, true)
  table.sort(entries)
  while #entries > keep do
    local oldest = table.remove(entries, 1)
    pcall(vim.fn.delete, oldest, "rf")
  end
end

-- Apply helper: runs Lua backend if configured, else shells to bin/taskmd.
-- Returns (result_table, error_string_or_nil).
local function do_apply(opts)
  -- opts: { content=str, tmpfile=str, dry_run=bool, on_delete=str, force=bool }
  local config = require("taskwarrior.config")
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "taskwarrior.taskmd")
    if ok_m then
      local ok_a, result = pcall(tm.apply, {
        content = opts.content,
        file = opts.tmpfile,
        dry_run = opts.dry_run,
        on_delete = opts.on_delete,
        force = opts.force,
      })
      if ok_a and type(result) == "table" then return result, nil end
      vim.notify("taskwarrior.nvim: Lua backend apply failed (" .. tostring(result) .. "); falling back to Python",
        vim.log.levels.WARN)
    end
  end
  local taskmd = get_taskmd_path()
  local flags = {}
  if opts.dry_run then table.insert(flags, "--dry-run") end
  if opts.force then table.insert(flags, "--force") end
  table.insert(flags, "--on-delete=" .. (opts.on_delete or "done"))
  local cmd = string.format("%s apply %s %s",
    taskmd, table.concat(flags, " "), vim.fn.shellescape(opts.tmpfile))
  local out, ok = run(cmd)
  if not ok then return nil, out end
  local ok2, decoded = pcall(vim.fn.json_decode, out)
  if not ok2 or type(decoded) ~= "table" then return nil, "could not parse output" end
  return decoded, nil
end

-- on_write: BufWriteCmd handler.
-- refresh_fn: callback(bufnr) to re-render (avoids circular require with init)
-- do_apply_fn: callback(bufnr, tmpfile, on_delete) — used for the confirm path
function M.on_write(bufnr, refresh_fn, do_apply_fn)
  local config = require("taskwarrior.config")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(lines, tmpfile)

  local on_delete = config.options.on_delete or "done"

  if config.options.confirm then
    local decoded, err = do_apply({
      tmpfile = tmpfile,
      dry_run = true,
      on_delete = on_delete,
    })
    if not decoded then
      vim.notify("taskwarrior.nvim: dry-run failed\n" .. (err or ""), vim.log.levels.ERROR)
      vim.fn.delete(tmpfile)
      return
    end

    local actions = decoded.actions or {}
    if #actions == 0 then
      vim.notify("taskwarrior.nvim: no changes")
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
      elseif action.type == "start" then
        table.insert(labels, string.format("> Start: %q", desc))
      elseif action.type == "stop" then
        table.insert(labels, string.format("o Stop: %q", desc))
      else
        table.insert(labels, string.format("? %s: %q", action.type, desc))
      end
    end

    local preview = table.concat(labels, "\n")
    vim.ui.select({ "Apply", "Cancel" }, {
      prompt = string.format("Apply %d change(s)?\n%s", #actions, preview),
    }, function(choice)
      if choice ~= "Apply" then
        vim.notify("taskwarrior.nvim: cancelled")
        vim.fn.delete(tmpfile)
        return
      end
      do_apply_fn(bufnr, tmpfile, on_delete)
    end)
  else
    do_apply_fn(bufnr, tmpfile, on_delete)
  end
end

-- undo: walk back the last N taskwarrior actions recorded on bufnr.
-- refresh_fn: callback(bufnr) to re-render after undo completes.
function M.undo(bufnr, refresh_fn)
  local count = vim.b[bufnr].task_last_action_count
  if not count or count == 0 then
    vim.notify("taskwarrior.nvim: nothing to undo")
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
      vim.notify(string.format("taskwarrior.nvim: undo completed (%d failed)", failed), vim.log.levels.WARN)
    else
      vim.notify(string.format("taskwarrior.nvim: undid %d action(s)", count))
    end
    refresh_fn(bufnr)
  end)
end

-- do_apply_and_refresh: apply tmpfile and refresh the buffer.
-- refresh_fn: callback(bufnr) to re-render
function M.do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_fn)
  backup_taskdata()
  local summary, err = do_apply({
    tmpfile = tmpfile,
    on_delete = on_delete,
  })
  vim.fn.delete(tmpfile)
  if not summary then
    vim.notify("taskwarrior.nvim: apply failed\n" .. (err or ""), vim.log.levels.ERROR)
    return
  end
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
  if summary.errors and #summary.errors > 0 then
    msg = msg .. string.format(" (%d errors!)", #summary.errors)
    vim.notify(msg, vim.log.levels.WARN)
  else
    vim.notify(msg)
  end

  refresh_fn(bufnr)
  vim.bo[bufnr].modified = false
end

return M
