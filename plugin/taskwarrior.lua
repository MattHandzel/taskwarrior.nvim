-- taskwarrior.nvim plugin entrypoint.
-- Registers user commands even if the user hasn't called setup() yet. Each
-- command lazy-loads the real module and forwards args, so startup cost is
-- essentially zero for users who never run :Task.

if vim.g.loaded_taskwarrior == 1 then return end
vim.g.loaded_taskwarrior = 1

if vim.fn.has("nvim-0.9") ~= 1 then
  vim.notify("taskwarrior.nvim requires Neovim >= 0.9", vim.log.levels.ERROR)
  return
end

local function lazy(method)
  return function(cmd_opts)
    local ok, task = pcall(require, "taskwarrior")
    if not ok then
      vim.notify("taskwarrior.nvim: failed to load — " .. tostring(task), vim.log.levels.ERROR)
      return
    end
    -- Ensure setup() has run at least once so config defaults are populated.
    if type(task.setup) == "function" and not vim.g._taskwarrior_setup_done then
      pcall(task.setup, {})
      vim.g._taskwarrior_setup_done = 1
    end
    local fn = task[method]
    if type(fn) ~= "function" then
      vim.notify("taskwarrior.nvim: method not available — " .. method, vim.log.levels.ERROR)
      return
    end
    return fn(cmd_opts and cmd_opts.args or nil, cmd_opts)
  end
end

-- Primary command. All other commands are created inside setup() — we only
-- define :Task here as the lazy entrypoint so users get a clear error rather
-- than "command not found" when they haven't called setup() yet.
vim.api.nvim_create_user_command("Task", function(cmd_opts)
  local ok, task = pcall(require, "taskwarrior")
  if not ok then
    vim.notify("taskwarrior.nvim: failed to load — " .. tostring(task), vim.log.levels.ERROR)
    return
  end
  if type(task.setup) == "function" and not vim.g._taskwarrior_setup_done then
    pcall(task.setup, {})
    vim.g._taskwarrior_setup_done = 1
  end
  task.open(cmd_opts.args)
end, {
  nargs = "*",
  desc = "Open Taskwarrior tasks as markdown",
})

_G._taskwarrior_lazy = lazy  -- kept for future use; not publicly documented
