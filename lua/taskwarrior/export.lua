-- taskwarrior/export.lua — :TaskExport. Write the rendered task buffer to a
-- markdown file with concealed UUIDs stripped, producing a file readable by
-- any markdown viewer (Obsidian, Marked, vim's built-in markdown.vim, …).

local M = {}

-- Strip the trailing `  <!-- uuid:... -->` comment from a rendered task line
-- so downstream readers see clean markdown.
local function strip_uuid(line)
  -- gsub returns (result, count). Wrap so table.insert only sees the string;
  -- otherwise the count becomes a positional arg and table.insert errors.
  local result = line:gsub("%s*<!%-%-%s*uuid:[0-9a-fA-F]+%s*%-%->%s*$", "")
  return result
end

-- Render the current task buffer out to `path` with UUIDs removed. If `path`
-- is nil/empty, prompts for one. Returns the final path on success.
function M.write(path)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter == nil then
    require("taskwarrior.notify")("warn",
      "taskwarrior.nvim: not in a task buffer", vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Drop the header comment + any UUID comments.
  local cleaned = {}
  for _, line in ipairs(lines) do
    if not line:match("^<!%-%-.*taskmd") then
      table.insert(cleaned, strip_uuid(line))
    end
  end

  local function write_to(target)
    if not target or target == "" then return end
    local f, err = io.open(target, "w")
    if not f then
      require("taskwarrior.notify")("error",
        "taskwarrior.nvim: export failed: " .. (err or "unknown"),
        vim.log.levels.ERROR)
      return
    end
    f:write(table.concat(cleaned, "\n"))
    f:write("\n")
    f:close()
    require("taskwarrior.notify")("apply",
      "taskwarrior.nvim: exported → " .. target)
  end

  if path and path ~= "" then
    write_to(path)
    return path
  end
  vim.ui.input({
    prompt = "Export to: ",
    default = "./tasks.md",
    completion = "file",
  }, write_to)
end

return M
