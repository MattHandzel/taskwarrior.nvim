local M = {}

local function run(cmd)
  local out = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  return out, ok
end

-- Omnifunc for the capture window — delegates to task.completion.complete_filter
-- so users get project:, +tag, priority:, field: completions with <Tab>.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local start = col
    while start > 0 and line:sub(start, start) ~= " " do
      start = start - 1
    end
    return start
  end
  local ok, completion = pcall(require, "taskwarrior.completion")
  if not ok then return {} end
  return completion.complete_filter(base)
end

-- open: open the quick-capture floating window.
-- refresh_fn: callback() to refresh all task buffers after add.
function M.open(refresh_fn)
  local config = require("taskwarrior.config")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "taskmd"
  vim.bo[buf].omnifunc = "v:lua.require'taskwarrior'._capture_omnifunc"

  local width = config.options.capture_width
      or math.min(80, math.floor(vim.o.columns * 0.6))
  local height = config.options.capture_height or 3
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor(vim.o.lines / 2) - 1,
    style = "minimal",
    border = config.options.border_style or "rounded",
    title = " Task Add ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.cmd("startinsert")

  -- Close is always deferred via vim.schedule: cmp's keymap solver (and other
  -- expr-mapping wrappers) can invoke our callbacks from inside a textlock
  -- context where nvim_win_close raises E565. Scheduling moves the close to
  -- the next main loop tick where textlock is released.
  local function do_close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.fn.mode():sub(1, 1) == "i" then
      vim.cmd("stopinsert")
    end
  end

  local function close()
    vim.schedule(do_close)
  end

  local function close_with_confirm()
    vim.schedule(function()
      if config.options.capture_confirm_close ~= false then
        local line = vim.api.nvim_buf_is_valid(buf)
            and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
            or ""
        if line:match("%S") then
          -- vim.fn.confirm requires a non-textlock context; we're already
          -- inside vim.schedule, so it's safe to call here.
          local choice = vim.fn.confirm("Discard task?", "&Yes\n&No", 2)
          if choice ~= 1 then
            -- Restore insert mode at the line's end so typing resumes naturally.
            if vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_set_current_win(win)
              vim.api.nvim_win_set_cursor(win, { 1, #line })
              vim.cmd("startinsert!")
            end
            return
          end
        end
      end
      do_close()
    end)
  end

  local function submit(line)
    if not line or line == "" then return end

    -- Greedy-parse the line so utility:20, project:X, +tag, due:tom etc.
    -- become real fields even when they appear in the middle of free-form
    -- text (e.g. between a sentence and a trailing code block).
    local ok_m, tm = pcall(require, "taskwarrior.taskmd")
    if ok_m then
      local udas = {}
      local ok_u, list = pcall(tm.tw_udas)
      if ok_u and type(list) == "table" then udas = list end
      local desc, fields = tm.parse_capture(line, udas)
      if desc and desc ~= "" then
        local new_uuid = tm.tw_add(desc, fields)
        if new_uuid and new_uuid ~= "" then
          vim.notify("taskwarrior.nvim: added task")
          refresh_fn()
          return
        end
      end
    end

    -- Fallback: raw add as literal description
    local escaped = line:gsub("'", "'\\''")
    local _, ok = run("task rc.bulk=0 rc.confirmation=off add -- '" .. escaped .. "'")
    if ok then
      vim.notify("taskwarrior.nvim: added task (unparsed)")
      refresh_fn()
    else
      vim.notify("taskwarrior.nvim: add failed", vim.log.levels.ERROR)
    end
  end

  -- <Tab>/<S-Tab> drive the completion popup
  vim.keymap.set("i", "<Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-n>" or "<C-x><C-o>"
  end, { buffer = buf, expr = true })
  vim.keymap.set("i", "<S-Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-p>" or "<S-Tab>"
  end, { buffer = buf, expr = true })

  vim.keymap.set("i", "<CR>", function()
    -- If the popup is visible, accept the selection instead of submitting
    if vim.fn.pumvisible() == 1 then
      return "<C-y>"
    end
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    -- Defer close + submit to escape any active textlock (nvim-cmp, etc.).
    vim.schedule(function()
      close()
      submit(line)
    end)
    return ""
  end, { buffer = buf, expr = true })

  vim.keymap.set("i", "<Esc>", close_with_confirm, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close_with_confirm, { buffer = buf })
  vim.keymap.set("n", "q", close_with_confirm, { buffer = buf })
end

return M
