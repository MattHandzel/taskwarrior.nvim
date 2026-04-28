-- taskwarrior/graph.lua — :TaskGraph. Renders task `depends:` relationships
-- as a Mermaid flowchart wrapped in a markdown code-fence, suitable for
-- preview tools (markdown-preview.nvim, quarto, obsidian).
--
-- Node IDs are short UUIDs (8 hex chars). Node labels are the task description
-- with Mermaid-incompatible characters replaced.

local M = {}

local function run(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error == 0
end

-- Produce a label safe for Mermaid's `["..."]` node syntax.
-- Mermaid's string parser is stricter than it looks: `"` inside the quoted
-- form terminates the string unless escaped, `#` opens a comment, and line
-- breaks always terminate the node. Rather than fight the quoting rules,
-- we strip every character Mermaid can interpret and collapse whitespace.
local function escape_label(s)
  s = (s or ""):gsub("[\r\n\t]", " ")
  -- Replace quote/bracket/brace chars Mermaid reserves for node shapes.
  s = s:gsub('"', "'")
  s = s:gsub("[%[%]]", function(c) return c == "[" and "(" or ")" end)
  s = s:gsub("[{}]", function(c) return c == "{" and "(" or ")" end)
  -- `|` marks edge labels; `;` and `#` have special meaning at top level.
  s = s:gsub("[|;#]", " ")
  -- Backticks confuse some renderers that treat them as fence markers inside
  -- markdown code blocks.
  s = s:gsub("`", "'")
  -- Collapse any runs of whitespace produced above.
  s = s:gsub("%s+", " ")
  -- Trim
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then s = "(no description)" end
  return s
end

-- Mermaid accepts bare hex identifiers in recent versions, but several
-- downstream extractors (markdown-preview.nvim, some obsidian plugins)
-- reject IDs that start with a digit because they parse the `flowchart`
-- body with a stricter grammar. Prefix with `t_` so every ID is always
-- a valid identifier under every renderer we've tested.
local function node_id(uuid)
  return "t_" .. uuid:sub(1, 8)
end

function M.render(filter)
  filter = filter or "status:pending"
  local cmd = string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", filter)
  local out, ok = run(cmd)
  if not ok or not out or out == "" then return nil end
  local js = out:find("%[")
  if js and js > 1 then out = out:sub(js) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return nil end

  local lines = {
    "# taskwarrior.nvim — dependency graph",
    "",
    "```mermaid",
    "flowchart TD",
  }

  -- Handle the empty case explicitly — an empty `flowchart TD` is still
  -- valid Mermaid but downstream renderers like to warn, so give them a
  -- single placeholder node to render.
  if #tasks == 0 then
    table.insert(lines, "  empty[(no tasks)]")
    table.insert(lines, "```")
    return lines
  end

  local included = {}
  for _, t in ipairs(tasks) do
    if t.uuid then included[t.uuid] = true end
  end

  -- Declare every node first, then every edge. Mermaid accepts interleaved
  -- forms but some stricter parsers (vscode-mermaid-preview, obsidian's
  -- renderer before v1.4) error on an edge that references a not-yet-seen
  -- node. Always declaring-first eliminates that class of failure.
  local node_lines, edge_lines = {}, {}
  for _, t in ipairs(tasks) do
    if t.uuid then
      local id = node_id(t.uuid)
      local label = escape_label(t.description)
      table.insert(node_lines, string.format('  %s["%s"]', id, label))
    end
  end
  for _, t in ipairs(tasks) do
    if t.uuid then
      local id = node_id(t.uuid)
      local deps = t.depends or {}
      if type(deps) == "string" then deps = { deps } end
      for _, dep in ipairs(deps) do
        if included[dep] then
          table.insert(edge_lines, string.format("  %s --> %s", node_id(dep), id))
        end
      end
    end
  end

  for _, l in ipairs(node_lines) do table.insert(lines, l) end
  for _, l in ipairs(edge_lines) do table.insert(lines, l) end

  table.insert(lines, "```")
  return lines
end

function M.open(filter)
  local lines = M.render(filter)
  if not lines then
    require("taskwarrior.notify")("error",
      "taskwarrior.nvim: failed to render dependency graph",
      vim.log.levels.ERROR)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
  local name = "taskwarrior.nvim Graph"
  local ok_name = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok_name then
    local stale = vim.fn.bufnr(name)
    if stale ~= -1 and stale ~= buf then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
      pcall(vim.api.nvim_buf_set_name, buf, name)
    end
  end
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end, { buffer = buf, noremap = true, silent = true })
end

return M
