-- taskwarrior/notify.lua — category-gated vim.notify wrapper.
--
-- Every user-facing notification in taskwarrior.nvim goes through this module.
-- The config option `notifications = { <category> = true|false }` lets users
-- silence specific categories (e.g. `apply = false` in heavy-edit sessions).
--
-- Usage:
--   local notify = require("taskwarrior.notify")
--   notify("modify", "taskwarrior.nvim: modified")
--   notify("error",  "taskwarrior.nvim: render failed", vim.log.levels.ERROR)
--
-- Unknown categories fall through to vim.notify (treated as enabled). Error-
-- and warn-level messages default to their respective categories when called
-- with a log level but no explicit category.

local function resolve(level)
  if level == vim.log.levels.ERROR then return "error" end
  if level == vim.log.levels.WARN  then return "warn"  end
  return nil
end

local function M(cat, msg, level)
  -- Second-arg is the message only when cat is a string category.
  if type(cat) ~= "string" then
    -- Called as notify(msg, level): shift args, resolve category from level.
    level = msg
    msg = cat
    cat = resolve(level)
  end
  level = level or vim.log.levels.INFO

  local ok, config = pcall(require, "taskwarrior.config")
  if ok and config.options.notifications and cat ~= nil then
    local enabled = config.options.notifications[cat]
    if enabled == false then return end
  end

  vim.notify(msg, level)
end

return setmetatable({}, {
  __call = function(_, cat, msg, level)
    return M(cat, msg, level)
  end,
})
