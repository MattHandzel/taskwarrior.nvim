local M = {}

local function views_file_path()
  local data_dir = vim.fn.stdpath("data") .. "/task.nvim"
  vim.fn.mkdir(data_dir, "p")
  return data_dir .. "/saved-views.json"
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
    vim.notify("task.nvim: not in a task buffer", vim.log.levels.WARN)
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
    vim.notify(string.format("task.nvim: saved view %q", chosen))
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
      vim.notify(string.format("task.nvim: no saved view %q", chosen), vim.log.levels.WARN)
      return
    end
    open_fn(v.filter or "")
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.b[bufnr].task_filter ~= nil then
      if v.sort and v.sort ~= "" then vim.b[bufnr].task_sort = v.sort end
      if v.group and v.group ~= "" then vim.b[bufnr].task_group = v.group end
      refresh_fn(bufnr)
    end
    vim.notify(string.format("task.nvim: loaded view %q", chosen))
  end
  if name then
    finish(name)
  else
    local names = M.list_names()
    if #names == 0 then
      vim.notify("task.nvim: no saved views", vim.log.levels.WARN)
      return
    end
    vim.ui.select(names, { prompt = "Load view:" }, finish)
  end
end

return M
