-- diff_spec.lua — tests for M.compute_diff.
--
-- All tests are HERMETIC: we never call vim.fn.system / task. We only
-- test compute_diff() which is a pure-Lua function operating on tables.
--
-- Covers:
--   • Unchanged buffer → zero actions
--   • Reordered tasks → zero actions
--   • Adding a task → add action
--   • Adding a started task → add with _post_start=true
--   • Adding a completed task → add with _post_done=true
--   • Removing a task → done action (default on_delete)
--   • Removing a task with on_delete="delete" → delete action
--   • Completing a task → done action
--   • Uncompleting a task → modify with status=pending
--   • Modifying description → modify action
--   • Modifying priority → modify action
--   • Modifying project → modify action
--   • Adding a tag → modify with tags
--   • Removing a tag → modify with _removed_tags
--   • Removing a field (clear) → modify with field=""
--   • Date same-day (time component differs) → no modify
--   • Date actually changed → modify with new date
--   • Duplicate UUID → second treated as add
--   • Mixed scenario (add + complete + modify)
--   • start/stop transitions

local M = require("task.taskmd")

local function make_uuid(prefix)
  -- Pad a short 8-char prefix into a full UUID
  return prefix .. "-1234-5678-9abc-def012345678"
end

local UUID1 = make_uuid("ab05fb51")
local UUID2 = make_uuid("cd12ef34")

local BASE_TASKS = {
  {
    uuid        = UUID1,
    description = "Buy groceries",
    status      = "pending",
    project     = "Inbox",
  },
  {
    uuid        = UUID2,
    description = "Fix bug",
    status      = "pending",
    project     = "Work",
    priority    = "H",
  },
}

-- Helper: parse a line, asserting it succeeds
local function P(line, extra_fields)
  local t = M.parse_task_line(line, extra_fields)
  assert(t ~= nil, "Failed to parse: " .. tostring(line))
  return t
end

-- Shorthand
local function diff(lines, base, opts)
  return M.compute_diff(lines, base or BASE_TASKS, opts or {})
end

-- ── zero-change scenarios ────────────────────────────────────────────────────

describe("compute_diff — zero changes", function()

  it("returns empty list when buffer matches base exactly", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    assert.same({}, actions)
  end)

  it("returns empty list when tasks are reordered", function()
    local lines = {
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
    }
    local actions = diff(lines)
    assert.same({}, actions)
  end)

  it("returns empty list when date has different time component but same day", function()
    local base = {
      {
        uuid        = UUID1,
        description = "Buy groceries",
        status      = "pending",
        project     = "Inbox",
        due         = "20260322T134834Z",  -- has time component
      },
      BASE_TASKS[2],
    }
    local lines = {
      P("- [ ] Buy groceries project:Inbox due:2026-03-22 <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines, base)
    assert.same({}, actions)
  end)

end)

-- ── add actions ──────────────────────────────────────────────────────────────

describe("compute_diff — add", function()

  it("produces add action for a line without UUID", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
      P("- [ ] Brand new task project:Personal"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("add", actions[1].type)
    assert.equals("Brand new task", actions[1].description)
    assert.equals("Personal", actions[1].fields.project)
  end)

  it("add action does not have _post_start or _post_done for plain pending task", function()
    local lines = { P("- [ ] New task") }
    local actions = diff(lines, {})
    assert.equals(1, #actions)
    assert.equals("add", actions[1].type)
    assert.is_not_true(actions[1]._post_start)
    assert.is_not_true(actions[1]._post_done)
  end)

  it("sets _post_start=true for a started new task", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
      P("- [>] New active task"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("add", actions[1].type)
    assert.is_true(actions[1]._post_start)
  end)

  it("sets _post_done=true for an already-completed new task", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
      P("- [x] Already done task"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("add", actions[1].type)
    assert.is_true(actions[1]._post_done)
  end)

end)

-- ── done / delete on removal ─────────────────────────────────────────────────

describe("compute_diff — removal", function()

  it("emits done action for missing task (default on_delete='done')", function()
    local lines = {
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("done", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
  end)

  it("emits delete action when on_delete='delete'", function()
    local lines = {
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines, nil, { on_delete = "delete" })
    assert.equals(1, #actions)
    assert.equals("delete", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
  end)

end)

-- ── completion ───────────────────────────────────────────────────────────────

describe("compute_diff — completion", function()

  it("emits done action when [x] checkbox set on pending task", function()
    local lines = {
      P("- [x] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("done", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
  end)

  it("emits modify(status=pending) when completed task is unchecked", function()
    local base = {
      {
        uuid        = UUID1,
        description = "Buy groceries",
        status      = "completed",
        project     = "Inbox",
      },
    }
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
    }
    local actions = diff(lines, base)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
    assert.equals("pending", actions[1].fields.status)
  end)

end)

-- ── start / stop transitions ─────────────────────────────────────────────────

describe("compute_diff — start/stop", function()

  it("emits start action when [>] set on pending task", function()
    local lines = {
      P("- [>] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    -- should be a start action for UUID1
    local starts = {}
    for _, a in ipairs(actions) do
      if a.type == "start" then starts[#starts + 1] = a end
    end
    assert.equals(1, #starts)
    assert.equals(UUID1, starts[1].uuid)
  end)

  it("emits stop action when started task reverts to [ ]", function()
    local base = {
      {
        uuid        = UUID1,
        description = "Buy groceries",
        status      = "pending",
        project     = "Inbox",
        start       = "20260101T000000Z",
      },
      BASE_TASKS[2],
    }
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines, base)
    local stops = {}
    for _, a in ipairs(actions) do
      if a.type == "stop" then stops[#stops + 1] = a end
    end
    assert.equals(1, #stops)
    assert.equals(UUID1, stops[1].uuid)
  end)

  it("emits stop before done when a started task is completed", function()
    local base = {
      {
        uuid        = UUID1,
        description = "Buy groceries",
        status      = "pending",
        project     = "Inbox",
        start       = "20260101T000000Z",
      },
    }
    local lines = {
      P("- [x] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
    }
    local actions = diff(lines, base)
    -- Expect a stop action AND a done action for the same UUID
    local types = {}
    for _, a in ipairs(actions) do types[#types + 1] = a.type end
    local has_stop = vim.tbl_contains(types, "stop")
    local has_done = vim.tbl_contains(types, "done")
    assert.is_true(has_stop, "expected stop action")
    assert.is_true(has_done, "expected done action")
    -- stop must come before done
    local stop_idx, done_idx
    for i, a in ipairs(actions) do
      if a.type == "stop" and a.uuid == UUID1 then stop_idx = i end
      if a.type == "done" and a.uuid == UUID1 then done_idx = i end
    end
    assert.is_true(stop_idx < done_idx, "stop must precede done")
  end)

end)

-- ── modify ───────────────────────────────────────────────────────────────────

describe("compute_diff — modify", function()

  it("emits modify action when description changes", function()
    local lines = {
      P("- [ ] Buy MORE groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
    assert.equals("Buy MORE groceries", actions[1].fields.description)
  end)

  it("emits modify action when priority changes", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:L <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals(UUID2, actions[1].uuid)
    assert.equals("L", actions[1].fields.priority)
  end)

  it("emits modify action when project changes", function()
    local lines = {
      P("- [ ] Buy groceries project:Home <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
    assert.equals("Home", actions[1].fields.project)
  end)

  it("emits modify with field='' when a field is removed", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work <!-- uuid:cd12ef34 -->"),   -- priority:H removed
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals(UUID2, actions[1].uuid)
    assert.equals("", actions[1].fields.priority)
  end)

  it("emits modify when date actually changes", function()
    local base = {
      {
        uuid        = UUID1,
        description = "Buy groceries",
        status      = "pending",
        project     = "Inbox",
        due         = "20260322T134834Z",
      },
      BASE_TASKS[2],
    }
    local lines = {
      P("- [ ] Buy groceries project:Inbox due:2026-03-25 <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines, base)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals("20260325T000000Z", actions[1].fields.due)
  end)

  it("emits modify with tags when a tag is added", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox +urgent <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
    assert.truthy(vim.tbl_contains(actions[1].fields.tags, "urgent"))
  end)

  it("emits modify with _removed_tags when a tag is removed", function()
    local base = {
      {
        uuid        = UUID1,
        description = "Buy groceries",
        status      = "pending",
        project     = "Inbox",
        tags        = { "urgent" },
      },
      BASE_TASKS[2],
    }
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines, base)
    assert.equals(1, #actions)
    assert.equals("modify", actions[1].type)
    assert.equals(UUID1, actions[1].uuid)
    assert.same({}, actions[1].fields.tags)
    assert.truthy(vim.tbl_contains(actions[1].fields._removed_tags, "urgent"))
  end)

end)

-- ── duplicate UUID ───────────────────────────────────────────────────────────

describe("compute_diff — duplicate UUID", function()

  it("treats the second occurrence of a UUID as an add", function()
    local lines = {
      P("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Duplicate line project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
    }
    local actions = diff(lines)
    local adds = {}
    for _, a in ipairs(actions) do
      if a.type == "add" then adds[#adds + 1] = a end
    end
    assert.equals(1, #adds)
    assert.equals("Duplicate line", adds[1].description)
  end)

end)

-- ── mixed scenario ───────────────────────────────────────────────────────────

describe("compute_diff — mixed scenario", function()

  it("handles add + complete + modify simultaneously", function()
    local lines = {
      P("- [ ] Buy ALL the groceries project:Inbox <!-- uuid:ab05fb51 -->"),
      P("- [x] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
      P("- [ ] Write tests project:Dev"),
    }
    local actions = diff(lines)

    local types = {}
    for _, a in ipairs(actions) do types[a.type] = (types[a.type] or 0) + 1 end

    assert.truthy(types["modify"], "expected modify action")
    assert.truthy(types["done"],   "expected done action")
    assert.truthy(types["add"],    "expected add action")

    -- Verify the modify targets UUID1 (description changed)
    local modify_found = false
    for _, a in ipairs(actions) do
      if a.type == "modify" and a.uuid == UUID1 then
        modify_found = true
        assert.equals("Buy ALL the groceries", a.fields.description)
      end
    end
    assert.is_true(modify_found, "modify for UUID1 not found")
  end)

end)
