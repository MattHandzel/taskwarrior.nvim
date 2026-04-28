-- taskwarrior/granulation.lua — auto-stop active tasks after a period of
-- nvim-wide idle. Opt-in via `granulation.enabled = true`.
--
-- Design:
--   • A single timer runs plugin-wide (not per-buffer). Any user activity
--     (CursorMoved/Hold, TextChanged, FocusGained/Lost) resets it.
--   • When the timer fires, we export all started tasks and `task <uuid> stop`
--     each one. Multiple started tasks would be unusual but the TW UI allows
--     it, so the plugin handles the general case.
--   • On FocusLost we *also* schedule an immediate check at `idle_ms` ahead.
--     If the user never regains focus in that window, tasks are stopped even
--     though CursorHold wouldn't have fired (CursorHold requires focus).
--
-- Public surface:
--   M.setup()        — register autocmds / timer according to config
--   M.stop_all_now() — force-stop every started task (used on VimLeavePre)

local M = {}

local timer = nil
local augroup = nil

local function run(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error == 0
end

-- Return a list of { uuid, description } for every currently-started task.
local function list_started()
  local out, ok = run(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on +ACTIVE export")
  if not ok or not out or out == "" then return {} end
  local js = out:find("%[")
  if js and js > 1 then out = out:sub(js) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return {} end
  local started = {}
  for _, t in ipairs(tasks) do
    if t.start and t.uuid then
      table.insert(started, { uuid = t.uuid, description = t.description or "" })
    end
  end
  return started
end

local function stop_all(reason)
  local started = list_started()
  if #started == 0 then return end
  local config = require("taskwarrior.config")
  local notify = require("taskwarrior.notify")
  for _, t in ipairs(started) do
    run(string.format("task rc.bulk=0 rc.confirmation=off %s stop",
      t.uuid:sub(1, 8)))
  end
  if config.options.granulation.notify_on_stop ~= false then
    notify("stop", string.format(
      "taskwarrior.nvim: auto-stopped %d task%s (%s)",
      #started, #started > 1 and "s" or "", reason or "idle"))
  end
  -- Refresh any visible task buffers so the [>] markers drop.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter ~= nil then
      pcall(function() require("taskwarrior.buffer").refresh_buf(b) end)
    end
  end
end

M.stop_all_now = function() stop_all("VimLeavePre") end

local function reset_timer()
  if timer then
    pcall(vim.fn.timer_stop, timer)
    timer = nil
  end
  local config = require("taskwarrior.config")
  local g = config.options.granulation or {}
  if not g.enabled then return end
  local ms = math.max(1000, g.idle_ms or (5 * 60 * 1000))
  timer = vim.fn.timer_start(ms, function()
    timer = nil
    vim.schedule(function() stop_all("idle") end)
  end)
end

function M.setup()
  local config = require("taskwarrior.config")
  local g = config.options.granulation or {}
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  if timer then
    pcall(vim.fn.timer_stop, timer)
    timer = nil
  end
  if not g.enabled then return end

  augroup = vim.api.nvim_create_augroup("TaskwarriorGranulation", { clear = true })
  -- Any keyboard / focus activity resets the idle timer.
  vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI", "CursorHold", "CursorHoldI",
      "TextChanged", "TextChangedI", "InsertEnter", "FocusGained" },
    {
      group = augroup,
      callback = reset_timer,
    })

  -- On focus loss, immediately queue the stop rather than waiting on CursorHold
  -- (which won't fire without focus).
  vim.api.nvim_create_autocmd("FocusLost", {
    group = augroup,
    callback = reset_timer,
  })

  -- Safety net: stop tasks when nvim exits cleanly.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function() stop_all("VimLeavePre") end,
  })

  reset_timer()
end

return M
