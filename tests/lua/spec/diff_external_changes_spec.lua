-- diff_external_changes_spec.lua — pure-Lua tests for compute_diff's
-- external-change detection. No shell / no real Taskwarrior.
--
-- Regression shield for the class of bugs where external Taskwarrior
-- mutations (CLI `task add`, mobile sync, another editor) were silently
-- overwritten or duplicated when the plugin saved a buffer rendered
-- before those mutations.
--
-- Covers the five compute_diff rules:
--   1. External modify + local modify on SAME task  → conflict, no action
--   2. UUID in buffer not in base (external delete)  → conflict, no add
--   3. Base-only task with modified > rendered_at   → conflict, no done/delete
--   4. Base-only task with modified <= rendered_at  → real delete/done
--   5. UUID in buffer AND base, no local change, external modify → no-op
-- Plus: force=true restores legacy destructive behaviour.

local M = require("taskwarrior.taskmd")

local function make_uuid(prefix)
  return prefix .. "-1234-5678-9abc-def012345678"
end

local UUID1 = make_uuid("aa11bb22")
local UUID2 = make_uuid("cc33dd44")
local UUID_GHOST = make_uuid("99887766")

-- rendered_at in the past, mod timestamps either side of it.
local RENDERED_AT = "2026-04-21T10:00:00"
local BEFORE_RA   = "20260421T095000Z"  -- 10 minutes before RA
local AFTER_RA    = "20260421T101500Z"  -- 15 minutes after RA

local function P(line)
  local t = M.parse_task_line(line)
  assert(t ~= nil, "Failed to parse: " .. tostring(line))
  return t
end

describe("compute_diff — external-change rules", function()

  it("rule 1: both-sides modified surfaces a conflict and skips the modify", function()
    local base = {
      {
        uuid = UUID1,
        description = "Shared task",
        status = "pending",
        project = "work",
        modified = AFTER_RA, -- externally touched AFTER we rendered
      },
    }
    -- Buffer has a locally modified priority (user wasn't aware external happened).
    local lines = {
      P("- [ ] Shared task project:work priority:H <!-- uuid:aa11bb22 -->"),
    }

    local actions, conflicts = M.compute_diff(lines, base, {
      rendered_at = RENDERED_AT,
    })

    assert.are.equal(0, #actions, "no modify should be emitted when base was externally touched")
    assert.are.equal(1, #conflicts)
    assert.are.equal("external_modify", conflicts[1].type)
    assert.are.equal(UUID1, conflicts[1].uuid)
    assert.are.equal("Shared task", conflicts[1].description)
    assert.is_not_nil(conflicts[1].would_have, "conflict carries the skipped actions for UI surfacing")
  end)

  it("rule 2: buffer UUID not in base → external_delete conflict, NOT a new-add", function()
    local base = {
      {
        uuid = UUID1,
        description = "Still here",
        status = "pending",
        modified = BEFORE_RA,
      },
    }
    -- Buffer still references a task whose UUID is no longer in the filter
    -- (externally completed / deleted / project-moved).
    local lines = {
      P("- [ ] Still here <!-- uuid:aa11bb22 -->"),
      P("- [ ] Ghost that was externally removed <!-- uuid:99887766 -->"),
    }

    local actions, conflicts = M.compute_diff(lines, base, {
      rendered_at = RENDERED_AT,
    })

    -- No action should attempt to re-create the ghost.
    for _, a in ipairs(actions) do
      assert.are_not.equal("add", a.type,
        "external_delete must NOT be duplicated as a new add")
    end
    local ghost_conflicts = 0
    for _, c in ipairs(conflicts) do
      if c.type == "external_delete" then ghost_conflicts = ghost_conflicts + 1 end
    end
    assert.are.equal(1, ghost_conflicts)
    assert.are.equal("99887766", conflicts[#conflicts].short_uuid)
  end)

  it("rule 3: base task not in buffer, modified after render → external_add conflict, NOT done/delete", function()
    local base = {
      {
        uuid = UUID1,
        description = "Task from buffer",
        status = "pending",
        modified = BEFORE_RA,
      },
      {
        uuid = UUID2,
        description = "Externally added",
        status = "pending",
        modified = AFTER_RA, -- added AFTER render
      },
    }
    -- Buffer only has UUID1.
    local lines = {
      P("- [ ] Task from buffer <!-- uuid:aa11bb22 -->"),
    }

    local actions, conflicts = M.compute_diff(lines, base, {
      rendered_at = RENDERED_AT,
      on_delete = "done",
    })

    for _, a in ipairs(actions) do
      assert.is_true(a.type ~= "done" and a.type ~= "delete",
        "externally-added task must NOT be clobbered by done/delete, got: " .. a.type)
    end
    local add_conflicts = 0
    for _, c in ipairs(conflicts) do
      if c.type == "external_add" and c.uuid == UUID2 then
        add_conflicts = add_conflicts + 1
      end
    end
    assert.are.equal(1, add_conflicts)
  end)

  it("rule 4: base task not in buffer, modified BEFORE render → real done action", function()
    local base = {
      {
        uuid = UUID1,
        description = "Deleted by user in buffer",
        status = "pending",
        modified = BEFORE_RA,
      },
    }
    local lines = {} -- user removed the line

    local actions, conflicts = M.compute_diff(lines, base, {
      rendered_at = RENDERED_AT,
      on_delete = "done",
    })

    assert.are.equal(1, #actions)
    assert.are.equal("done", actions[1].type)
    assert.are.equal(UUID1, actions[1].uuid)
    assert.are.equal(0, #conflicts)
  end)

  it("rule 5: externally modified task identical in buffer → no-op, no conflict", function()
    -- The user hasn't edited this task; buffer was rendered before the external
    -- change but its content matches what a re-render would produce now. We
    -- must not surface a conflict for something the user isn't touching.
    local base = {
      {
        uuid = UUID1,
        description = "Synced",
        status = "pending",
        modified = AFTER_RA, -- external touched it, but buffer still matches
      },
    }
    local lines = {
      P("- [ ] Synced <!-- uuid:aa11bb22 -->"),
    }

    local actions, conflicts = M.compute_diff(lines, base, {
      rendered_at = RENDERED_AT,
    })

    assert.are.equal(0, #actions)
    assert.are.equal(0, #conflicts,
      "no conflict when buffer didn't locally modify an externally-touched task")
  end)

  it("force=true restores legacy destructive behaviour (rules bypassed)", function()
    local base = {
      {
        uuid = UUID2,
        description = "Externally added",
        status = "pending",
        modified = AFTER_RA,
      },
    }
    local lines = {
      P("- [ ] Ghost that TW no longer has <!-- uuid:99887766 -->"),
    }

    local actions, conflicts = M.compute_diff(lines, base, {
      rendered_at = RENDERED_AT,
      force = true,
      on_delete = "done",
    })

    -- Legacy: ghost UUID becomes a new add, base's external-add becomes a done.
    local got_add, got_done = false, false
    for _, a in ipairs(actions) do
      if a.type == "add" then got_add = true end
      if a.type == "done" and a.uuid == UUID2 then got_done = true end
    end
    assert.is_true(got_add, "force mode treats unknown UUID line as new add")
    assert.is_true(got_done, "force mode marks externally-added task done")
    assert.are.equal(0, #conflicts, "force mode suppresses conflict reporting")
  end)

  it("no rendered_at → external_modify/external_add disabled, but external_delete still guards", function()
    -- external_delete (UUID in buffer, not in base) signals a deleted/moved
    -- task regardless of rendered_at, so we keep that protection always-on.
    -- The other two rules need rendered_at to disambiguate external vs local.
    local base = {
      {
        uuid = UUID2,
        description = "Any task",
        status = "pending",
        modified = AFTER_RA,
      },
    }
    local lines = {
      P("- [ ] Missing-UUID ghost <!-- uuid:99887766 -->"),
    }

    local actions, conflicts = M.compute_diff(lines, base, { on_delete = "done" })

    -- base→done still happens (no rendered_at means external_add check is off)
    local saw_done = false
    for _, a in ipairs(actions) do
      if a.type == "done" and a.uuid == UUID2 then saw_done = true end
    end
    assert.is_true(saw_done, "without rendered_at, base task absent from buffer is still marked done")

    -- But the ghost UUID is NEVER turned into an add — that would duplicate a
    -- deleted task. This protection is correct even without rendered_at.
    for _, a in ipairs(actions) do
      assert.are_not.equal("add", a.type)
    end

    local ghost = 0
    for _, c in ipairs(conflicts) do
      if c.type == "external_delete" then ghost = ghost + 1 end
    end
    assert.are.equal(1, ghost)
  end)

  it("both local and external add-path coexist safely (no false positives)", function()
    local base = {
      {
        uuid = UUID1,
        description = "Old task",
        status = "pending",
        modified = BEFORE_RA,
      },
    }
    -- Buffer has UUID1 unchanged plus a brand-new task (no UUID comment).
    local lines = {
      P("- [ ] Old task <!-- uuid:aa11bb22 -->"),
      P("- [ ] Brand new local task project:home"),
    }

    local actions, conflicts = M.compute_diff(lines, base, {
      rendered_at = RENDERED_AT,
    })

    assert.are.equal(1, #actions)
    assert.are.equal("add", actions[1].type)
    assert.are.equal("Brand new local task", actions[1].description)
    assert.are.equal(0, #conflicts)
  end)

  it("backward-compat: legacy single-return call site still receives actions", function()
    -- `local actions = M.compute_diff(...)` (ignoring the second return) must
    -- keep working — Lua discards unbound multi-returns, but assert the shape
    -- explicitly so we never accidentally wrap the return in a table.
    local actions = M.compute_diff({}, { { uuid = UUID1, description = "x", status = "pending", modified = BEFORE_RA } }, {
      on_delete = "done",
    })
    assert.is_table(actions)
    assert.are.equal(1, #actions)
    assert.are.equal("done", actions[1].type)
  end)

end)
