local M = {}

M.check = function()
  vim.health.start("task.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.9") == 1 then
    vim.health.ok("Neovim >= 0.9")
  else
    vim.health.error("Neovim >= 0.9 required")
  end

  -- Taskwarrior
  if vim.fn.executable("task") == 1 then
    local tw_version = vim.fn.system("task --version"):gsub("%s+$", "")
    local major = tonumber(tw_version:match("^(%d+)"))
    if major and major >= 2 then
      vim.health.ok("Taskwarrior " .. tw_version)
    else
      vim.health.warn("Taskwarrior version may be too old: " .. tw_version)
    end
  else
    vim.health.error("Taskwarrior not found", "Install: https://taskwarrior.org")
  end

  -- Python 3
  if vim.fn.executable("python3") == 1 then
    local py_version = vim.fn.system("python3 --version"):gsub("%s+$", "")
    vim.health.ok(py_version)
  else
    vim.health.error("Python 3 not found")
  end

  -- taskmd binary
  local ok_require, task_mod = pcall(require, "task")
  if ok_require and task_mod.get_taskmd_path then
    local taskmd_path = task_mod.get_taskmd_path()
    if taskmd_path and vim.fn.filereadable(taskmd_path) == 1 then
      vim.health.ok("taskmd found at " .. taskmd_path)
    else
      vim.health.warn("taskmd not found at expected path: " .. (taskmd_path or "nil"))
    end
  else
    vim.health.info("Could not check taskmd path (plugin not loaded)")
  end

  -- Task data
  local taskdata = vim.fn.system("task _get rc.data.location"):gsub("%s+$", "")
  if taskdata ~= "" and vim.fn.isdirectory(taskdata) == 1 then
    vim.health.ok("Task data at " .. taskdata)
  else
    local default = vim.fn.expand("~/.task")
    if vim.fn.isdirectory(default) == 1 then
      vim.health.ok("Task data at " .. default)
    else
      vim.health.warn("Task data directory not found")
    end
  end
end

return M
