local M = {}

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

-- Apply helper: runs Lua backend if configured, else shells to bin/taskmd.
-- Returns (result_table, error_string_or_nil).
local function do_apply(opts)
  -- opts: { content=str, tmpfile=str, dry_run=bool, on_delete=str, force=bool }
  local config = require("task.config")
  if config.options.backend ~= "python" then
    local ok_m, tm = pcall(require, "task.taskmd")
    if ok_m then
      local ok_a, result = pcall(tm.apply, {
        content = opts.content,
        file = opts.tmpfile,
        dry_run = opts.dry_run,
        on_delete = opts.on_delete,
        force = opts.force,
      })
      if ok_a and type(result) == "table" then return result, nil end
      vim.notify("task.nvim: Lua backend apply failed (" .. tostring(result) .. "); falling back to Python",
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
  local config = require("task.config")

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
      vim.notify("task.nvim: dry-run failed\n" .. (err or ""), vim.log.levels.ERROR)
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
      do_apply_fn(bufnr, tmpfile, on_delete)
    end)
  else
    do_apply_fn(bufnr, tmpfile, on_delete)
  end
end

-- do_apply_and_refresh: apply tmpfile and refresh the buffer.
-- refresh_fn: callback(bufnr) to re-render
function M.do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_fn)
  local summary, err = do_apply({
    tmpfile = tmpfile,
    on_delete = on_delete,
  })
  vim.fn.delete(tmpfile)
  if not summary then
    vim.notify("task.nvim: apply failed\n" .. (err or ""), vim.log.levels.ERROR)
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
