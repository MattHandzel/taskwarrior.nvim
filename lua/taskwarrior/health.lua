local M = {}

M.check = function()
  vim.health.start("taskwarrior.nvim")

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

  -- Python 3 (optional — only required for bin/taskmd CLI and live diff preview)
  if vim.fn.executable("python3") == 1 then
    local py_version = vim.fn.system("python3 --version"):gsub("%s+$", "")
    vim.health.ok(py_version .. " (optional — used by bin/taskmd CLI)")
  else
    vim.health.warn(
      "Python 3 not found",
      "Optional. Required only for the bin/taskmd CLI and live diff-preview virtual text. The default render/save path is pure Lua."
    )
  end

  -- taskmd binary
  local ok_require, task_mod = pcall(require, "taskwarrior")
  if ok_require and task_mod.get_taskmd_path then
    local taskmd_path = task_mod.get_taskmd_path()
    if taskmd_path and vim.fn.filereadable(taskmd_path) == 1 then
      vim.health.ok("taskmd CLI at " .. taskmd_path)
    else
      vim.health.info("taskmd CLI not on PATH (optional — pure-Lua backend is the default)")
    end
  else
    vim.health.info("Could not check taskmd path (plugin not loaded)")
  end

  -- Task data directory
  local taskdata = vim.fn.system("task _get rc.data.location"):gsub("%s+$", "")
  if taskdata ~= "" and vim.fn.isdirectory(taskdata) == 1 then
    vim.health.ok("Taskwarrior data at " .. taskdata)
  else
    local default = vim.fn.expand("~/.task")
    if vim.fn.isdirectory(default) == 1 then
      vim.health.ok("Taskwarrior data at " .. default)
    else
      vim.health.warn(
        "Taskwarrior data directory not found",
        "Run `task add 'first task'` once to initialize ~/.task."
      )
    end
  end

  -- Plugin data directory (saved views, backups)
  local plugin_data = vim.fn.stdpath("data") .. "/taskwarrior.nvim"
  if vim.fn.isdirectory(plugin_data) == 1 then
    vim.health.ok("Plugin data at " .. plugin_data)
  else
    vim.health.info("Plugin data dir not yet created (will appear on first :TaskSave or apply)")
  end
end

return M
