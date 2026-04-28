-- external_changes_spec.lua — end-to-end regression shield for the class of
-- bugs where Taskwarrior mutations performed OUTSIDE the plugin (CLI
-- `task add`, sync, another editor) were silently clobbered by the plugin
-- when it later saved a stale buffer.
--
-- Drives the real `task` CLI (via the isolated TASKDATA that
-- tests/e2e/run.sh seeds), renders a buffer through the plugin, applies
-- an external mutation, then triggers the save path and asserts the
-- external state survived.
--
-- All scenarios must fail CLOSED: the plugin must either refuse the write
-- (non-confirm mode, no bang) or apply only non-conflicting changes
-- (with the bang / Apply-force branch). The test matrix:
--   A. External add  → plugin must NOT mark it done/delete on save
--   B. External tag-add → plugin must NOT remove the tag on save
--   C. Task completed externally + buffer keeps the UUID line → no duplicate
--   D. Both sides modified same task → conflict surfaced, no silent overwrite
--   E. Force (via apply force=true) DOES overwrite — escape hatch preserved
--   F. No external change → ordinary save works (control)

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")

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

-- Each test owns its own tag so scenarios don't pollute each other's filters.
local function unique_tag(prefix)
  return string.format("%s_%d_%d", prefix, vim.fn.getpid(), math.random(1, 1e9))
end

-- Render a markdown view for a specific tag filter. Returns (path, content).
--
-- Taskwarrior timestamps have 1-second resolution, so tests that want a
-- post-render external mutation to register as externally-touched must
-- `sleep_for_tw_tick()` before mutating. We do NOT rewind rendered_at,
-- because that would retroactively make the seed task look externally
-- modified too (its modified timestamp would be after the rewound
-- rendered_at).
local function render_to_tmpfile(filter_args)
  local content = taskmd.render({
    filter_args = filter_args,
    sort_spec = "urgency-",
  })
  assert(type(content) == "string" and #content > 0, "render returned empty")

  local path = vim.fn.tempname()
  local f = assert(io.open(path, "w"))
  f:write(content); f:close()
  return path, content
end

-- Wait just over one Taskwarrior tick so the next mutation's `modified`
-- timestamp is strictly greater than the rendered_at captured moments ago.
local function sleep_for_tw_tick()
  vim.fn.system("sleep 1.2")
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local s = f:read("*a"); f:close(); return s
end

local function task_uuids_with_tag(tag)
  local tasks = task_export("+" .. tag)
  local uuids = {}
  for _, t in ipairs(tasks) do table.insert(uuids, t.uuid) end
  return uuids
end

-- Plugin bootstrap (same pattern as e2e_spec.lua).
require("taskwarrior").setup({})

describe("e2e — external changes survive buffer saves", function()

  it("A. externally-added task is NOT marked done when the stale buffer saves", function()
    local tag = unique_tag("extA")
    local _, ok1 = run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'A existing' +%s", tag))
    assert(ok1, "seed add failed")

    local tmpfile = render_to_tmpfile({ "+" .. tag })
    sleep_for_tw_tick()

    -- External add AFTER render.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'A externally added' +%s", tag))

    -- Save the stale buffer (non-force).
    local summary = taskmd.apply({ file = tmpfile, on_delete = "done" })

    local remaining = task_uuids_with_tag(tag)
    assert.are.equal(2, #remaining,
      "externally-added task was clobbered; remaining pending=" .. #remaining)

    -- And a structured external_add conflict was surfaced.
    local saw = false
    for _, c in ipairs(summary.conflicts or {}) do
      if c.type == "external_add" and c.description == "A externally added" then
        saw = true
      end
    end
    assert.is_true(saw, "expected external_add conflict in summary.conflicts")
  end)

  it("B. tag added externally is NOT removed when the stale buffer saves", function()
    local tag = unique_tag("extB")
    local _, ok1 = run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'B tagged task' +%s", tag))
    assert(ok1)

    local tmpfile = render_to_tmpfile({ "+" .. tag })
    sleep_for_tw_tick()

    -- External: add an extra tag. The buffer has no awareness of it.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off +%s modify +external_%s", tag, tag))

    local summary = taskmd.apply({ file = tmpfile, on_delete = "done" })

    local tasks = task_export("+" .. tag)
    assert.are.equal(1, #tasks)
    local has_external = false
    for _, t in ipairs(tasks[1].tags or {}) do
      if t == "external_" .. tag then has_external = true end
    end
    assert.is_true(has_external,
      "external tag was stripped; remaining tags=" .. table.concat(tasks[1].tags or {}, ","))
  end)

  it("C. externally-completed task + buffer UUID line → no pending duplicate", function()
    local tag = unique_tag("extC")
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'C will be completed' +%s", tag))

    local tmpfile = render_to_tmpfile({ "+" .. tag })
    sleep_for_tw_tick()

    -- External: complete (done) the task. It leaves the pending filter.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off +%s done", tag))

    local summary = taskmd.apply({ file = tmpfile, on_delete = "done" })

    -- Pending count should be zero — we must NOT resurrect the task as a new
    -- pending "add" just because its UUID went missing from the filter.
    local pending = task_export("status:pending +" .. tag)
    assert.are.equal(0, #pending,
      "externally-completed task was duplicated as pending; count=" .. #pending)

    -- And the surviving record remains exactly one (the completed one).
    local all = task_export("+" .. tag)
    assert.are.equal(1, #all)
    assert.are.equal("completed", all[1].status)

    local saw = false
    for _, c in ipairs(summary.conflicts or {}) do
      if c.type == "external_delete" then saw = true end
    end
    assert.is_true(saw, "expected external_delete conflict")
  end)

  it("D. both-sides modified → conflict surfaced, buffer's change NOT auto-applied", function()
    local tag = unique_tag("extD")
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'D conflict task' +%s project:orig", tag))

    local _tmpfile, original = render_to_tmpfile({ "+" .. tag })
    -- Craft a buffer with a LOCAL project change.
    local modified_content = (original:gsub("project:orig", "project:local_edit"))
    local tmpfile = vim.fn.tempname()
    local f = assert(io.open(tmpfile, "w")); f:write(modified_content); f:close()

    sleep_for_tw_tick()

    -- External: also change the project differently.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off +%s modify project:external_edit", tag))

    local summary = taskmd.apply({ file = tmpfile, on_delete = "done" })

    local tasks = task_export("+" .. tag)
    assert.are.equal(1, #tasks)
    assert.are.equal("external_edit", tasks[1].project,
      "buffer silently overwrote external change; project=" .. tostring(tasks[1].project))

    local saw = false
    for _, c in ipairs(summary.conflicts or {}) do
      if c.type == "external_modify" then saw = true end
    end
    assert.is_true(saw, "expected external_modify conflict in summary")
  end)

  it("E. force=true preserves the escape hatch: buffer wins, external clobbered", function()
    local tag = unique_tag("extE")
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'E forced task' +%s project:orig", tag))

    local _tmpfile, original = render_to_tmpfile({ "+" .. tag })
    local modified_content = (original:gsub("project:orig", "project:forced_edit"))
    local tmpfile = vim.fn.tempname()
    local f = assert(io.open(tmpfile, "w")); f:write(modified_content); f:close()

    sleep_for_tw_tick()

    -- External change that would ordinarily conflict.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off +%s modify project:external_edit", tag))

    local summary = taskmd.apply({
      file = tmpfile, on_delete = "done", force = true,
    })

    local tasks = task_export("+" .. tag)
    assert.are.equal(1, #tasks)
    assert.are.equal("forced_edit", tasks[1].project,
      "force mode must apply buffer's edit regardless of external state")

    assert.are.equal(0, #(summary.conflicts or {}),
      "force mode must not surface conflicts")
  end)

  it("F. control: no external change → ordinary save applies buffer edits", function()
    local tag = unique_tag("extF")
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'F clean task' +%s project:orig", tag))

    local _tmpfile, original = render_to_tmpfile({ "+" .. tag })
    local modified_content = (original:gsub("project:orig", "project:updated"))
    local tmpfile = vim.fn.tempname()
    local f = assert(io.open(tmpfile, "w")); f:write(modified_content); f:close()

    -- NO external change.
    local summary = taskmd.apply({ file = tmpfile, on_delete = "done" })

    local tasks = task_export("+" .. tag)
    assert.are.equal(1, #tasks)
    assert.are.equal("updated", tasks[1].project)
    assert.are.equal(0, #(summary.conflicts or {}))
    assert.are.equal(1, summary.modified)
  end)

end)

describe("e2e — apply.on_write aborts non-force saves on conflict", function()
  -- Exercises the BufWriteCmd UI layer: non-confirm mode + no :w! must refuse
  -- the save (no actions applied, notify.ERROR emitted) when conflicts exist.

  local apply_mod = require("taskwarrior.apply")

  local function with_mocks(fn)
    local notify_log = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notify_log, { msg = msg, level = level })
    end
    local orig_cmdbang = vim.v.cmdbang
    -- vim.v.cmdbang is read-only at runtime; we simulate by directly calling
    -- on_write with force=false via the underlying helper. The on_write entry
    -- captures cmdbang at call time, so we can't easily override it — instead
    -- we drive the conflict path through taskmd.apply's dry-run return, which
    -- is what on_write's non-confirm branch actually inspects.
    local ok, err = pcall(fn, notify_log)
    vim.notify = orig_notify
    if not ok then error(err) end
    return notify_log
  end

  it("external_add alone is informational — does NOT block a non-confirm save", function()
    -- Regression: previously surfaced as a "conflict" requiring user action,
    -- which was wrong — there's no decision to make for an external add. The
    -- save should just proceed (the new task gets picked up on next refresh).
    local config = require("taskwarrior.config")
    local prev_confirm = config.options.confirm
    config.options.confirm = false

    local tag = unique_tag("addOnly")
    -- Seed one task that's also in the buffer.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'In buffer' +%s project:orig", tag))
    local _t, original = render_to_tmpfile({ "+" .. tag })

    -- User edits a benign field locally — generates one real action.
    local edited = (original:gsub("project:orig", "project:user_edit"))
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(edited, "\n"))

    sleep_for_tw_tick()

    -- External: add a NEW task (not modify the existing one). external_add only.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'Externally added new' +%s", tag))

    local refresh_calls = 0
    local refresh_fn = function() refresh_calls = refresh_calls + 1 end
    local apply_calls = 0
    local apply_mod = require("taskwarrior.apply")
    local do_apply_fn = function(_b, tmpfile, on_delete, opts)
      apply_calls = apply_calls + 1
      apply_mod.do_apply_and_refresh(_b, tmpfile, on_delete, refresh_fn, opts)
    end

    local notify_log = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notify_log, { msg = msg, level = level }) end
    local ok, err = pcall(function()
      apply_mod.on_write(bufnr, refresh_fn, do_apply_fn)
    end)
    vim.notify = orig_notify
    if not ok then error(err) end

    -- The save MUST have proceeded — external_add is informational only.
    assert.are.equal(1, apply_calls,
      "external_add alone must not block the save; got apply_calls=" .. apply_calls)

    -- And the user's edit was applied.
    local tasks = task_export("+" .. tag)
    assert.are.equal(2, #tasks, "both the buffer task and the externally-added task survive")
    local edited_task
    for _, t in ipairs(tasks) do
      if t.description == "In buffer" then edited_task = t end
    end
    assert.is_not_nil(edited_task)
    assert.are.equal("user_edit", edited_task.project)

    -- The informational note WAS surfaced (non-error level).
    local saw_info = false
    for _, entry in ipairs(notify_log) do
      if tostring(entry.msg):find("external change") and entry.level ~= vim.log.levels.ERROR then
        saw_info = true
      end
    end
    assert.is_true(saw_info, "expected non-error info notification listing the external add")

    config.options.confirm = prev_confirm
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("non-confirm save with conflicts is refused and no mutation occurs", function()
    local config = require("taskwarrior.config")
    local prev_confirm = config.options.confirm
    config.options.confirm = false

    local tag = unique_tag("onwriteG")
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off add 'G task' +%s project:orig", tag))

    local _t, original = render_to_tmpfile({ "+" .. tag })
    local edited = (original:gsub("project:orig", "project:user_edit"))

    -- Create a scratch buffer with the stale-but-edited content.
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(edited, "\n"))

    sleep_for_tw_tick()

    -- Externally change the SAME project — this creates a conflict.
    run_shell(string.format(
      "task rc.bulk=0 rc.confirmation=off +%s modify project:external_edit", tag))

    local refresh_calls = 0
    local refresh_fn = function() refresh_calls = refresh_calls + 1 end
    local apply_calls = 0
    local do_apply_fn = function(_b, tmpfile, on_delete, opts)
      apply_calls = apply_calls + 1
      apply_mod.do_apply_and_refresh(_b, tmpfile, on_delete, refresh_fn, opts)
    end

    local log = with_mocks(function(nlog)
      apply_mod.on_write(bufnr, refresh_fn, do_apply_fn)
    end)

    -- Refused: do_apply_fn must not have fired.
    assert.are.equal(0, apply_calls,
      "on_write must refuse to apply when conflicts detected (no-bang, no-confirm)")

    local task = task_export("+" .. tag)[1]
    assert.are.equal("external_edit", task.project,
      "external change must survive the refused save")

    local saw_error = false
    for _, entry in ipairs(log) do
      if entry.level == vim.log.levels.ERROR
         and tostring(entry.msg):find("refusing to save") then
        saw_error = true
      end
    end
    assert.is_true(saw_error, "expected error-level notification explaining refusal")

    config.options.confirm = prev_confirm
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)
