local M = {}

local function projects_file()
  return vim.fn.stdpath("data") .. "/task_nvim_projects.json"
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
  local config = require("task.config")
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
  vim.notify(string.format("task.nvim: project '%s' → %s", name, cwd))
end

function M.remove()
  local cwd = vim.fn.getcwd()
  local projects = load_projects()
  if projects[cwd] then
    local name = projects[cwd]
    projects[cwd] = nil
    save_projects(projects)
    vim.notify(string.format("task.nvim: removed project '%s' from %s", name, cwd))
  else
    vim.notify("task.nvim: no project registered for " .. cwd, vim.log.levels.WARN)
  end
end

function M.list()
  local config = require("task.config")
  local saved = load_projects()
  local all = vim.tbl_extend("keep", config.options.projects or {}, saved)
  if vim.tbl_isempty(all) then
    vim.notify("task.nvim: no projects registered")
    return
  end
  local lines = { "task.nvim projects:" }
  for dir, name in pairs(all) do
    table.insert(lines, string.format("  %s → %s", name, dir))
  end
  vim.notify(table.concat(lines, "\n"))
end

return M
