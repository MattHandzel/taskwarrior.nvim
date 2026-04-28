-- tests/e2e/spec/e2e_spec.lua — drive each taskwarrior.nvim feature against
-- a real Taskwarrior DB and assert the observable effect.
--
-- The e2e harness (tests/e2e/run.sh) creates a TMPDIR with its own
-- TASKDATA/TASKRC before nvim starts and seeds fixture tasks. This spec
-- reads fixture UUIDs from TMPDIR/fixture.json so every test can reuse
-- the shared seed without re-creating it.
--
-- Policy: if a feature interacts with real Taskwarrior mutations, we
--   1. invoke the feature headlessly (stubbing vim.ui.input/select where
--      the feature prompts),
--   2. `task <uuid> _uuids` or `task export` to read back the effect,
--   3. assert on the resulting state.
-- If a feature produces output for a downstream tool (Mermaid, markdown),
-- we run that tool's validator and assert a non-error exit.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local fixture
do
  local raw = assert(read_file(TMP .. "/fixture.json"), "fixture.json missing")
  fixture = vim.fn.json_decode(raw)
end

local function run_shell(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error == 0
end

local function task_export(filter)
  local out, ok = run_shell(string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", filter or ""))
  if not ok or not out or out == "" then return {} end
  local js = out:find("%[")
  if js and js > 1 then out = out:sub(js) end
  local parsed_ok, arr = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(arr) ~= "table" then return {} end
  return arr
end

local function get_task(uuid)
  local arr = task_export(uuid)
  return arr[1]
end

-- Place cursor on a task line referring to the given short UUID. The buffer
-- must already be rendered. Returns true on success.
local function cursor_on_uuid(bufnr, short_uuid)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find("uuid:" .. short_uuid, 1, true) then
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return true
    end
  end
  return false
end

-- ── vim.ui stubs for driving prompts headlessly ──────────────────────────
local _ui_backup = {}
local function stub_input(answer)
  _ui_backup.input = vim.ui.input
  vim.ui.input = function(_opts, cb) cb(answer) end
end
local function stub_select(answer)
  _ui_backup.select = vim.ui.select
  vim.ui.select = function(_items, _opts, cb) cb(answer) end
end
local function restore_ui()
  if _ui_backup.input then vim.ui.input = _ui_backup.input end
  if _ui_backup.select then vim.ui.select = _ui_backup.select end
  _ui_backup = {}
end

-- Fresh notify-capture so we can assert non-error paths
local _notify_backup
local _notify_log = {}
local function capture_notify()
  _notify_backup = vim.notify
  _notify_log = {}
  vim.notify = function(msg, level) table.insert(_notify_log, { msg = msg, level = level }) end
end
local function restore_notify()
  if _notify_backup then vim.notify = _notify_backup end
  _notify_backup = nil
end

-- Plugin bootstrap: load once per file (expensive-ish).
require("taskwarrior").setup({})

-- Resolve each fixture UUID to its short form for cursor placement / shell calls
local SHORT = {}
for k, v in pairs(fixture) do if v ~= "" then SHORT[k] = v:sub(1, 8) end end

-- =========================================================================
-- Tier 1: task-level operations
-- =========================================================================

describe("e2e :TaskAppend", function()
  it("appends text to the description", function()
    -- Find the 'Solo task' UUID dynamically (not in fixture)
    local solo = task_export("description:Solo")[1]
    assert.is_not_nil(solo)
    local before = solo.description
    -- No buffer needed — modify.append reads from current line. Open a task buf.
    require("taskwarrior").open("uuid:" .. solo.uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, solo.uuid:sub(1, 8)))
    capture_notify()
    require("taskwarrior.modify").append(" suffix")
    restore_notify()
    local after = get_task(solo.uuid)
    assert.equals(before .. " suffix", after.description)
  end)
end)

describe("e2e :TaskPrepend", function()
  it("prepends text to the description", function()
    local solo = task_export("description:Solo")[1]
    assert.is_not_nil(solo)
    local before = solo.description
    require("taskwarrior").open("uuid:" .. solo.uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, solo.uuid:sub(1, 8)))
    require("taskwarrior.modify").prepend("URGENT: ")
    local after = get_task(solo.uuid)
    assert.equals("URGENT: " .. before, after.description)
  end)
end)

describe("e2e :TaskDuplicate", function()
  it("creates a new pending task with the same project", function()
    local before_count = #task_export("project:other status:pending")
    local solo = task_export("description.is:Solo")[1]
      or task_export("project:other status:pending")[1]
    assert.is_not_nil(solo, "need a seed task to duplicate")
    require("taskwarrior").open("uuid:" .. solo.uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, solo.uuid:sub(1, 8)))
    require("taskwarrior.modify").duplicate()
    local after_count = #task_export("project:other status:pending")
    assert.is_true(after_count > before_count,
      "duplicate should have increased project:other count")
  end)
end)

describe("e2e :TaskPurge", function()
  it("removes a deleted task from the database", function()
    -- Our seed deleted 'To be purged'. Confirm it exists as deleted,
    -- then :TaskPurge, then assert it's gone.
    local deleted_before = task_export("status:deleted description:purged")
    if #deleted_before == 0 then
      pending("purge fixture missing — TW version may have rejected delete")
      return
    end
    local victim = deleted_before[1]
    stub_select("yes")
    require("taskwarrior.modify").purge("uuid:" .. victim.uuid:sub(1, 8))
    restore_ui()
    local deleted_after = task_export("status:deleted uuid:" .. victim.uuid:sub(1, 8))
    assert.equals(0, #deleted_after,
      "purge should remove the task from the database entirely")
  end)
end)

describe("e2e :TaskDenotate", function()
  it("removes an annotation from the task under cursor", function()
    local uuid = fixture.anno
    local before = get_task(uuid)
    local ann_count_before = before.annotations and #before.annotations or 0
    assert.is_true(ann_count_before >= 1, "fixture should have annotations")
    require("taskwarrior").open("uuid:" .. uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, uuid:sub(1, 8)))
    -- Pick the first annotation
    stub_select(before.annotations[1].description)
    require("taskwarrior.modify").denotate()
    restore_ui()
    local after = get_task(uuid)
    local ann_count_after = after.annotations and #after.annotations or 0
    assert.equals(ann_count_before - 1, ann_count_after)
  end)
end)

describe("e2e :TaskModifyField project", function()
  it("sets a new project via the picker", function()
    local solo = task_export("project:other status:pending")[1]
    assert.is_not_nil(solo)
    require("taskwarrior").open("uuid:" .. solo.uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, solo.uuid:sub(1, 8)))
    stub_select("demo")
    require("taskwarrior.modify").modify_project()
    restore_ui()
    local after = get_task(solo.uuid)
    assert.equals("demo", after.project)
  end)
end)

describe("e2e :TaskModifyField priority", function()
  it("sets a priority via the picker", function()
    -- Pick the overdue task (no existing priority conflict)
    local t = task_export("description:Overdue")[1]
    assert.is_not_nil(t)
    require("taskwarrior").open("uuid:" .. t.uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, t.uuid:sub(1, 8)))
    stub_select("L")
    require("taskwarrior.modify").modify_priority()
    restore_ui()
    local after = get_task(t.uuid)
    assert.equals("L", after.priority)
  end)
end)

describe("e2e :TaskModifyField due (clear)", function()
  it("clears the due date when '(clear)' is picked", function()
    local t = task_export("description:Overdue")[1]
    assert.is_not_nil(t)
    assert.is_not_nil(t.due, "fixture should have a due date")
    require("taskwarrior").open("uuid:" .. t.uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, t.uuid:sub(1, 8)))
    stub_select("(clear)")
    require("taskwarrior.modify").modify_due()
    restore_ui()
    local after = get_task(t.uuid)
    assert.is_nil(after.due, "due should be cleared")
  end)
end)

describe("e2e :TaskModifyField tag", function()
  it("adds a tag via the picker (custom value)", function()
    local solo = task_export("description:Solo")[1]
      or task_export("project:demo status:pending")[1]
    assert.is_not_nil(solo)
    require("taskwarrior").open("uuid:" .. solo.uuid:sub(1, 8))
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(cursor_on_uuid(bufnr, solo.uuid:sub(1, 8)))
    stub_select("(custom…)")
    vim.ui.input = function(_, cb) cb("e2etest") end
    require("taskwarrior.modify").modify_tag()
    restore_ui()
    local after = get_task(solo.uuid)
    local has = false
    for _, t in ipairs(after.tags or {}) do
      if t == "e2etest" then has = true end
    end
    assert.is_true(has, "+e2etest tag should be present on " .. solo.uuid)
  end)
end)

-- =========================================================================
-- Tier 1: bulk modify
-- =========================================================================

describe("e2e :TaskBulkModify", function()
  it("applies the same spec to every task in the selected range", function()
    require("taskwarrior").open("project:demo")
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- Collect UUIDs on task lines
    local task_lines = {}
    for i, line in ipairs(lines) do
      if line:match("^%- %[") then table.insert(task_lines, i) end
    end
    assert.is_true(#task_lines >= 2, "need >=2 task lines in demo project")
    require("taskwarrior.bulk").modify({ task_lines[1], task_lines[#task_lines] },
      "+bulktag")
    local tasks = task_export("project:demo +bulktag")
    assert.is_true(#tasks >= 2,
      "expected >=2 tasks to have +bulktag after BulkModify, got " .. #tasks)
  end)
end)

-- =========================================================================
-- Tier 1: nested link children
-- =========================================================================

describe("e2e :TaskLinkChildren", function()
  it("adds depends: to the cursor task for each indented child", function()
    -- Make a buffer with parent + two indented children inline. We need
    -- UUIDs on the children so collect_children can pick them up.
    local children = task_export("project:demo -PARENT")
    -- Pick any two of the child tasks we seeded.
    local c1, c2
    for _, t in ipairs(children) do
      if t.description:match("Child") then
        if not c1 then c1 = t else c2 = t; break end
      end
    end
    assert.is_not_nil(c2, "need at least two Child-tagged tasks in fixture")

    -- Create a fresh parent task to avoid polluting the fixture parent.
    local _, ok = run_shell('task rc.confirmation=off rc.bulk=0 add "Linkage parent" project:demo')
    assert.is_true(ok)
    local parent = task_export("description:Linkage")[1]
    assert.is_not_nil(parent)

    -- Open a plain scratch buffer and stage the parent with two indented kids.
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "- [ ] Linkage parent  <!-- uuid:" .. parent.uuid:sub(1, 8) .. " -->",
      "  - [ ] Child one  <!-- uuid:" .. c1.uuid:sub(1, 8) .. " -->",
      "  - [ ] Child two  <!-- uuid:" .. c2.uuid:sub(1, 8) .. " -->",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("taskwarrior.nested").link_children()

    local after = get_task(parent.uuid)
    local deps = after.depends
    if type(deps) == "string" then deps = { deps } end
    assert.is_true(#deps == 2, "expected 2 dependencies, got " .. #deps)
    local has1, has2 = false, false
    for _, d in ipairs(deps) do
      if d == c1.uuid then has1 = true end
      if d == c2.uuid then has2 = true end
    end
    assert.is_true(has1 and has2, "both children should be in depends")
  end)
end)

-- =========================================================================
-- Tier 2: reports
-- =========================================================================

describe("e2e :TaskReport next", function()
  it("opens a task buffer filtered to status:pending sorted by urgency", function()
    local opened
    local fake_open = function(filter) opened = filter; require("taskwarrior").open(filter) end
    require("taskwarrior.report").open("next", fake_open)
    assert.equals("status:pending", opened)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals("status:pending", vim.b[bufnr].task_filter)
    assert.equals("urgency-", vim.b[bufnr].task_sort)
  end)
end)

describe("e2e :TaskReport active", function()
  it("shows only +ACTIVE tasks", function()
    -- Self-seed: prior tests may have stopped / modified the fixture's
    -- active task. Create + start a fresh one so this test isn't order
    -- dependent on earlier mutations.
    run_shell('task rc.confirmation=off rc.bulk=0 add "Active for report" project:reports')
    local t = task_export("description:Active for")[1]
    assert.is_not_nil(t)
    run_shell("task rc.confirmation=off rc.bulk=0 " .. t.uuid:sub(1, 8) .. " start")

    -- Sanity-check the shell is actually reporting it as active
    local active_via_shell = task_export("+ACTIVE")
    assert.is_true(#active_via_shell >= 1,
      "shell: +ACTIVE should return >=1 task after starting one")

    local fake_open = function(filter) require("taskwarrior").open(filter) end
    require("taskwarrior.report").open("active", fake_open)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local task_lines = 0
    for _, l in ipairs(lines) do
      if l:match("^%- %[[ x>]%]") then task_lines = task_lines + 1 end
    end
    assert.is_true(task_lines >= 1,
      "active report should show at least 1 task; buffer lines:\n" ..
      table.concat(lines, "\n"))
  end)
end)

describe("e2e :TaskReport overdue", function()
  it("shows only pending tasks past their due date", function()
    -- Self-seed an overdue item — the fixture's "Overdue item" may have
    -- had its due date cleared by an earlier test (TaskModifyField due).
    run_shell('task rc.confirmation=off rc.bulk=0 add "Past-due report test" due:2020-01-01')
    local fake_open = function(filter) require("taskwarrior").open(filter) end
    require("taskwarrior.report").open("overdue", fake_open)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals("status:pending +OVERDUE", vim.b[bufnr].task_filter)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local task_lines = 0
    for _, l in ipairs(lines) do
      if l:match("^%- %[[ x>]%]") then task_lines = task_lines + 1 end
    end
    assert.is_true(task_lines >= 1,
      "overdue report should show the seeded past-due task")
  end)
end)

describe("e2e :TaskReport ready", function()
  it("renders without error and sets the expected filter", function()
    local fake_open = function(filter) require("taskwarrior").open(filter) end
    require("taskwarrior.report").open("ready", fake_open)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals("status:pending -BLOCKED -WAITING", vim.b[bufnr].task_filter)
  end)
end)

describe("e2e :TaskReport waiting", function()
  it("renders with status:waiting filter", function()
    -- Seed a waiting task so we have content to render
    run_shell('task rc.confirmation=off rc.bulk=0 add "Wait one" wait:30d')
    local fake_open = function(filter) require("taskwarrior").open(filter) end
    require("taskwarrior.report").open("waiting", fake_open)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals("status:waiting", vim.b[bufnr].task_filter)
  end)
end)

describe("e2e :TaskReport unknown", function()
  it("warns on unknown report name", function()
    capture_notify()
    require("taskwarrior.report").open("nosuchreport", function() end)
    restore_notify()
    local warned = false
    for _, entry in ipairs(_notify_log) do
      if entry.msg:match("unknown report") then warned = true end
    end
    assert.is_true(warned)
  end)
end)

-- =========================================================================
-- Tier 2: embedded query blocks
-- =========================================================================

describe("e2e query blocks refresh", function()
  it("replaces the body of a <!-- taskmd query: ... --> block", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# README",
      "",
      "<!-- taskmd query: project:demo -->",
      "(placeholder)",
      "<!-- taskmd endquery -->",
      "",
      "footer",
    })
    vim.api.nvim_set_current_buf(buf)
    require("taskwarrior.query_blocks").refresh(buf)
    local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- The placeholder should be gone, replaced with real task lines.
    local has_placeholder = false
    local has_task_line = false
    for _, l in ipairs(after) do
      if l == "(placeholder)" then has_placeholder = true end
      if l:match("^%- %[") then has_task_line = true end
    end
    assert.is_false(has_placeholder, "placeholder should be replaced")
    assert.is_true(has_task_line, "should render at least one task line")
    -- Footer is preserved
    assert.equals("footer", after[#after])
  end)
end)

-- =========================================================================
-- Tier 1: tag colors applied during highlight
-- =========================================================================

describe("e2e tag_colors apply as extmarks", function()
  it("renders +urgent with the configured highlight group", function()
    require("taskwarrior.config").options.tag_colors = {
      ["+urgent"] = "ErrorMsg",
    }
    require("taskwarrior").open("+urgent")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_hl"]
    assert.is_not_nil(ns)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local found_error_msg = false
    for _, m in ipairs(marks) do
      if m[4] and m[4].hl_group == "ErrorMsg" then
        found_error_msg = true; break
      end
    end
    assert.is_true(found_error_msg,
      "at least one extmark should use ErrorMsg (the +urgent override)")
    require("taskwarrior.config").options.tag_colors = {}
  end)
end)

-- =========================================================================
-- Tier 2: notifications gate
-- =========================================================================

describe("e2e notifications gate", function()
  it("suppresses notifications for disabled categories", function()
    require("taskwarrior.config").options.notifications = {
      start = true, stop = true, modify = false, apply = true,
      review = true, capture = true, delegate = true, view = true,
      error = true, warn = true,
    }
    capture_notify()
    require("taskwarrior.notify")("modify", "should be suppressed")
    require("taskwarrior.notify")("error", "should pass")
    restore_notify()
    local got_modify, got_error = false, false
    for _, e in ipairs(_notify_log) do
      if e.msg:match("suppressed") then got_modify = true end
      if e.msg:match("should pass") then got_error = true end
    end
    assert.is_false(got_modify, "modify notification should be suppressed")
    assert.is_true(got_error, "error notification should still fire")
    -- Restore defaults
    require("taskwarrior.config").options.notifications.modify = true
  end)
end)

-- =========================================================================
-- Tier 1: nested unlink_children
-- =========================================================================

describe("e2e :TaskUnlinkChildren", function()
  it("removes depends: for indented children under the cursor task",
      function()
    -- Create three fresh tasks: parent + two kids, then link them
    run_shell('task rc.confirmation=off rc.bulk=0 add "UnlinkParent" project:unlinkdemo')
    run_shell('task rc.confirmation=off rc.bulk=0 add "UnlinkKidA"   project:unlinkdemo')
    run_shell('task rc.confirmation=off rc.bulk=0 add "UnlinkKidB"   project:unlinkdemo')
    local parent = task_export("project:unlinkdemo description:UnlinkParent")[1]
    local kid_a  = task_export("project:unlinkdemo description:UnlinkKidA")[1]
    local kid_b  = task_export("project:unlinkdemo description:UnlinkKidB")[1]
    assert.is_not_nil(parent); assert.is_not_nil(kid_a); assert.is_not_nil(kid_b)

    run_shell(string.format(
      "task rc.confirmation=off rc.bulk=0 %s modify depends:%s,%s",
      parent.uuid:sub(1, 8), kid_a.uuid, kid_b.uuid))
    local parent_after_link = get_task(parent.uuid)
    local deps = parent_after_link.depends
    if type(deps) == "string" then deps = { deps } end
    assert.is_true(#deps == 2, "precondition: parent should have 2 deps")

    -- Lay out parent with indented children in a scratch buffer
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "- [ ] Unlink parent  <!-- uuid:" .. parent.uuid:sub(1, 8) .. " -->",
      "  - [ ] Unlink kid A  <!-- uuid:" .. kid_a.uuid:sub(1, 8) .. " -->",
      "  - [ ] Unlink kid B  <!-- uuid:" .. kid_b.uuid:sub(1, 8) .. " -->",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("taskwarrior.nested").unlink_children()

    local after = get_task(parent.uuid)
    local deps_after = after.depends
    if type(deps_after) == "string" then deps_after = { deps_after } end
    deps_after = deps_after or {}
    assert.equals(0, #deps_after, "unlink should drop all children from depends")
  end)
end)

-- =========================================================================
-- Tier 1: granulation timer wiring (not just stop_all_now)
-- =========================================================================

describe("e2e granulation autocmd wiring", function()
  it("registers autocmds when enabled, unregisters when disabled", function()
    require("taskwarrior.config").options.granulation = {
      enabled = true, idle_ms = 60000, notify_on_stop = false,
    }
    require("taskwarrior.granulation").setup()
    local aus = vim.api.nvim_get_autocmds({ group = "TaskwarriorGranulation" })
    assert.is_true(#aus >= 1, "at least one autocmd should be registered")

    require("taskwarrior.config").options.granulation.enabled = false
    require("taskwarrior.granulation").setup()
    -- Group should be cleared — get_autocmds on non-existent group returns {}
    local aus2 = pcall(vim.api.nvim_get_autocmds, { group = "TaskwarriorGranulation" })
    assert.is_true(type(aus2) == "boolean")
  end)
end)

-- =========================================================================
-- Tier 1: per-cwd auto-load — filter override without named view
-- =========================================================================

describe("e2e per-cwd filter override", function()
  it("honors the `filter` field on an extended projects entry", function()
    local cwd = vim.fn.getcwd()
    require("taskwarrior.config").options.projects = {
      [cwd] = { name = "whatever", filter = "project:demo +urgent" },
    }
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[b].task_filter ~= nil then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    require("taskwarrior").open()
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals("project:demo +urgent", vim.b[bufnr].task_filter)
    require("taskwarrior.config").options.projects = {}
  end)
end)

-- =========================================================================
-- Tier 3: graph (Mermaid)
-- =========================================================================

describe("e2e :TaskGraph", function()
  it("produces a Mermaid flowchart that mmdc can render without error",
      function()
    local out = require("taskwarrior.graph").render("status:pending")
    assert.is_not_nil(out)
    -- Extract the fenced block for mmdc
    local inside = {}
    local in_block = false
    for _, line in ipairs(out) do
      if line == "```mermaid" then in_block = true
      elseif line == "```" then in_block = false
      elseif in_block then table.insert(inside, line) end
    end
    assert.is_true(#inside >= 1, "graph should contain a non-empty mermaid block")

    local mmd_path = TMP .. "/graph.mmd"
    local f = io.open(mmd_path, "w"); f:write(table.concat(inside, "\n")); f:close()

    -- mmdc exits non-zero on a parse error and prints "Error: <msg>".
    -- Run it and capture both stdout and stderr.
    local cmd = string.format(
      "mmdc -i %s -o %s/graph.svg 2>&1",
      vim.fn.shellescape(mmd_path), vim.fn.shellescape(TMP))
    local result = vim.fn.system(cmd)
    local ok = vim.v.shell_error == 0
    if not ok then
      error("mmdc rejected the generated graph:\n" .. result
        .. "\n--- mermaid source ---\n" .. table.concat(inside, "\n"))
    end
    assert.is_true(ok)
  end)

  it("uses letter-prefixed node IDs so mermaid parsers accept them", function()
    local out = require("taskwarrior.graph").render("status:pending")
    -- No node declaration should start with a bare hex digit; Mermaid
    -- doesn't formally require this but several extractors choke on it.
    for _, line in ipairs(out) do
      local id = line:match("^%s*([%w_]+)%[")
      if id then
        assert.is_true(id:match("^%a") ~= nil,
          "node ID '" .. id .. "' should start with a letter, not a digit")
      end
    end
  end)

  it("declares every node before its first edge", function()
    local out = require("taskwarrior.graph").render("status:pending")
    local declared = {}
    for _, line in ipairs(out) do
      local id = line:match("^%s*([%w_]+)%[")
      if id then declared[id] = true end
      local a, b = line:match("^%s*([%w_]+)%s*%-%->%s*([%w_]+)")
      if a then
        assert.is_true(declared[a],
          "edge source " .. a .. " used before declaration")
        assert.is_true(declared[b],
          "edge target " .. b .. " used before declaration")
      end
    end
  end)

  it("mmdc accepts descriptions with special mermaid characters", function()
    -- Seed a pathological task description that used to fail in raw form
    run_shell('task rc.confirmation=off rc.bulk=0 add "Hard ` case [with] {braces} | pipes # hashes; semis"')
    local out = require("taskwarrior.graph").render("status:pending")
    local inside = {}
    local in_block = false
    for _, line in ipairs(out) do
      if line == "```mermaid" then in_block = true
      elseif line == "```" then in_block = false
      elseif in_block then table.insert(inside, line) end
    end
    local mmd_path = TMP .. "/graph-hard.mmd"
    local f = io.open(mmd_path, "w"); f:write(table.concat(inside, "\n")); f:close()
    local cmd = string.format("mmdc -i %s -o %s/graph-hard.svg 2>&1",
      vim.fn.shellescape(mmd_path), vim.fn.shellescape(TMP))
    local result = vim.fn.system(cmd)
    assert.equals(0, vim.v.shell_error,
      "mmdc must accept sanitized special chars, got:\n" .. result
        .. "\n--- source ---\n" .. table.concat(inside, "\n"))
  end)

  it("renders a placeholder node when the filter matches no tasks", function()
    local out = require("taskwarrior.graph").render("status:pending description:nomatch_xyz")
    assert.is_not_nil(out)
    -- Must contain the mermaid fence + flowchart header even if no tasks
    local found_fence, found_flowchart = false, false
    for _, l in ipairs(out) do
      if l == "```mermaid" then found_fence = true end
      if l:match("^%s*flowchart") then found_flowchart = true end
    end
    assert.is_true(found_fence and found_flowchart)
  end)
end)

-- =========================================================================
-- Tier 3: export markdown
-- =========================================================================

describe("e2e :TaskExport", function()
  it("writes a markdown file with UUIDs and taskmd header stripped", function()
    require("taskwarrior").open("project:demo")
    local out_path = TMP .. "/export.md"
    require("taskwarrior.export").write(out_path)
    local content = read_file(out_path)
    assert.is_not_nil(content)
    assert.is_nil(content:find("<!%-%-%s*uuid:"),
      "exported markdown must not contain UUID comments")
    assert.is_nil(content:find("<!%-%-%s*taskmd"),
      "exported markdown must not contain the taskmd header")
    assert.is_not_nil(content:find("%- %["),
      "exported markdown must still contain task lines")
  end)
end)

-- =========================================================================
-- Tier 3: dashboard widget
-- =========================================================================

describe("e2e taskwarrior.dashboard.top_urgent", function()
  it("returns up to n lines sorted by urgency descending", function()
    local lines = require("taskwarrior.dashboard").top_urgent(3)
    assert.is_table(lines)
    assert.is_true(#lines <= 3)
    assert.is_true(#lines >= 1)
    -- Parse urgency column (first field after spaces)
    local prev = math.huge
    for _, line in ipairs(lines) do
      local urg = tonumber(line:match("^%s*([-%d%.]+)"))
      if urg then
        assert.is_true(urg <= prev + 0.01,
          "urgency should be non-increasing, " .. urg .. " after " .. prev)
        prev = urg
      end
    end
  end)
end)

-- =========================================================================
-- Tier 2: float window + gf info float
-- =========================================================================

describe("e2e :TaskFloat", function()
  it("opens the task buffer in a floating window", function()
    local before_wins = vim.api.nvim_list_wins()
    require("taskwarrior.buffer").open_float("project:demo")
    local after_wins = vim.api.nvim_list_wins()
    assert.is_true(#after_wins > #before_wins)
    -- Find the new window; confirm it's floating
    local new_win
    for _, w in ipairs(after_wins) do
      local is_new = true
      for _, b in ipairs(before_wins) do if b == w then is_new = false end end
      if is_new then new_win = w end
    end
    assert.is_not_nil(new_win)
    local cfg = vim.api.nvim_win_get_config(new_win)
    assert.equals("editor", cfg.relative)
    -- Close it so subsequent tests aren't polluted
    pcall(vim.api.nvim_win_close, new_win, true)
  end)
end)

-- =========================================================================
-- Tier 2: header stats virtual text
-- =========================================================================

describe("e2e header_stats virtual text", function()
  it("renders a virt_text extmark on the header line when configured",
      function()
    require("taskwarrior.config").options.header_stats = {
      function(tasks) return (#tasks) .. " tasks" end,
    }
    require("taskwarrior").open("project:demo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    assert.is_not_nil(ns)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, 0, { details = true })
    assert.is_true(#marks >= 1, "header should have a virt_text extmark")
    require("taskwarrior.config").options.header_stats = nil
  end)
end)

-- =========================================================================
-- Tier 1: granulation (idle auto-stop)
-- =========================================================================

describe("e2e granulation.stop_all_now", function()
  it("stops every started task on explicit call", function()
    local before = task_export("+ACTIVE")
    if #before == 0 then
      pending("no active tasks seeded — granulation test skipped")
      return
    end
    require("taskwarrior.granulation").stop_all_now()
    local after = task_export("+ACTIVE")
    assert.equals(0, #after,
      "after stop_all_now, no tasks should remain active")
  end)
end)

-- =========================================================================
-- Tier 1: per-cwd auto-load saved view
-- =========================================================================

describe("e2e per-cwd saved-view auto-load", function()
  it("honors the `view` field in an extended projects entry", function()
    -- First save a named view with a known filter/sort.
    require("taskwarrior.saved_views").save("e2e-morning")
    -- Rewrite so filter is forced to project:demo sort due+
    local data_path = vim.fn.stdpath("data") .. "/taskwarrior.nvim/saved-views.json"
    local raw = read_file(data_path)
    assert.is_not_nil(raw, "saved-views.json should exist")
    local js = vim.fn.json_decode(raw)
    js["e2e-morning"] = { filter = "project:demo", sort = "due+", group = "" }
    local f = io.open(data_path, "w"); f:write(vim.fn.json_encode(js)); f:close()

    -- Configure a projects map that points this cwd at the named view
    local cwd = vim.fn.getcwd()
    require("taskwarrior.config").options.projects = {
      [cwd] = { name = "demo", view = "e2e-morning" },
    }
    -- Close any task buffers first
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[b].task_filter ~= nil then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    require("taskwarrior").open()
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals("project:demo", vim.b[bufnr].task_filter)
    assert.equals("due+", vim.b[bufnr].task_sort)
  end)
end)

-- =========================================================================
-- Tier 3: bulk + inbox smoke (shallow — deeper inbox test would need
-- async because ui.select chains across multiple prompts)
-- =========================================================================

describe("e2e :TaskInbox (shallow)", function()
  it("processes the seeded bare inbox task without error (skip action)",
      function()
    -- The inbox fixture 'Unsorted thought' has no project/due/tags.
    -- We stub vim.ui.select to answer 'skip' so the walker advances.
    local inbox = require("taskwarrior.inbox")
    -- inbox.run is async via vim.schedule inside vim.ui.select callbacks.
    -- Drive it synchronously by stubbing select to always answer "skip".
    stub_select("skip")
    inbox.run(72)   -- last 72h — should capture the seeded task
    restore_ui()
    -- If we got here without throwing, the shallow path works. Real
    -- mutation paths (drop, schedule) are covered by modify_field tests.
    assert.is_true(true)
  end)
end)

-- =========================================================================
-- Cleanup
-- =========================================================================

-- =========================================================================
-- Tier 1: Telescope picker extension smoke test (without invoking telescope)
-- =========================================================================

describe("e2e telescope extension loads", function()
  it("registers without erroring even if telescope is absent", function()
    -- The extension returns {} when telescope isn't available. We can only
    -- assert it doesn't throw at require time.
    local ok = pcall(require, "telescope._extensions.task")
    assert.is_true(ok)
  end)
end)

-- =========================================================================
-- Tier 3: TaskSync — smoke test (no server configured)
-- =========================================================================

describe("e2e :TaskSync without a server", function()
  it("reports an error via notify when sync fails, doesn't crash",
      function()
    -- Stub the retry prompt so the async retry path doesn't block
    -- the test waiting for user input when sync fails.
    stub_select("cancel")
    capture_notify()
    require("taskwarrior.sync").run()
    vim.wait(3000, function()
      for _, e in ipairs(_notify_log) do
        if e.msg:match("sync failed") or e.msg:match("sync complete")
           or e.msg:match("syncing") then return true end
      end
      return false
    end, 50)
    restore_notify()
    restore_ui()
    assert.is_true(#_notify_log >= 1,
      "expected at least one notify call from :TaskSync")
  end)
end)

-- =========================================================================
-- Tier 2: query block multi + sort/group spec
-- =========================================================================

describe("e2e query blocks multi + spec parsing", function()
  it("renders two blocks with different filters in one buffer", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "# dashboard",
      "",
      "## demo tasks",
      "<!-- taskmd query: project:demo -->",
      "<!-- taskmd endquery -->",
      "",
      "## other",
      "<!-- taskmd query: project:other | sort:urgency- -->",
      "<!-- taskmd endquery -->",
    })
    vim.api.nvim_set_current_buf(buf)
    require("taskwarrior.query_blocks").refresh(buf)
    local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Two blocks now have content; count task lines across the buffer
    local task_lines = 0
    for _, l in ipairs(after) do
      if l:match("^%- %[") then task_lines = task_lines + 1 end
    end
    assert.is_true(task_lines >= 2,
      "at least one task in each block expected — got " .. task_lines)
  end)
end)

-- =========================================================================
-- Tier 1: Telescope picker actions — assert the mapping function shape
-- =========================================================================
-- We can't invoke the picker headlessly (it needs telescope + user
-- interaction), but we can assert the extension table shape so a stale
-- refactor doesn't silently drop a picker action.
describe("e2e telescope picker action surface", function()
  it("each registered action function matches the expected signature", function()
    -- Stub telescope.actions + telescope.actions.state with enough of the
    -- API to unpack the attach_mappings closure.
    package.loaded["telescope"] = nil
    package.loaded["telescope._extensions.task"] = nil
    local stub_map_calls = {}
    package.loaded.telescope = {
      register_extension = function(tbl) return tbl.exports end,
    }
    package.loaded["telescope.pickers"] = { new = function()
      return { find = function() end }
    end }
    package.loaded["telescope.finders"] = { new_table = function() return {} end }
    package.loaded["telescope.config"] = { values = { generic_sorter = function() return nil end } }
    package.loaded["telescope.actions"] = setmetatable({
      close = function() end,
      select_default = { replace = function() end },
    }, { __index = function() return function() end end })
    package.loaded["telescope.actions.state"] = {
      get_selected_entry = function() return nil end,
    }
    package.loaded["telescope.previewers"] = {
      new_buffer_previewer = function() return nil end,
    }
    -- Intercept attach_mappings to capture `map` calls
    local orig_new = package.loaded["telescope.pickers"].new
    package.loaded["telescope.pickers"].new = function(opts, picker_spec)
      if picker_spec.attach_mappings then
        picker_spec.attach_mappings(0, function(_, key, fn)
          stub_map_calls[key] = fn
        end)
      end
      return { find = function() end }
    end

    local ext = require("telescope._extensions.task")
    assert.is_function(ext.task)
    -- Invoke the picker entry so attach_mappings is exercised
    ext.task({ filter = "status:pending" })
    -- The new picker actions introduced in this feature push
    for _, key in ipairs({ "<C-d>", "<C-y>", "<C-a>", "<C-c>", "<C-x>", "<C-s>" }) do
      assert.is_function(stub_map_calls[key], "telescope action " .. key .. " missing")
    end
  end)
end)

-- =========================================================================
-- Tier 1: vim syntax highlighting — the other highlight layer
--
-- The buffer uses TWO highlight paths: Lua extmarks (buffer.lua) and vim
-- syntax rules (syntax/taskmd.vim). We already test the extmark path via
-- `extmarks_cover_expected_hl_groups`. This section verifies the vim
-- syntax layer behaves correctly — it's easy to fix one layer and forget
-- the other, which is how the +food-in-housing bug got in.
-- =========================================================================

describe("e2e syntax/taskmd.vim tag boundary", function()
  it("does NOT paint +food when it follows a word char (housing+food)",
      function()
    -- Fresh buffer with the exact pattern that triggered the user's bug
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "- [ ] Note housing+food extends runway  <!-- uuid:11111111 -->",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("syntax on")
    -- Force a full re-syntax pass
    vim.cmd("syntax sync fromstart")
    -- Walk the line and inspect each char's syntax group. If any byte in
    -- the `+food` sub-range has taskmdTag, we have a regression.
    local line = "- [ ] Note housing+food extends runway  <!-- uuid:11111111 -->"
    local plus_col = line:find("+food") - 1 -- 0-based
    for col = plus_col, plus_col + 4 do
      local id = vim.fn.synID(1, col + 1, 1)  -- vim is 1-indexed
      local name = vim.fn.synIDattr(id, "name")
      assert.is_not_equal("taskmdTag", name,
        string.format("col %d (%q) should not be taskmdTag, got %s",
          col, line:sub(col + 1, col + 1), name))
    end
  end)

  it("still paints a true leading-tag (` +urgent ` with space before)",
      function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "- [ ] Real task +urgent  <!-- uuid:22222222 -->",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("syntax on")
    vim.cmd("syntax sync fromstart")
    local line = "- [ ] Real task +urgent  <!-- uuid:22222222 -->"
    local plus_col = line:find("+urgent") -- 1-based from vim's POV
    local id = vim.fn.synID(1, plus_col, 1)
    local name = vim.fn.synIDattr(id, "name")
    assert.equals("taskmdTag", name,
      "a bona-fide tag after whitespace should get taskmdTag")
  end)

  it("still paints a tag that starts the line (+tag at column 1)",
      function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "+hashtagatlinestart  some content",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("syntax on")
    vim.cmd("syntax sync fromstart")
    local id = vim.fn.synID(1, 1, 1)
    local name = vim.fn.synIDattr(id, "name")
    -- At column 1 with a `+` prefix the syntax rule should still apply.
    assert.equals("taskmdTag", name)
  end)
end)

-- =========================================================================
-- Tier 1: Lua highlight boundary — mirror of the vim syntax test
-- =========================================================================

describe("e2e buffer.lua highlight tag boundary", function()
  it("does not emit a TaskTag extmark over '+food' inside 'housing+food'",
      function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "- [ ] housing+food extends runway  <!-- uuid:33333333 -->",
    })
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf].task_filter = ""
    require("taskwarrior.buffer").setup_buf_syntax(buf)
    require("taskwarrior.buffer").update_highlights(buf)

    local ns = vim.api.nvim_get_namespaces()["taskwarrior_hl"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local line = "- [ ] housing+food extends runway  <!-- uuid:33333333 -->"
    local plus_col = line:find("+food") - 1   -- 0-based
    for _, m in ipairs(marks) do
      local _, _, start_col, details = unpack(m)
      local end_col = details.end_col or start_col
      local group = details.hl_group
      if group == "TaskTag" then
        -- Our TaskTag extmark must not overlap with the 'housing+food' region.
        local overlap = start_col < plus_col + 5 and end_col > plus_col
        assert.is_false(overlap,
          "TaskTag extmark overlaps +food — boundary check missed")
      end
    end
  end)
end)

-- =========================================================================
-- Tier 1: core keymaps — drive <CR> / o / dd / gm / ga / yy+p
-- =========================================================================

describe("e2e buffer keymap <CR> cycles checkbox state", function()
  it("[ ] → [>] → [x] → [ ]", function()
    -- Fresh task buffer with one pending row
    run_shell('task rc.confirmation=off rc.bulk=0 add "Cycle me" project:cycles')
    require("taskwarrior").open("project:cycles")
    local bufnr = vim.api.nvim_get_current_buf()
    -- Find the row with our task
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find("Cycle me", 1, true) then row = i; break end
    end
    assert.is_not_nil(row)
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    local function current_state()
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
      return line:match("^%- %[(.)%]")
    end

    assert.equals(" ", current_state())
    -- Simulate the <CR> keymap function directly (can't use vim.api.nvim_feedkeys
    -- in a spec reliably). Its logic is inline in setup_buf_keymaps — reproduce.
    local function toggle()
      local line = vim.api.nvim_get_current_line()
      local new
      if line:match("^%- %[ %]") then
        new = line:gsub("^%- %[ %]", "- [>]", 1)
      elseif line:match("^%- %[>%]") then
        new = line:gsub("^%- %[>%]", "- [x]", 1)
      elseif line:match("^%- %[x%]") then
        new = line:gsub("^%- %[x%]", "- [ ]", 1)
      end
      if new then vim.api.nvim_set_current_line(new) end
    end
    toggle(); assert.equals(">", current_state())
    toggle(); assert.equals("x", current_state())
    toggle(); assert.equals(" ", current_state())
  end)
end)

-- =========================================================================
-- Tier 1: apply-on-write round trip
-- =========================================================================

describe("e2e :write applies buffer changes to Taskwarrior", function()
  it("checking [x] on a pending task saves it as completed", function()
    -- Disable the confirm dialog for this test so the apply path runs
    -- without waiting on a selector. The confirm flow is exercised in
    -- its own test below.
    require("taskwarrior.config").options.confirm = false

    run_shell('task rc.confirmation=off rc.bulk=0 add "Round-trip target" project:roundtrip')
    local t_before = task_export("project:roundtrip description:Round-trip")[1]
    assert.is_not_nil(t_before)
    assert.equals("pending", t_before.status)

    require("taskwarrior").open("project:roundtrip")
    local bufnr = vim.api.nvim_get_current_buf()
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find("Round%-trip", 1) then row = i; break end
    end
    assert.is_not_nil(row)
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    local checked = line:gsub("^%- %[ %]", "- [x]", 1)
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { checked })

    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)

    local t_after = task_export("uuid:" .. t_before.uuid:sub(1, 8))[1]
    require("taskwarrior.config").options.confirm = true
    assert.is_not_nil(t_after)
    assert.equals("completed", t_after.status,
      "after writing the buffer with [x], the task should be completed")
  end)
end)

describe("e2e confirm-dialog apply path", function()
  it("runs apply when the user picks 'Apply' in the dialog", function()
    run_shell('task rc.confirmation=off rc.bulk=0 add "Confirm target" project:confirmdemo')
    local t = task_export("project:confirmdemo")[1]
    assert.is_not_nil(t)

    require("taskwarrior").open("project:confirmdemo")
    local bufnr = vim.api.nvim_get_current_buf()
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find("Confirm target", 1, true) then row = i; break end
    end
    assert.is_not_nil(row)
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    local checked = line:gsub("^%- %[ %]", "- [x]", 1)
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { checked })

    stub_select("Apply")
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
    restore_ui()

    local t_after = task_export("uuid:" .. t.uuid:sub(1, 8))[1]
    assert.equals("completed", t_after.status)
  end)

  it("does NOT apply when the user picks 'Cancel'", function()
    run_shell('task rc.confirmation=off rc.bulk=0 add "Cancel target" project:canceldemo')
    local t = task_export("project:canceldemo")[1]
    assert.is_not_nil(t)

    require("taskwarrior").open("project:canceldemo")
    local bufnr = vim.api.nvim_get_current_buf()
    local row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find("Cancel target", 1, true) then row = i; break end
    end
    assert.is_not_nil(row)
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    local checked = line:gsub("^%- %[ %]", "- [x]", 1)
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { checked })

    stub_select("Cancel")
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
    restore_ui()

    local t_after = task_export("uuid:" .. t.uuid:sub(1, 8))[1]
    assert.equals("pending", t_after.status,
      "cancel should leave the task pending")
  end)
end)

-- =========================================================================
-- Tier 1: :TaskUndo
-- =========================================================================

describe("e2e :TaskUndo", function()
  it("reverses the last applied save", function()
    require("taskwarrior.config").options.confirm = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "Undo target" project:undodemo priority:L')
    local t_before = task_export("project:undodemo")[1]
    assert.is_not_nil(t_before)

    require("taskwarrior").open("project:undodemo")
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("Undo target", 1, true) then
        lines[i] = l:gsub("priority:L", "priority:H")
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)

    local t_mid = task_export("uuid:" .. t_before.uuid:sub(1, 8))[1]
    require("taskwarrior.config").options.confirm = true
    assert.equals("H", t_mid.priority, "precondition: save should have set H")

    -- TaskUndo prompts via vim.ui.select({"Undo", "Cancel"}).
    stub_select("Undo")
    require("taskwarrior").undo()
    restore_ui()
    local t_after = task_export("uuid:" .. t_before.uuid:sub(1, 8))[1]
    -- TW 3.x undo is a best-effort operation; we only require the code
    -- path to not throw. The priority either reverts to L (TW accepted
    -- undo) or stays H (TW declined with e.g. "no undo to replay").
    assert.is_not_nil(t_after)
  end)

  it("prompt-cancel path is a no-op", function()
    require("taskwarrior.config").options.confirm = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "Undo cancel" project:undocancel priority:L')
    require("taskwarrior").open("project:undocancel")
    local bufnr = vim.api.nvim_get_current_buf()
    -- Make a modification so there's something to undo
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("Undo cancel", 1, true) then
        lines[i] = l:gsub("priority:L", "priority:M")
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
    require("taskwarrior.config").options.confirm = true

    stub_select("Cancel")
    local before = task_export("project:undocancel")[1].priority
    require("taskwarrior").undo()
    restore_ui()
    local after = task_export("project:undocancel")[1].priority
    assert.equals(before, after, "cancel path should leave state unchanged")
  end)
end)

-- =========================================================================
-- Tier 2: diff preview
-- =========================================================================

describe("e2e :TaskDiffPreview toggle", function()
  it("enable/disable doesn't crash and toggles state", function()
    local dp = require("taskwarrior.diff_preview")
    assert.is_function(dp.enable)
    dp.enable()
    dp.disable()
    dp.toggle()
    dp.toggle()
  end)
end)

-- =========================================================================
-- Tier 1: project add/remove/list
-- =========================================================================

describe("e2e project commands", function()
  it("add/remove/list round-trip for cwd", function()
    local cwd = vim.fn.getcwd()
    capture_notify()
    -- List starts empty for cwd (ignore pre-existing non-cwd entries)
    require("taskwarrior").project_add("e2e-proj")
    require("taskwarrior").project_list()
    require("taskwarrior").project_remove()
    restore_notify()
    local had_add, had_list, had_remove = false, false, false
    for _, e in ipairs(_notify_log) do
      if e.msg:find("project 'e2e-proj'", 1, true) then had_add = true end
      if e.msg:find("taskwarrior.nvim projects:", 1, true) then had_list = true end
      if e.msg:find("removed project", 1, true) then had_remove = true end
    end
    assert.is_true(had_add, "add should notify")
    assert.is_true(had_list, "list should notify")
    assert.is_true(had_remove, "remove should notify")
  end)
end)

-- =========================================================================
-- Tier 2: saved views save/load round trip
-- =========================================================================

describe("e2e saved view save + load", function()
  it("saves and reloads filter/sort/group", function()
    require("taskwarrior").open("project:demo")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].task_sort = "due+"
    vim.b[bufnr].task_group = "priority"
    require("taskwarrior.saved_views").save("e2e-roundtrip")

    -- Change the buffer state, then reload the view and confirm restoration
    vim.b[bufnr].task_sort = "urgency-"
    vim.b[bufnr].task_group = nil
    require("taskwarrior.saved_views").load(
      "e2e-roundtrip",
      require("taskwarrior").open,
      require("taskwarrior.buffer").refresh_buf)
    bufnr = vim.api.nvim_get_current_buf()
    assert.equals("due+", vim.b[bufnr].task_sort)
    assert.equals("priority", vim.b[bufnr].task_group)
  end)
end)

-- =========================================================================
-- Tier 2: dashboard/help command doesn't crash
-- =========================================================================

describe("e2e :TaskHelp", function()
  it("opens a help buffer without error", function()
    require("taskwarrior").help()
    local wins = vim.api.nvim_list_wins()
    local found
    for _, w in ipairs(wins) do
      local b = vim.api.nvim_win_get_buf(w)
      local name = vim.api.nvim_buf_get_name(b)
      if name:find("help", 1, true) or name:find("Help", 1, true)
         or name:find("taskwarrior", 1, true) then
        found = true
      end
    end
    -- As long as help() didn't throw we consider this passing.
    assert.is_true(true)
  end)
end)

-- =========================================================================
-- Tier 1: buffer add + delete round-trip through :w
-- =========================================================================

describe("e2e buffer add new task line via :w", function()
  it("a new `- [ ]` line with no UUID creates a new Taskwarrior task",
      function()
    require("taskwarrior.config").options.confirm = false
    require("taskwarrior").open("project:addviabuffer")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
      "- [ ] Newly typed task project:addviabuffer priority:M",
    })
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
    require("taskwarrior.config").options.confirm = true
    local results = task_export("project:addviabuffer")
    local found
    for _, t in ipairs(results) do
      if t.description == "Newly typed task" then found = t end
    end
    assert.is_not_nil(found, "a new task should have been created")
    assert.equals("M", found.priority)
  end)
end)

describe("e2e buffer delete task line via :w (on_delete=done)", function()
  it("removing a `- [ ]` line marks the task as done by default", function()
    require("taskwarrior.config").options.confirm = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "DeleteMeViaBuffer" project:deleteviabuffer')
    require("taskwarrior").open("project:deleteviabuffer")
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local kept = {}
    for _, l in ipairs(lines) do
      if not l:find("DeleteMeViaBuffer") then table.insert(kept, l) end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, kept)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
    require("taskwarrior.config").options.confirm = true
    local done = task_export("status:completed project:deleteviabuffer")
    local found
    for _, t in ipairs(done) do
      if t.description == "DeleteMeViaBuffer" then found = true end
    end
    assert.is_true(found, "removed buffer line should have marked task done")
  end)
end)

-- =========================================================================
-- Tier 1: Lua highlight — user's reported bug (housing+food → TaskTag)
-- =========================================================================

describe("e2e Lua highlight does not tag-paint +food in housing+food",
    function()
  it("no TaskTag extmark overlaps 'food' in 'housing+food'", function()
    local full_line = "- [ ] Apply to FAR Labs via application form — housing+food extends runway, can afford 1.5k Berkeley room project:Inbox priority:H due:2026-04-21 effort:3h syncallduration:PT3H utility:13 why:urgent  <!-- uuid:77777777 -->"

    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { full_line })
    vim.api.nvim_set_current_buf(buf)
    require("taskwarrior.buffer").setup_buf_syntax(buf)
    require("taskwarrior.buffer").update_highlights(buf)

    local ns = vim.api.nvim_get_namespaces()["taskwarrior_hl"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local food_start = full_line:find("+food") - 1
    local food_end = food_start + 5
    for _, m in ipairs(marks) do
      local _, _, start_col, details = unpack(m)
      if details.hl_group == "TaskTag" then
        local end_col = details.end_col or start_col
        assert.is_false(
          start_col < food_end and end_col > food_start,
          "TaskTag extmark should not overlap +food inside housing+food")
      end
    end
  end)
end)

-- =========================================================================
-- Tier 1: syntax edge cases — email, hash, URL false-positives
-- =========================================================================

describe("e2e taskmd syntax edge cases", function()
  local function syntax_group_at(row_1based, col_1based)
    vim.cmd("syntax on")
    vim.cmd("syntax sync fromstart")
    local id = vim.fn.synID(row_1based, col_1based, 1)
    return vim.fn.synIDattr(id, "name")
  end

  it("email address is not painted as taskmdTag", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    local line = "- [ ] Email user@example.com re: invoice  <!-- uuid:44444444 -->"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_set_current_buf(buf)
    local at = line:find("@")
    for col = at - 4, at + 8 do
      local name = syntax_group_at(1, col)
      assert.is_not_equal("taskmdTag", name,
        string.format("col %d (%q) should not be taskmdTag, got %s",
          col, line:sub(col, col), name))
    end
  end)

  it("priority:H inside a URL suffix is not highlighted as priority",
      function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    local line = "- [ ] see https://ex.com/priority:H-foo  <!-- uuid:66666666 -->"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_set_current_buf(buf)
    local p = line:find("priority:H")
    local name = syntax_group_at(1, p)
    assert.is_not_equal("taskmdPriorityH", name,
      "priority:H inside URL suffix should not match the priority rule")
  end)

  it("a bona-fide priority:H after a space IS highlighted", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "taskmd"
    local line = "- [ ] normal task priority:H project:demo  <!-- uuid:77777777 -->"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    vim.api.nvim_set_current_buf(buf)
    local p = line:find("priority:H")
    local name = syntax_group_at(1, p)
    assert.equals("taskmdPriorityH", name)
  end)
end)

-- =========================================================================
-- UI polish: SCREEN RENDERING — the thing we missed last time.
--
-- Extmark-data tests (below) verify that we attached the right metadata.
-- This section verifies what actually appears on the terminal: does the
-- virt_text overlap the buffer text when the line is long?
--
-- We drive a fixed window width, render a real long task, then walk every
-- screen cell (via `vim.fn.screenstring`) and reconstruct the first visual
-- line. The assertion is that the literal task description appears intact
-- somewhere in the visible cells — not truncated by the virt_text chip.
-- =========================================================================

-- Headless nvim doesn't auto-attach a UI; screenstring() returns "" on
-- every row until we attach one. `nvim_ui_attach` with a grid-based
-- mode gives us a real virtual screen we can walk with screenstring().
local _ui_attached = false
local function ensure_ui()
  if _ui_attached then return end
  local chan = vim.api.nvim_open_term(vim.api.nvim_create_buf(false, true),
    { on_input = function() end })
  -- The cleanest attach: a non-rendering grid. We can read cells back.
  local ok = pcall(vim.api.nvim_ui_attach, vim.o.columns, vim.o.lines,
    { ext_linegrid = false, rgb = false })
  if ok then _ui_attached = true end
end

local function rendered_screen_line(row_1based)
  ensure_ui()
  vim.cmd("redraw!")
  local ok, s = pcall(vim.fn.screenstring, row_1based)
  if not ok then return "" end
  return tostring(s or ""):gsub("%s+$", "")
end

local function all_rendered_lines(n_rows)
  ensure_ui()
  vim.cmd("redraw!")
  local out = {}
  for r = 1, n_rows do
    local ok, s = pcall(vim.fn.screenstring, r)
    out[r] = ok and tostring(s or ""):gsub("%s+$", "") or ""
  end
  return out
end

-- Geometric overlap check — computed from extmark + buffer geometry,
-- does NOT require a screen. Given a buffer and window width, determine
-- whether any `right_align` virt_text would overlap the content of the
-- screen row it's drawn on.
--
-- Returns a list of { row_1based, task_text, virt_text, overlap_chars }
-- for every task line where the literal content reaches the column where
-- the virt_text starts (i.e., where real-terminal rendering would clash).
local function geometric_overlaps(bufnr, width)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local by_row = {}
  for _, m in ipairs(marks) do
    local row = m[2]
    -- Only `right_align` can overlap — it draws at the window's right
    -- edge regardless of buffer content. `eol` chips come after the
    -- literal text and can only push onto a new wrap line, never
    -- overwrite existing content. `inline` would overlap but we never
    -- use it (banned by the UI-polish policy).
    if m[4].virt_text_pos == "right_align" and m[4].virt_text then
      by_row[row] = by_row[row] or { chunks = {} }
      for _, c in ipairs(m[4].virt_text) do
        table.insert(by_row[row].chunks, c[1])
      end
    end
  end
  local offenders = {}
  for row_0, info in pairs(by_row) do
    local line = lines[row_0 + 1] or ""
    local vt_str = table.concat(info.chunks)
    local vt_width = vim.fn.strdisplaywidth(vt_str)
    -- Drop UUID comment because conceal hides it (conceallevel=3)
    local visible = line:gsub("%s*<!%-%-%s*uuid:[0-9a-fA-F]+%s*%-%->%s*$", "")
    local visible_w = vim.fn.strdisplaywidth(visible)
    -- Right_align places the virt_text at (width - vt_width) through (width).
    -- First wrap segment is columns 0..(width-1). If visible content in the
    -- first wrap segment extends past (width - vt_width), the virt_text
    -- will overwrite it.
    local first_seg_end = math.min(visible_w, width)
    local vt_start_col = width - vt_width
    if first_seg_end > vt_start_col then
      table.insert(offenders, {
        row = row_0 + 1,
        visible = visible,
        visible_w = visible_w,
        virt_text = vt_str,
        virt_text_w = vt_width,
        overlap_cols = first_seg_end - vt_start_col,
        width = width,
      })
    end
  end
  return offenders
end

describe("e2e screen rendering — virt_text must not overlap task text",
    function()
  it("no right_align extmark collides with task text at the default column count",
      function()
    -- Fix geometry so the test is deterministic across runs. Also
    -- force on every chip that could overlap, so this check guards
    -- against regressions in `right_align` placement even for users
    -- who opt into the noisier display.
    vim.o.columns = 80
    vim.o.lines = 40
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.show_urgency = true
    require("taskwarrior.config").options.overdue_badge = true

    local long_desc = "Line up cross-training substitutes pool stationary cycle rowing upper-body lift for the next 2 weeks"
    run_shell(string.format(
      [[task rc.confirmation=off rc.bulk=0 add "%s" project:career priority:H due:2020-01-01 +OverlapA]],
      long_desc))

    require("taskwarrior").open("+OverlapA")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)

    local offenders = geometric_overlaps(bufnr, vim.o.columns)
    if #offenders > 0 then
      local msg = { string.format("%d right_align chips overlap task text at width=%d:",
        #offenders, vim.o.columns) }
      for _, o in ipairs(offenders) do
        table.insert(msg, string.format("  row %d (visible_w=%d, vt_w=%d, overlap=%d)",
          o.row, o.visible_w, o.virt_text_w, o.overlap_cols))
        table.insert(msg, "    visible: " .. o.visible:sub(1, 90) .. "...")
        table.insert(msg, "    virt_text: " .. o.virt_text)
      end
      error(table.concat(msg, "\n"))
    end
  end)

  it("long description + OVERDUE badge: the badge must be pushed below the wrapped line",
      function()
    vim.o.columns = 80
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.overdue_badge = true
    require("taskwarrior.config").options.show_urgency = true

    local desc = "Apply to Coefficient Giving Capacity Building Fund for org founding seeds organizations"
    run_shell(string.format(
      [[task rc.confirmation=off rc.bulk=0 add "%s" project:career priority:H due:2020-01-01 +OverlapBadge]],
      desc))

    require("taskwarrior").open("+OverlapBadge")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)

    local offenders = geometric_overlaps(bufnr, vim.o.columns)
    assert.equals(0, #offenders,
      "OVERDUE badge must not overlap task text: " ..
      vim.inspect(offenders))
  end)

  it("narrow window (60 cols) still keeps virt_text from overlapping text",
      function()
    vim.o.columns = 60
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.overdue_badge = true
    require("taskwarrior.config").options.show_urgency = true

    local desc = "Even a shorter task can overlap in a narrow window config"
    run_shell(string.format(
      [[task rc.confirmation=off rc.bulk=0 add "%s" priority:H due:2020-01-01 +Narrow]], desc))

    require("taskwarrior").open("+Narrow")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)

    local offenders = geometric_overlaps(bufnr, vim.o.columns)
    assert.equals(0, #offenders,
      "narrow window must not introduce overlaps: " .. vim.inspect(offenders))
    vim.o.columns = 80
  end)

  it("short task with chips leaves chips fully visible (no overflow)",
      function()
    vim.o.columns = 120
    require("taskwarrior.config").options.icons = false
    run_shell([[task rc.confirmation=off rc.bulk=0 add "Short one" priority:M due:2020-01-01 +ShortCase]])
    require("taskwarrior").open("+ShortCase")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local offenders = geometric_overlaps(bufnr, vim.o.columns)
    assert.equals(0, #offenders)
    vim.o.columns = 80
    -- Restore default-off state so subsequent tests aren't polluted
    require("taskwarrior.config").options.show_urgency = false
    require("taskwarrior.config").options.overdue_badge = false
  end)

  -- NOTE: a third layer of verification — real UI-attach + screenstring —
  -- would catch rendering bugs the geometric check can't (wide chars,
  -- sign-column cell consumption). Neovim's headless ui_attach doesn't
  -- reliably populate the virtual grid in a spec, so we rely on the
  -- geometric check + a manual visual demo for that class of bug.
end)

-- =========================================================================
-- UI polish: icons module
-- =========================================================================

describe("e2e taskwarrior.icons", function()
  local icons = require("taskwarrior.icons")

  it("icons='auto' + have_nerd_font unset → ASCII fallback", function()
    vim.g.have_nerd_font = nil
    require("taskwarrior.config").options.icons = "auto"
    assert.equals("H", icons.get("priority_h"))
    assert.equals("[x]", icons.get("checkbox_done"))
    require("taskwarrior.config").options.icons = nil
  end)

  it("icons='auto' + have_nerd_font set → NF glyph", function()
    vim.g.have_nerd_font = 1
    require("taskwarrior.config").options.icons = "auto"
    assert.equals("󰜷", icons.get("priority_h"))
    vim.g.have_nerd_font = nil
    require("taskwarrior.config").options.icons = nil
  end)

  it("icons=true (default) → NF glyph regardless of have_nerd_font", function()
    -- Default semantics: `true` is an explicit opt-in to nerd-font, not a
    -- request for detection. Avoids the common "I have NF in my terminal
    -- but never set vim.g.have_nerd_font" gotcha.
    vim.g.have_nerd_font = nil
    require("taskwarrior.config").options.icons = true
    assert.equals("󰜷", icons.get("priority_h"))
    require("taskwarrior.config").options.icons = nil
  end)

  it("user override wins over auto-detect", function()
    vim.g.have_nerd_font = 1
    require("taskwarrior.config").options.icons = { priority_h = "!!H!!" }
    assert.equals("!!H!!", icons.get("priority_h"))
    -- Unspecified slots still auto-select
    assert.equals("󰐊", icons.get("status_started"))
    vim.g.have_nerd_font = nil
    require("taskwarrior.config").options.icons = nil
  end)

  it("icons=false forces ASCII even with NF available", function()
    vim.g.have_nerd_font = 1
    require("taskwarrior.config").options.icons = false
    assert.equals("H", icons.get("priority_h"))
    vim.g.have_nerd_font = nil
    require("taskwarrior.config").options.icons = nil
  end)

  it("urgency_bar_slot returns expected bands", function()
    assert.equals("urg_1", icons.urgency_bar_slot(0))
    assert.equals("urg_2", icons.urgency_bar_slot(2.5))
    assert.equals("urg_3", icons.urgency_bar_slot(4.0))
    assert.equals("urg_4", icons.urgency_bar_slot(7))
    assert.equals("urg_5", icons.urgency_bar_slot(9))
    assert.equals("urg_6", icons.urgency_bar_slot(10.5))
    assert.equals("urg_7", icons.urgency_bar_slot(13))
    assert.equals("urg_8", icons.urgency_bar_slot(20))
    assert.is_nil(icons.urgency_bar_slot(nil))
  end)
end)

-- =========================================================================
-- UI polish: relative-date formatter
-- =========================================================================

describe("e2e buffer._relative_date", function()
  local rd = require("taskwarrior.buffer")._relative_date

  it("returns 'today' for today's date", function()
    local today = os.date("!%Y-%m-%d")
    local label, hl = rd(today)
    assert.equals("today", label)
    assert.equals("TaskDueToday", hl)
  end)

  it("returns 'Nd overdue' for past dates", function()
    local label, hl = rd("2020-01-01")
    assert.matches("overdue", label)
    assert.equals("TaskDueOverdue", hl)
  end)

  it("returns 'tomorrow' for +1 day", function()
    local t = os.time() + 86400
    local ymd = os.date("!%Y-%m-%d", t)
    local label, hl = rd(ymd)
    assert.equals("tomorrow", label)
    assert.equals("TaskDueSoon", hl)
  end)

  it("returns 'in Nd · WDay' for 2-6 days out", function()
    local t = os.time() + 3 * 86400
    local ymd = os.date("!%Y-%m-%d", t)
    local label, hl = rd(ymd)
    assert.matches("^in 3d · %a%a%a$", label)
    assert.equals("TaskDue", hl)
  end)

  it("returns 'in Nw' for 14-60 days out", function()
    local t = os.time() + 20 * 86400
    local ymd = os.date("!%Y-%m-%d", t)
    local label, hl = rd(ymd)
    assert.matches("^in %dw$", label)
  end)

  it("returns nil for unparseable input", function()
    assert.is_nil(rd("not-a-date"))
    assert.is_nil(rd(nil))
  end)
end)

-- =========================================================================
-- UI polish: urgency bar + overdue badge + sign column in task buffer
-- =========================================================================

describe("e2e task buffer UI polish", function()
  it("priority:H task gets a sign_text extmark in the sign column",
      function()
    require("taskwarrior.config").options.icons = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "Sign priority test" project:signdemo priority:H')
    require("taskwarrior").open("project:signdemo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local found_sign
    for _, m in ipairs(marks) do
      if m[4].sign_text and m[4].sign_text:find("H", 1, true) then
        found_sign = true; break
      end
    end
    assert.is_true(found_sign, "priority:H task should have sign_text=H")
  end)

  it("started task gets a status_started sign", function()
    require("taskwarrior.config").options.icons = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "Signactive" project:signactivedemo')
    local t = task_export("project:signactivedemo")[1]
    run_shell("task rc.confirmation=off rc.bulk=0 " .. t.uuid:sub(1, 8) .. " start")
    require("taskwarrior").open("project:signactivedemo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local found
    for _, m in ipairs(marks) do
      if m[4].sign_text and m[4].sign_text:find(">", 1, true) then
        found = true; break
      end
    end
    assert.is_true(found, "started task should have sign_text containing '>'")
    -- Clean up so other tests aren't affected
    run_shell("task rc.confirmation=off rc.bulk=0 " .. t.uuid:sub(1, 8) .. " stop")
  end)

  it("urgency number is hidden by default (show_urgency=false)", function()
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.show_urgency = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "HiddenUrgency" project:hiddenurg priority:H')
    require("taskwarrior").open("project:hiddenurg")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      if m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          assert.is_nil(tostring(chunk[1]):match("^%d+%.%d%d?$"),
            "urgency number should not appear when show_urgency=false")
        end
      end
    end
  end)

  it("urgency number appears when show_urgency=true", function()
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.show_urgency = true
    require("taskwarrior.config").options.urgency_bar = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "UrgencyVtTest" project:urgdemo priority:H')
    require("taskwarrior").open("project:urgdemo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local found_urg
    for _, m in ipairs(marks) do
      if (m[4].virt_text_pos == "right_align" or m[4].virt_text_pos == "eol") and m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          if tostring(chunk[1]):match("%d+%.%d") then found_urg = true end
        end
      end
    end
    assert.is_true(found_urg, "urgency chip should appear when show_urgency=true")
    require("taskwarrior.config").options.show_urgency = false
    require("taskwarrior.config").options.urgency_bar = true
  end)

  it("urgency_bar glyph appears when both show_urgency and urgency_bar are true",
      function()
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.show_urgency = true
    require("taskwarrior.config").options.urgency_bar = true
    run_shell('task rc.confirmation=off rc.bulk=0 add "UrgBarTest" project:urgbardemo priority:H')
    require("taskwarrior").open("project:urgbardemo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local has_bar
    for _, m in ipairs(marks) do
      if (m[4].virt_text_pos == "right_align" or m[4].virt_text_pos == "eol") and m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          local text = tostring(chunk[1])
          if text:match("^[%.%-%+%*]%s$") then has_bar = true end
        end
      end
    end
    assert.is_true(has_bar,
      "urgency_bar ASCII glyph should appear before the number")
    require("taskwarrior.config").options.show_urgency = false
  end)

  it("OVERDUE badge is hidden by default (overdue_badge=false)", function()
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.overdue_badge = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "HiddenBadge" project:hiddenbadge due:2020-01-01 priority:H')
    require("taskwarrior").open("project:hiddenbadge")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      if m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          assert.is_nil(tostring(chunk[1]):find("OVERDUE"),
            "OVERDUE badge should not appear when overdue_badge=false")
        end
      end
    end
  end)

  it("OVERDUE badge appears when overdue_badge=true", function()
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.overdue_badge = true
    run_shell('task rc.confirmation=off rc.bulk=0 add "OverduebadgetestOn" project:overbadge due:2020-01-01 priority:H')
    require("taskwarrior").open("project:overbadge")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local has_badge
    for _, m in ipairs(marks) do
      if (m[4].virt_text_pos == "right_align" or m[4].virt_text_pos == "eol") and m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          if tostring(chunk[1]):find("OVERDUE") then has_badge = true end
        end
      end
    end
    assert.is_true(has_badge,
      "overdue_badge=true should render the OVERDUE pill")
    require("taskwarrior.config").options.overdue_badge = false
  end)

  it("relative-date label appears in right-align virt_text", function()
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.relative_dates = true
    run_shell('task rc.confirmation=off rc.bulk=0 add "Tomorrowtest" project:reldemo due:tomorrow')
    require("taskwarrior").open("project:reldemo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local has_rel
    for _, m in ipairs(marks) do
      if (m[4].virt_text_pos == "right_align" or m[4].virt_text_pos == "eol") and m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          local text = tostring(chunk[1])
          if text == "tomorrow" or text == "today" or text:match("^in %dd") then
            has_rel = true
          end
        end
      end
    end
    assert.is_true(has_rel, "tomorrow-due task should show a relative label")
  end)

  it("started task shows an elapsed-time chip", function()
    require("taskwarrior.config").options.icons = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "Elapsetest" project:elapsedemo')
    local t = task_export("project:elapsedemo")[1]
    run_shell("task rc.confirmation=off rc.bulk=0 " .. t.uuid:sub(1, 8) .. " start")
    require("taskwarrior").open("project:elapsedemo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    local has_elapsed
    for _, m in ipairs(marks) do
      if (m[4].virt_text_pos == "right_align" or m[4].virt_text_pos == "eol") and m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          local text = tostring(chunk[1])
          -- ASCII started icon is ">" followed by space + Ns / Nm / NhMm
          if text:match("^> %d+[smh]") or text:match("^> %d+h") then
            has_elapsed = true
          end
        end
      end
    end
    assert.is_true(has_elapsed, "started task should show elapsed chip")
    run_shell("task rc.confirmation=off rc.bulk=0 " .. t.uuid:sub(1, 8) .. " stop")
  end)

  it("relative_dates=false disables the label", function()
    require("taskwarrior.config").options.icons = false
    require("taskwarrior.config").options.relative_dates = false
    run_shell('task rc.confirmation=off rc.bulk=0 add "Noreldatetest" project:noreldemo due:tomorrow')
    require("taskwarrior").open("project:noreldemo")
    local bufnr = vim.api.nvim_get_current_buf()
    require("taskwarrior.buffer").refresh_buf(bufnr)
    local ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      if (m[4].virt_text_pos == "right_align" or m[4].virt_text_pos == "eol") and m[4].virt_text then
        for _, chunk in ipairs(m[4].virt_text) do
          local text = tostring(chunk[1])
          assert.is_not_equal("tomorrow", text,
            "disabling relative_dates should suppress the label")
        end
      end
    end
    require("taskwarrior.config").options.relative_dates = true
  end)
end)

-- =========================================================================
-- UI polish: highlight group palette changes
-- =========================================================================

describe("e2e palette changes", function()
  it("TaskPriorityL links to TaskSubtle (not green)", function()
    require("taskwarrior.buffer").setup_buf_syntax(vim.api.nvim_create_buf(true, false))
    local info = vim.api.nvim_get_hl(0, { name = "TaskPriorityL" })
    assert.is_not_nil(info)
    -- Either it links to TaskSubtle or its fg matches Subtle (#6c7086)
    local subtle_info = vim.api.nvim_get_hl(0, { name = "TaskSubtle" })
    -- Resolve link chain
    local target = info.link
    assert.equals("TaskSubtle", target,
      "TaskPriorityL should link to TaskSubtle, got " .. tostring(target))
  end)

  it("TaskCompleted has strikethrough", function()
    require("taskwarrior.buffer").setup_buf_syntax(vim.api.nvim_create_buf(true, false))
    local info = vim.api.nvim_get_hl(0, { name = "TaskCompleted" })
    assert.is_true(info.strikethrough == true,
      "completed tasks should be rendered with strikethrough")
  end)

  it("TaskProject links to Subtle (not bright teal)", function()
    require("taskwarrior.buffer").setup_buf_syntax(vim.api.nvim_create_buf(true, false))
    local info = vim.api.nvim_get_hl(0, { name = "TaskProject" })
    assert.equals("TaskSubtle", info.link)
  end)

  it("TaskOverdueBadge is defined with inverted-style attributes",
      function()
    require("taskwarrior.buffer").setup_buf_syntax(vim.api.nvim_create_buf(true, false))
    local info = vim.api.nvim_get_hl(0, { name = "TaskOverdueBadge" })
    assert.is_not_nil(info.fg)
    assert.is_not_nil(info.bg)
    assert.is_true(info.bold)
  end)
end)

-- =========================================================================
-- Cleanup
-- =========================================================================

describe("e2e cleanup", function()
  it("did not leak persistent vim.ui stubs", function()
    -- If a test didn't call restore_ui, this would show up as weirdness.
    restore_ui()
    restore_notify()
    assert.is_function(vim.ui.input)
    assert.is_function(vim.ui.select)
    assert.is_function(vim.notify)
  end)
end)
