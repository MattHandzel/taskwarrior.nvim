-- Live diff preview for task.nvim. Attaches virtual text to each task line
-- showing the pending taskwarrior action (add/modify/done/delete) so the
-- user sees what `:w` will do before they save.

local M = {}

local ns = vim.api.nvim_create_namespace("task_nvim_diff_preview")
local _enabled = {}    -- { [bufnr] = true }
local _debounce = {}   -- { [bufnr] = timer }

local function uuid_for_line(line)
  return line:match("<!%-%- uuid:([0-9a-fA-F]+) %-%->")
end

local ACTION_LABELS = {
  add = { text = "+ ADD", hl = "DiffAdd" },
  modify = { text = "~ MODIFY", hl = "DiffChange" },
  done = { text = "✓ DONE", hl = "DiffText" },
  delete = { text = "✗ DELETE", hl = "DiffDelete" },
  start = { text = "▶ START", hl = "DiffChange" },
  stop = { text = "◼ STOP", hl = "DiffChange" },
}

local function render_actions(bufnr, actions)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not actions or #actions == 0 then return end

  -- Build a map: short uuid → list of actions
  local by_uuid = {}
  local add_actions = {}
  for _, a in ipairs(actions) do
    if a.type == "add" then
      table.insert(add_actions, a)
    elseif a.uuid then
      local short = a.uuid:sub(1, 8)
      by_uuid[short] = by_uuid[short] or {}
      table.insert(by_uuid[short], a)
    end
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local add_idx = 1
  for i, line in ipairs(lines) do
    local u = uuid_for_line(line)
    local label
    if u and by_uuid[u] then
      local acts = by_uuid[u]
      local types = {}
      for _, a in ipairs(acts) do table.insert(types, a.type) end
      local joined = table.concat(types, ",")
      local first = ACTION_LABELS[acts[1].type] or { text = joined:upper(), hl = "Comment" }
      label = { text = first.text, hl = first.hl }
    elseif not u and line:match("^%- %[") then
      -- A task line with no UUID → a new add. Attribute to the next unattached add action.
      local a = add_actions[add_idx]
      if a then
        label = ACTION_LABELS.add
        add_idx = add_idx + 1
      end
    end
    if label then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, i - 1, 0, {
        virt_text = { { "  " .. label.text, label.hl } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

-- Synchronous call into the Lua backend. The expensive part is `task export`
-- inside taskmd.apply; on a 300-task db this takes ~50–150ms. Since the caller
-- is already debounced 400ms after typing stops, the cost is acceptable for now.
local function run_dry_run(bufnr, cb)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")
  local ok_m, taskmd = pcall(require, "task.taskmd")
  if not ok_m then cb({}); return end
  local ok_a, result = pcall(taskmd.apply, { content = content, dry_run = true })
  if not ok_a or type(result) ~= "table" then cb({}); return end
  cb(result.actions or {})
end

function M.update(bufnr)
  if not _enabled[bufnr] then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    _enabled[bufnr] = nil
    return
  end
  run_dry_run(bufnr, function(actions)
    if _enabled[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
      render_actions(bufnr, actions)
    end
  end)
end

local function schedule_update(bufnr)
  if _debounce[bufnr] then
    _debounce[bufnr]:stop()
    _debounce[bufnr]:close()
  end
  local timer = vim.loop.new_timer()
  _debounce[bufnr] = timer
  timer:start(400, 0, vim.schedule_wrap(function()
    timer:stop()
    timer:close()
    _debounce[bufnr] = nil
    M.update(bufnr)
  end))
end

function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if _enabled[bufnr] then return end
  _enabled[bufnr] = true
  local grp = vim.api.nvim_create_augroup("TaskNvimDiffPreview_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    buffer = bufnr,
    group = grp,
    callback = function() schedule_update(bufnr) end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    group = grp,
    once = true,
    callback = function() M.disable(bufnr) end,
  })
  M.update(bufnr)
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  _enabled[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "TaskNvimDiffPreview_" .. bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if _enabled[bufnr] then M.disable(bufnr) else M.enable(bufnr) end
end

function M.is_enabled(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return _enabled[bufnr] == true
end

return M
