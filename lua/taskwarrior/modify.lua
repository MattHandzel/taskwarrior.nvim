-- taskwarrior/modify.lua — per-task shell-out operations.
--
-- Each function looks up the UUID of the task under the cursor, shells out to
-- `task <uuid> <verb>`, and refreshes the buffer on success. All commands
-- include `rc.bulk=0 rc.confirmation=off` so they never prompt for confirmation
-- at the CLI level — confirmation belongs in the vim layer.

local M = {}

local notify = require("taskwarrior.notify")

local function run(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error == 0
end

local function uuid_from_line(line)
  return line:match("<!%-%-.*uuid:([0-9a-fA-F]+).*%-%->")
end

-- Resolve the UUID of the task on the current cursor line. Returns nil and
-- emits a warning notify if the cursor is not on a task line.
local function current_uuid()
  local line = vim.api.nvim_get_current_line()
  local u = uuid_from_line(line)
  if not u then
    notify("warn", "taskwarrior.nvim: no UUID on this line", vim.log.levels.WARN)
  end
  return u
end

-- Try the Python CLI-sanitizing shell-escape before falling back to the
-- stdlib single-quote replacement. Works on all platforms nvim supports.
local function shq(s)
  return vim.fn.shellescape(s or "")
end

-- ---------------------------------------------------------------------------
-- Refresh helper: refresh every currently-open task buffer.
-- modify.lua doesn't know whether the current buffer is a task buffer (it may
-- be a vanilla markdown buffer with a query block), so we broadcast.
-- ---------------------------------------------------------------------------
local function refresh_all_task_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter ~= nil then
      pcall(function() require("taskwarrior.buffer").refresh_buf(b) end)
    end
  end
  -- Refresh embedded query blocks in any open markdown buffer.
  pcall(function() require("taskwarrior.query_blocks").refresh_all() end)
end

-- ---------------------------------------------------------------------------
-- :TaskAppend / :TaskPrepend
-- Append or prepend text to the description of the task under the cursor.
-- ---------------------------------------------------------------------------

--- @param mode "append"|"prepend"
--- @param text string|nil   when nil, prompts for input
function M.append_or_prepend(mode, text)
  local uuid = current_uuid()
  if not uuid then return end
  local function finish(input)
    if not input or input == "" then return end
    local cmd = string.format(
      "task rc.bulk=0 rc.confirmation=off %s %s %s",
      uuid, mode, shq(input))
    local out, ok = run(cmd)
    if ok then
      notify("modify", string.format("taskwarrior.nvim: %s → %s", mode, uuid))
      refresh_all_task_buffers()
    else
      notify("error", string.format("taskwarrior.nvim: %s failed\n%s", mode, out),
        vim.log.levels.ERROR)
    end
  end
  if text and text ~= "" then
    finish(text)
  else
    vim.ui.input({ prompt = mode == "append" and "Append: " or "Prepend: " }, finish)
  end
end

function M.append(text)  M.append_or_prepend("append",  text) end
function M.prepend(text) M.append_or_prepend("prepend", text) end

-- ---------------------------------------------------------------------------
-- :TaskDuplicate
-- Copy the task under the cursor into a new pending task. Uses `task duplicate`
-- so Taskwarrior preserves project/tags/due but resets status to pending and
-- generates a fresh UUID.
-- ---------------------------------------------------------------------------

function M.duplicate()
  local uuid = current_uuid()
  if not uuid then return end
  local out, ok = run(string.format(
    "task rc.bulk=0 rc.confirmation=off %s duplicate", uuid))
  if ok then
    notify("modify", "taskwarrior.nvim: duplicated " .. uuid)
    refresh_all_task_buffers()
  else
    notify("error", "taskwarrior.nvim: duplicate failed\n" .. out, vim.log.levels.ERROR)
  end
end

-- ---------------------------------------------------------------------------
-- :TaskPurge
-- Irreversibly remove tombstoned (deleted) tasks from the database. Takes an
-- optional filter; when omitted, purges the task under the cursor if it is
-- itself deleted, otherwise prompts for a filter like "status:deleted".
-- ---------------------------------------------------------------------------

function M.purge(filter)
  if not filter or filter == "" then
    local uuid = uuid_from_line(vim.api.nvim_get_current_line())
    filter = uuid or "status:deleted"
  end
  vim.ui.select({ "yes", "no" }, {
    prompt = string.format("Irreversibly purge tasks matching %q?", filter),
  }, function(choice)
    if choice ~= "yes" then
      notify("modify", "taskwarrior.nvim: purge cancelled")
      return
    end
    local out, ok = run(string.format(
      "task rc.bulk=0 rc.confirmation=off %s purge", filter))
    if ok then
      notify("modify", "taskwarrior.nvim: purged " .. filter)
      refresh_all_task_buffers()
    else
      notify("error", "taskwarrior.nvim: purge failed\n" .. out, vim.log.levels.ERROR)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- :TaskDenotate
-- Remove an annotation from the task under the cursor. If the task has more
-- than one annotation, prompts the user to pick which one to remove.
-- ---------------------------------------------------------------------------

local function get_task_json(uuid)
  local out, ok = run(string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", uuid))
  if not ok or not out or out == "" then return nil end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, arr = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(arr) ~= "table" or not arr[1] then return nil end
  return arr[1]
end

function M.denotate()
  local uuid = current_uuid()
  if not uuid then return end
  local task = get_task_json(uuid)
  if not task or not task.annotations or #task.annotations == 0 then
    notify("warn", "taskwarrior.nvim: no annotations on this task",
      vim.log.levels.WARN)
    return
  end
  local anns = task.annotations
  local function finish(text)
    if not text or text == "" then return end
    local out, ok = run(string.format(
      "task rc.bulk=0 rc.confirmation=off %s denotate %s", uuid, shq(text)))
    if ok then
      notify("modify", "taskwarrior.nvim: annotation removed")
      refresh_all_task_buffers()
    else
      notify("error", "taskwarrior.nvim: denotate failed\n" .. out, vim.log.levels.ERROR)
    end
  end
  if #anns == 1 then
    finish(anns[1].description)
  else
    local items = {}
    for _, a in ipairs(anns) do table.insert(items, a.description) end
    vim.ui.select(items, { prompt = "Remove annotation:" }, finish)
  end
end

-- ---------------------------------------------------------------------------
-- Field-specific modify shortcuts (MM / Mp / MP / MD / M+)
--
-- These wrap `task <uuid> modify FIELD:VALUE` with a pre-canned picker so the
-- user never has to remember Taskwarrior's attribute-value syntax.
-- ---------------------------------------------------------------------------

local function modify_field(uuid, spec)
  local out, ok = run(string.format(
    "task rc.bulk=0 rc.confirmation=off %s modify %s", uuid, spec))
  if ok then
    notify("modify", "taskwarrior.nvim: " .. spec)
    refresh_all_task_buffers()
  else
    notify("error", "taskwarrior.nvim: modify failed\n" .. out, vim.log.levels.ERROR)
  end
end

--- Collect existing project names from pending tasks (de-duplicated, sorted).
local function existing_projects()
  local out, ok = run(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on status:pending export")
  if not ok or not out or out == "" then return {} end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return {} end
  local seen, names = {}, {}
  for _, t in ipairs(tasks) do
    if t.project and not seen[t.project] then
      seen[t.project] = true
      table.insert(names, t.project)
    end
  end
  table.sort(names)
  return names
end

--- Collect existing tags from pending tasks.
local function existing_tags()
  local out, ok = run(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on status:pending export")
  if not ok or not out or out == "" then return {} end
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return {} end
  local seen, names = {}, {}
  for _, t in ipairs(tasks) do
    for _, tag in ipairs(t.tags or {}) do
      if not seen[tag] then
        seen[tag] = true
        table.insert(names, tag)
      end
    end
  end
  table.sort(names)
  return names
end

M._existing_projects = existing_projects
M._existing_tags = existing_tags

--- Generic field picker. field_name → Taskwarrior attribute name.
--- values → list of valid values. Empty string clears the field.
local function pick_field(uuid, field_name, values, prompt)
  local items = { "(clear)" }
  for _, v in ipairs(values) do table.insert(items, v) end
  vim.ui.select(items, { prompt = prompt or (field_name .. ":") }, function(choice)
    if not choice then return end
    local spec = choice == "(clear)"
        and (field_name .. ":")
        or (field_name .. ":" .. choice)
    modify_field(uuid, spec)
  end)
end

--- MM — modify project from existing projects list.
function M.modify_project()
  local uuid = current_uuid()
  if not uuid then return end
  local projects = existing_projects()
  pick_field(uuid, "project", projects, "Project:")
end

--- Mp — modify priority: L / M / H / (clear).
function M.modify_priority()
  local uuid = current_uuid()
  if not uuid then return end
  pick_field(uuid, "priority", { "H", "M", "L" }, "Priority:")
end

--- MD — modify due date from a short preset list or free-form input.
function M.modify_due()
  local uuid = current_uuid()
  if not uuid then return end
  local items = {
    "(clear)",
    "today",
    "tomorrow",
    "eow (end of week)",
    "eom (end of month)",
    "+1d",
    "+1w",
    "(custom…)",
  }
  vim.ui.select(items, { prompt = "Due:" }, function(choice)
    if not choice then return end
    if choice == "(clear)" then
      modify_field(uuid, "due:")
    elseif choice == "(custom…)" then
      vim.ui.input({ prompt = "Due (Taskwarrior date expr): " }, function(v)
        if v and v ~= "" then modify_field(uuid, "due:" .. v) end
      end)
    else
      -- Strip any descriptive parenthetical
      local val = choice:match("^(%S+)")
      modify_field(uuid, "due:" .. val)
    end
  end)
end

--- M+ — add a tag from the existing-tag list, or a custom one.
function M.modify_tag()
  local uuid = current_uuid()
  if not uuid then return end
  local tags = existing_tags()
  local items = { "(custom…)" }
  for _, t in ipairs(tags) do table.insert(items, t) end
  vim.ui.select(items, { prompt = "Add tag:" }, function(choice)
    if not choice then return end
    if choice == "(custom…)" then
      vim.ui.input({ prompt = "Tag (no leading +): " }, function(v)
        if v and v ~= "" then modify_field(uuid, "+" .. v) end
      end)
    else
      modify_field(uuid, "+" .. choice)
    end
  end)
end

--- Generic modify-field picker. Exposed as :TaskModifyField <field>.
function M.modify_field_by_name(field)
  local uuid = current_uuid()
  if not uuid then return end
  if field == "project" then return M.modify_project() end
  if field == "priority" then return M.modify_priority() end
  if field == "due" then return M.modify_due() end
  if field == "tag" or field == "tags" or field == "+" then return M.modify_tag() end
  -- Fallback: free-form input
  vim.ui.input({ prompt = field .. ": " }, function(v)
    if v == nil then return end
    modify_field(uuid, field .. ":" .. v)
  end)
end

return M
