local M = {}

M.defaults = {
  on_delete = "done",   -- "done" or "delete" when lines are removed
  confirm = true,       -- show confirmation dialog before applying
  sort = "urgency-",    -- default sort
  group = "project",    -- default group field (nil to disable)
  fields = nil,         -- fields to show (nil = all)
  taskmd_path = nil,    -- path to taskmd binary (auto-detected if nil)
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
