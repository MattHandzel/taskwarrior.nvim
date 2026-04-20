-- render_spec.lua — tests for M.serialize_task_line (markdown rendering).
--
-- Covers:
--   • Status checkbox: [ ] / [x] / [>]
--   • Canonical field order
--   • UUID comment appended at the end
--   • tags rendered after known fields, sorted
--   • omit_group_field option
--   • fields_filter option
--   • extra_fields (UDA) rendered
--   • Date fields rendered as human-readable YYYY-MM-DD
--   • Effort field rendered as human-readable (1h30m)
--   • nil/non-string description handled safely
--   • Newlines in description are collapsed to spaces

local M = require("taskwarrior.taskmd")

describe("serialize_task_line", function()

  -- ── status checkboxes ───────────────────────────────────────────────────

  describe("status checkboxes", function()
    it("renders pending task with [ ] checkbox", function()
      local line = M.serialize_task_line({ status = "pending", description = "Buy milk" })
      assert.equals("- [ ] Buy milk", line)
    end)

    it("renders completed task with [x] checkbox", function()
      local line = M.serialize_task_line({ status = "completed", description = "Done" })
      assert.equals("- [x] Done", line)
    end)

    it("renders started task with [>] checkbox when task.start is truthy", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Active",
        start = "20260101T000000Z",
      })
      assert.equals("- [>] Active", line)
    end)

    it("pending without start is [ ] even if started field absent", function()
      local line = M.serialize_task_line({ status = "pending", description = "Task" })
      assert.truthy(line:match("^%- %[ %]"))
    end)
  end)

  -- ── field order ─────────────────────────────────────────────────────────

  describe("canonical field order", function()
    it("emits project before priority before due before scheduled before effort", function()
      local task = {
        status = "pending",
        description = "Ordered task",
        tags = { "z", "a" },
        priority = "M",
        due = "20260501T000000Z",
        project = "Test",
        scheduled = "20260415T000000Z",
        effort = "PT1H",
      }
      local line = M.serialize_task_line(task)
      local pos_project   = line:find("project:")
      local pos_priority  = line:find("priority:")
      local pos_due       = line:find("due:")
      local pos_scheduled = line:find("scheduled:")
      local pos_effort    = line:find("effort:")
      local pos_tag_a     = line:find("%+a")
      local pos_tag_z     = line:find("%+z")

      assert.truthy(pos_project,   "project missing")
      assert.truthy(pos_priority,  "priority missing")
      assert.truthy(pos_due,       "due missing")
      assert.truthy(pos_scheduled, "scheduled missing")
      assert.truthy(pos_effort,    "effort missing")
      assert.truthy(pos_tag_a,     "+a missing")
      assert.truthy(pos_tag_z,     "+z missing")

      assert.is_true(pos_project   < pos_priority,  "project must precede priority")
      assert.is_true(pos_priority  < pos_due,        "priority must precede due")
      assert.is_true(pos_due       < pos_scheduled,  "due must precede scheduled")
      assert.is_true(pos_scheduled < pos_effort,     "scheduled must precede effort")
      assert.is_true(pos_effort    < pos_tag_a,      "effort must precede tags")
      assert.is_true(pos_tag_a     < pos_tag_z,      "tags must be sorted (a before z)")
    end)
  end)

  -- ── UUID comment ────────────────────────────────────────────────────────

  describe("UUID comment", function()
    it("appends <!-- uuid:XXXXXXXX --> using first 8 chars of uuid", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "UUID task",
        uuid = "ab05fb51-1234-5678-9abc-def012345678",
      })
      assert.truthy(line:find("<!%-%- uuid:ab05fb51 %-%->"))
    end)

    it("UUID comment is the last token on the line", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "UUID task",
        uuid = "ab05fb51-1234-5678-9abc-def012345678",
        project = "Work",
      })
      assert.truthy(line:match("<!%-%- uuid:ab05fb51 %-%->$"))
    end)

    it("omits UUID comment when uuid is nil", function()
      local line = M.serialize_task_line({ status = "pending", description = "Task no id" })
      -- The <!-- uuid:... --> comment must not appear
      assert.is_nil(line:find("<!%-%-"), "HTML comment should not appear without uuid")
    end)

    it("omits UUID comment when uuid is empty string", function()
      local line = M.serialize_task_line({ status = "pending", description = "Task no id", uuid = "" })
      assert.is_nil(line:find("<!%-%-"), "HTML comment should not appear for empty uuid")
    end)
  end)

  -- ── date fields ─────────────────────────────────────────────────────────

  describe("date field rendering", function()
    it("renders due date as YYYY-MM-DD", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Task",
        due = "20260401T000000Z",
      })
      assert.truthy(line:find("due:2026%-04%-01"), "expected 'due:2026-04-01' in: " .. line)
    end)

    it("renders scheduled date as YYYY-MM-DD", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Task",
        scheduled = "20260325T000000Z",
      })
      assert.truthy(line:find("scheduled:2026%-03%-25"))
    end)
  end)

  -- ── effort rendering ─────────────────────────────────────────────────────

  describe("effort field rendering", function()
    it("renders PT1H30M as 1h30m", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Task",
        effort = "PT1H30M",
      })
      assert.truthy(line:find("effort:1h30m"), "expected 'effort:1h30m' in: " .. line)
    end)

    it("renders PT30M as 30m", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Task",
        effort = "PT30M",
      })
      assert.truthy(line:find("effort:30m"))
    end)
  end)

  -- ── tags ─────────────────────────────────────────────────────────────────

  describe("tags rendering", function()
    it("sorts tags alphabetically", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Task",
        tags = { "zebra", "apple", "mango" },
      })
      local pa = line:find("%+apple")
      local pm = line:find("%+mango")
      local pz = line:find("%+zebra")
      assert.is_true(pa < pm and pm < pz, "tags should be sorted alphabetically")
    end)

    it("does not render tags field when tags table is empty", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Task",
        tags = {},
      })
      assert.is_nil(line:find("%+"))
    end)
  end)

  -- ── omit_group_field ─────────────────────────────────────────────────────

  describe("omit_group_field option", function()
    it("omits the specified field from rendered output", function()
      local line = M.serialize_task_line(
        { status = "pending", description = "Task", project = "Work", priority = "H" },
        { omit_group_field = "project" }
      )
      assert.is_nil(line:find("project:"))
      assert.truthy(line:find("priority:H"))
    end)
  end)

  -- ── fields_filter option ─────────────────────────────────────────────────

  describe("fields_filter option", function()
    it("only emits listed fields", function()
      local line = M.serialize_task_line(
        { status = "pending", description = "Task", project = "Work", priority = "H", due = "20260401T000000Z" },
        { fields_filter = { "project" } }
      )
      assert.truthy(line:find("project:Work"))
      assert.is_nil(line:find("priority:"))
      assert.is_nil(line:find("due:"))
    end)
  end)

  -- ── description edge cases ─────────────────────────────────────────────

  describe("description edge cases", function()
    it("handles nil description without error", function()
      local ok, result = pcall(M.serialize_task_line, { status = "pending", description = nil })
      assert.is_true(ok)
      assert.truthy(result)
    end)

    it("collapses embedded newlines in description to spaces", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Line one\nLine two",
      })
      assert.is_nil(line:find("\n"), "newline should be collapsed")
      assert.truthy(line:find("Line one Line two"))
    end)

    it("strips embedded carriage returns from description", function()
      local line = M.serialize_task_line({
        status = "pending",
        description = "Line one\rLine two",
      })
      assert.is_nil(line:find("\r"), "CR should be stripped")
    end)
  end)

  -- ── extra_fields (UDA) ──────────────────────────────────────────────────

  describe("extra_fields (UDA)", function()
    it("renders a UDA field when listed in extra_fields", function()
      local line = M.serialize_task_line(
        { status = "pending", description = "Task", utility = "5" },
        { extra_fields = { "utility" } }
      )
      assert.truthy(line:find("utility:5"), "UDA field should appear in rendered line")
    end)

    it("does not render UDA field when not in extra_fields", function()
      local line = M.serialize_task_line(
        { status = "pending", description = "Task", utility = "5" }
      )
      assert.is_nil(line:find("utility:"))
    end)
  end)

  -- ── priority H/M/L rendering ─────────────────────────────────────────────

  describe("priority H/M/L rendering", function()
    for _, prio in ipairs({ "H", "M", "L" }) do
      it("renders priority:" .. prio .. " correctly", function()
        local line = M.serialize_task_line({
          status = "pending",
          description = "Task",
          priority = prio,
        })
        assert.truthy(line:find("priority:" .. prio))
      end)
    end
  end)

end)
