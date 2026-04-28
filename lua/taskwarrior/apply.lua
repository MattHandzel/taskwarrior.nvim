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

-- Format a single conflict entry for inclusion in the confirm-prompt preview
-- or non-confirm error message.
local function fmt_conflict(c)
  local desc = c.description
  if desc == nil or desc == "" then desc = c.uuid or c.short_uuid or "?" end
  if c.type == "external_modify" then
    return string.format("! conflict: %q was modified both in the buffer AND externally", desc)
  elseif c.type == "external_delete" then
    return string.format("- info: %q is in the buffer but no longer in Taskwarrior (deleted or filter-moved externally) — buffer line ignored", desc)
  elseif c.type == "external_add" then
    return string.format("+ info: %q was added/changed externally after render — preserved, will appear on next refresh", desc)
  else
    return string.format("! conflict (%s): %s", c.type or "unknown", desc)
  end
end

-- Split conflicts into the BLOCKING set (real merge decisions for the user)
-- and the INFORMATIONAL set (out-of-band adds/deletes that just need to be
-- mentioned, not chosen between). Only `external_modify` is blocking — both
-- sides changed the same task and only the user can pick a winner.
local function partition_conflicts(conflicts)
  local blocking, info = {}, {}
  for _, c in ipairs(conflicts or {}) do
    if c.type == "external_modify" then
      table.insert(blocking, c)
    else
      table.insert(info, c)
    end
  end
  return blocking, info
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
-- do_apply_fn: callback(bufnr, tmpfile, on_delete, opts) — used for the confirm path
function M.on_write(bufnr, refresh_fn, do_apply_fn)
  local config = require("taskwarrior.config")

  -- Capture :w! up-front: vim.v.cmdbang is set during the BufWriteCmd and may
  -- be clobbered by any nested Ex command we run before we branch on it.
  local force = vim.v.cmdbang == 1

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(lines, tmpfile)

  local on_delete = config.options.on_delete or "done"

  if config.options.confirm then
    local decoded, err = do_apply({
      tmpfile = tmpfile,
      dry_run = true,
      on_delete = on_delete,
      force = force,
    })
    if not decoded then
      vim.notify("taskwarrior.nvim: dry-run failed\n" .. (err or ""), vim.log.levels.ERROR)
      vim.fn.delete(tmpfile)
      return
    end

    local actions = decoded.actions or {}
    local conflicts = decoded.conflicts or {}
    local blocking, info = partition_conflicts(conflicts)
    if #actions == 0 and #blocking == 0 and #info == 0 then
      vim.notify("taskwarrior.nvim: no changes")
      vim.bo[bufnr].modified = false
      vim.fn.delete(tmpfile)
      return
    end

    -- Surface informational conflicts (external add/delete) once, up-front.
    -- They don't require a decision, so they don't appear in the prompt.
    if #info > 0 then
      local info_lines = { string.format("taskwarrior.nvim: %d external change(s) detected since render:", #info) }
      for _, c in ipairs(info) do table.insert(info_lines, "  " .. fmt_conflict(c)) end
      vim.notify(table.concat(info_lines, "\n"))
    end

    local labels = {}
    if #blocking > 0 then
      for _, c in ipairs(blocking) do
        table.insert(labels, fmt_conflict(c))
      end
      if #actions > 0 then table.insert(labels, "") end
    end
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

    if #actions == 0 and #blocking == 0 then
      -- Only informational conflicts — apply (no actions to run, but refreshes
      -- the buffer to pick up the externally-added/removed tasks).
      do_apply_fn(bufnr, tmpfile, on_delete, { force = false })
      return
    end

    local preview = table.concat(labels, "\n")

    local choices
    local prompt
    if #blocking > 0 then
      choices = {
        "Apply safe (skip conflicts)",
        "Apply force (overwrite external changes)",
        "Cancel",
      }
      prompt = string.format(
        "%d change(s), %d conflict(s):\n%s",
        #actions, #blocking, preview)
    else
      choices = { "Apply", "Cancel" }
      prompt = string.format("Apply %d change(s)?\n%s", #actions, preview)
    end

    vim.ui.select(choices, { prompt = prompt }, function(choice)
      if not choice or choice == "Cancel" then
        vim.notify("taskwarrior.nvim: cancelled")
        vim.fn.delete(tmpfile)
        return
      end
      local apply_force = choice == "Apply force (overwrite external changes)"
      do_apply_fn(bufnr, tmpfile, on_delete, { force = apply_force })
    end)
  else
    if not force then
      -- Non-confirm mode: dry-run first. Only BLOCKING conflicts (real merge
      -- decisions on the same task) abort the write — informational external
      -- adds/deletes are surfaced and the save proceeds.
      local dry, derr = do_apply({
        tmpfile = tmpfile,
        dry_run = true,
        on_delete = on_delete,
        force = false,
      })
      if not dry then
        vim.notify("taskwarrior.nvim: dry-run failed\n" .. (derr or ""), vim.log.levels.ERROR)
        vim.fn.delete(tmpfile)
        return
      end
      local actions = dry.actions or {}
      local blocking, info = partition_conflicts(dry.conflicts or {})
      if #blocking > 0 then
        local lines_out = { "taskwarrior.nvim: refusing to save — merge conflict on:" }
        for _, c in ipairs(blocking) do table.insert(lines_out, "  " .. fmt_conflict(c)) end
        table.insert(lines_out, "Reload the buffer (`:TaskRefresh` or `:e`) and re-apply, or use `:w!` to force.")
        vim.notify(table.concat(lines_out, "\n"), vim.log.levels.ERROR)
        vim.fn.delete(tmpfile)
        return
      end
      if #info > 0 then
        local info_lines = { string.format("taskwarrior.nvim: %d external change(s) detected since render:", #info) }
        for _, c in ipairs(info) do table.insert(info_lines, "  " .. fmt_conflict(c)) end
        vim.notify(table.concat(info_lines, "\n"))
      end
      -- Zero local actions ⇒ skip the apply pipeline entirely. A clean :w on
      -- an unchanged buffer feels free of side effects, and even when
      -- informational external changes were surfaced above, there is nothing
      -- for `task modify` to do.
      if #actions == 0 then
        vim.fn.delete(tmpfile)
        vim.bo[bufnr].modified = false
        return
      end
    end
    do_apply_fn(bufnr, tmpfile, on_delete, { force = force })
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
-- opts: optional { force = bool } — force skips external-change protections.
function M.do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_fn, opts)
  opts = opts or {}
  backup_taskdata()
  local summary, err = do_apply({
    tmpfile = tmpfile,
    on_delete = on_delete,
    force = opts.force == true,
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
  local n_conflicts = summary.conflicts and #summary.conflicts or 0
  if n_conflicts > 0 and not opts.force then
    msg = msg .. string.format(" (%d conflict(s) skipped)", n_conflicts)
  end
  if summary.errors and #summary.errors > 0 then
    msg = msg .. string.format(" (%d errors!)", #summary.errors)
    vim.notify(msg, vim.log.levels.WARN)
  elseif (summary.action_count or 0) > 0 then
    vim.notify(msg)
  end

  refresh_fn(bufnr)
  vim.bo[bufnr].modified = false
end

return M
