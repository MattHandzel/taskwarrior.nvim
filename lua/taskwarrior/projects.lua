local M = {}

local function projects_file()
  local data = vim.fn.stdpath("data")
  local new_path = data .. "/taskwarrior_nvim_projects.json"
  -- Migrate from pre-rename path (task.nvim → taskwarrior.nvim, v1.3.0).
  if vim.fn.filereadable(new_path) == 0 then
    local old_path = data .. "/task_nvim_projects.json"
    if vim.fn.filereadable(old_path) == 1 then
      pcall(vim.loop.fs_rename, old_path, new_path)
    end
  end
  return new_path
end

local function load_projects()
  local path = projects_file()
  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, content)
  if ok and type(data) == "table" then return data end
  return {}
end

local function save_projects(projects)
  local path = projects_file()
  local f = io.open(path, "w")
  if not f then return end
  f:write(vim.fn.json_encode(projects))
  f:close()
end

function M.detect()
  local config = require("taskwarrior.config")
  local cwd = vim.fn.getcwd()
  local saved = load_projects()
  local all = vim.tbl_extend("keep", config.options.projects or {}, saved)

  for dir, name in pairs(all) do
    -- Normalize: strip trailing slash for comparison
    local d = dir:gsub("/$", "")
    if cwd == d or cwd:sub(1, #d + 1) == d .. "/" then
      return name
    end
  end
  return nil
end

function M.add(name)
  local cwd = vim.fn.getcwd()
  name = name or vim.fn.fnamemodify(cwd, ":t")
  local projects = load_projects()
  projects[cwd] = name
  save_projects(projects)
  vim.notify(string.format("taskwarrior.nvim: project '%s' → %s", name, cwd))
end

function M.remove()
  local cwd = vim.fn.getcwd()
  local projects = load_projects()
  if projects[cwd] then
    local name = projects[cwd]
    projects[cwd] = nil
    save_projects(projects)
    vim.notify(string.format("taskwarrior.nvim: removed project '%s' from %s", name, cwd))
  else
    vim.notify("taskwarrior.nvim: no project registered for " .. cwd, vim.log.levels.WARN)
  end
end

function M.list()
  local config = require("taskwarrior.config")
  local saved = load_projects()
  local all = vim.tbl_extend("keep", config.options.projects or {}, saved)
  if vim.tbl_isempty(all) then
    vim.notify("taskwarrior.nvim: no projects registered")
    return
  end
  local lines = { "taskwarrior.nvim projects:" }
  for dir, name in pairs(all) do
    table.insert(lines, string.format("  %s → %s", name, dir))
  end
  vim.notify(table.concat(lines, "\n"))
end

return M
