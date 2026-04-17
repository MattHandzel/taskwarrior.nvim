local M = {}

local function run(cmd)
  local out = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  return out, ok
end

-- open: open the quick-capture floating window.
-- refresh_fn: callback() to refresh all task buffers after add.
function M.open(refresh_fn)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "taskmd"

  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor(vim.o.lines / 2) - 1,
    style = "minimal",
    border = "rounded",
    title = " Task Add ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.cmd("startinsert")

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    vim.cmd("stopinsert")
  end

  vim.keymap.set("i", "<CR>", function()
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    close()
    if line and line ~= "" then
      -- Write to temp file and use taskmd apply to avoid shell escaping issues
      -- with special characters (dashes, parens, plus signs, etc.)
      local escaped = line:gsub("'", "'\\''")
      local _, ok = run("task rc.bulk=0 rc.confirmation=off add -- '" .. escaped .. "'")
      if ok then
        vim.notify("task.nvim: added task")
        refresh_fn()
      else
        vim.notify("task.nvim: add failed", vim.log.levels.ERROR)
      end
    end
  end, { buffer = buf })

  vim.keymap.set("i", "<Esc>", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  vim.keymap.set("n", "q", close, { buffer = buf })
end

return M
