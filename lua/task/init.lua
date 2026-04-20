-- Deprecation shim — task.nvim was renamed to taskwarrior.nvim in v1.3.0.
--
-- `require("task")` and `require("task.*")` keep working for one release
-- cycle via this shim directory (each submodule file forwards to its
-- `taskwarrior.*` counterpart). Slated for removal in v1.5.
--
-- See `:help taskwarrior-rename` for the migration guide.

if not vim.g._taskwarrior_compat_warned then
  vim.g._taskwarrior_compat_warned = 1
  vim.schedule(function()
    vim.notify(
      "taskwarrior.nvim: require('task') is deprecated — update your config to "
        .. "require('taskwarrior'). See :help taskwarrior-rename.",
      vim.log.levels.WARN
    )
  end)
end

return require("taskwarrior")
