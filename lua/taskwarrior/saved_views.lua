local M = {}

local function views_file_path()
  local data = vim.fn.stdpath("data")
  local new_dir = data .. "/taskwarrior.nvim"
  vim.fn.mkdir(new_dir, "p")
  local new_path = new_dir .. "/saved-views.json"
  -- Migrate from pre-rename data dir (task.nvim → taskwarrior.nvim, v1.3.0).
  if vim.fn.filereadable(new_path) == 0 then
    local old_path = data .. "/task.nvim/saved-views.json"
    if vim.fn.filereadable(old_path) == 1 then
      pcall(vim.loop.fs_rename, old_path, new_path)
    end
  end
  return new_path
end

local function read_saved_views()
  local path = views_file_path()
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or not content or #content == 0 then return {} end
  local joined = table.concat(content, "\n")
  local parsed_ok, data = pcall(vim.fn.json_decode, joined)
  if not parsed_ok or type(data) ~= "table" then return {} end
  return data
end

local function write_saved_views(data)
  local path = views_file_path()
  local encoded = vim.fn.json_encode(data)
  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
end

function M.list_names()
  local data = read_saved_views()
  local names = {}
  for k, _ in pairs(data) do table.insert(names, k) end
  table.sort(names)
  return names
end

function M.save(name)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    vim.notify("taskwarrior.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  local function finish(chosen)
    if not chosen or chosen == "" then return end
    local views = read_saved_views()
    views[chosen] = {
      filter = vim.b[bufnr].task_filter or "",
      sort = vim.b[bufnr].task_sort or "",
      group = vim.b[bufnr].task_group or "",
    }
    write_saved_views(views)
    vim.notify(string.format("taskwarrior.nvim: saved view %q", chosen))
  end
  if name then finish(name) else
    vim.ui.input({ prompt = "Save view as: " }, finish)
  end
end

-- load: open a saved view by name.
-- open_fn: callback(filter_str) — M.open from init
-- refresh_fn: callback(bufnr) — refresh_buf from init
function M.load(name, open_fn, refresh_fn)
  local function finish(chosen)
    if not chosen or chosen == "" then return end
    local views = read_saved_views()
    local v = views[chosen]
    if not v then
      vim.notify(string.format("taskwarrior.nvim: no saved view %q", chosen), vim.log.levels.WARN)
      return
    end
    open_fn(v.filter or "")
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.b[bufnr].task_filter ~= nil then
      if v.sort and v.sort ~= "" then vim.b[bufnr].task_sort = v.sort end
      if v.group and v.group ~= "" then vim.b[bufnr].task_group = v.group end
      refresh_fn(bufnr)
    end
    vim.notify(string.format("taskwarrior.nvim: loaded view %q", chosen))
  end
  if name then
    finish(name)
  else
    local names = M.list_names()
    if #names == 0 then
      vim.notify("taskwarrior.nvim: no saved views", vim.log.levels.WARN)
      return
    end
    vim.ui.select(names, { prompt = "Load view:" }, finish)
  end
end

return M
