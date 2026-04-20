-- parse_spec.lua — tests for M.parse_task_line and related parser functions.
--
-- Covers:
--   • Simple pending / completed / started tasks
--   • Metadata fields (project, priority, due, scheduled, recur, wait, until, effort)
--   • Tags (+tag)
--   • UUID comment <!-- uuid:XXXXXXXX -->
--   • UDA (extra fields)
--   • Unicode descriptions
--   • Description with colons
--   • Lines that must NOT parse (non-task lines)
--   • Round-trip (parse → serialize → parse)
--   • Leading whitespace
--   • depends (LIST_FIELDS)
--   • Date normalisation (human → TW wire format)

local M = require("taskwarrior.taskmd")

describe("parse_task_line", function()

  -- ── basic cases ────────────────────────────────────────────────────────────

  describe("simple pending task", function()
    it("returns a table with status=pending and correct description", function()
      local t = M.parse_task_line("- [ ] Do thing")
      assert.is_not_nil(t)
      assert.equals("pending", t.status)
      assert.equals("Do thing", t.description)
    end)

    it("returns nil for a non-task line", function()
      assert.is_nil(M.parse_task_line("# Heading"))
      assert.is_nil(M.parse_task_line("## Group header"))
      assert.is_nil(M.parse_task_line("plain text"))
      assert.is_nil(M.parse_task_line(""))
      assert.is_nil(M.parse_task_line("[ ] no dash"))
      assert.is_nil(M.parse_task_line("- [] no space"))
    end)

    it("returns nil for non-string input", function()
      assert.is_nil(M.parse_task_line(nil))
      assert.is_nil(M.parse_task_line(42))
    end)
  end)

  describe("completed task", function()
    it("returns status=completed for [x] marker", function()
      local t = M.parse_task_line("- [x] Done thing")
      assert.is_not_nil(t)
      assert.equals("completed", t.status)
      assert.equals("Done thing", t.description)
    end)

    it("does NOT parse capital X as completed", function()
      -- Only lowercase x is a valid completed marker
      local t = M.parse_task_line("- [X] Capital X")
      assert.is_nil(t)
    end)
  end)

  describe("started task", function()
    it("sets _started=true for [>] marker", function()
      local t = M.parse_task_line("- [>] Working on this")
      assert.is_not_nil(t)
      assert.equals("pending", t.status)
      assert.is_true(t._started)
    end)
  end)

  -- ── metadata fields ────────────────────────────────────────────────────────

  describe("metadata fields", function()
    it("parses project field", function()
      local t = M.parse_task_line("- [ ] Buy milk project:Inbox")
      assert.is_not_nil(t)
      assert.equals("Buy milk", t.description)
      assert.equals("Inbox", t.project)
    end)

    it("parses priority field", function()
      local t = M.parse_task_line("- [ ] Urgent task priority:H")
      assert.is_not_nil(t)
      assert.equals("H", t.priority)
    end)

    it("parses due date and converts to TW wire format", function()
      local t = M.parse_task_line("- [ ] Task due:2026-04-01")
      assert.is_not_nil(t)
      assert.equals("20260401T000000Z", t.due)
    end)

    it("parses scheduled date", function()
      local t = M.parse_task_line("- [ ] Task scheduled:2026-03-25")
      assert.is_not_nil(t)
      assert.equals("20260325T000000Z", t.scheduled)
    end)

    it("parses recur (non-date string field)", function()
      local t = M.parse_task_line("- [ ] Task recur:weekly")
      assert.is_not_nil(t)
      assert.equals("weekly", t.recur)
    end)

    it("parses wait date", function()
      local t = M.parse_task_line("- [ ] Task wait:2026-04-01")
      assert.is_not_nil(t)
      assert.equals("20260401T000000Z", t.wait)
    end)

    it("parses until date", function()
      local t = M.parse_task_line("- [ ] Task until:2026-12-31")
      assert.is_not_nil(t)
      assert.equals("20261231T000000Z", t["until"])
    end)

    it("parses effort and converts to ISO 8601 duration", function()
      local t = M.parse_task_line("- [ ] Task effort:1h30m")
      assert.is_not_nil(t)
      -- parse_effort converts 1h30m → PT1H30M
      assert.equals("PT1H30M", t.effort)
    end)

    it("parses all fields together with correct description boundary", function()
      local line = "- [ ] Deploy service project:Work priority:H due:2026-04-01 scheduled:2026-03-25 +backend +devops <!-- uuid:ab05fb51 -->"
      local t = M.parse_task_line(line)
      assert.is_not_nil(t)
      assert.equals("Deploy service", t.description)
      assert.equals("Work", t.project)
      assert.equals("H", t.priority)
      assert.equals("20260401T000000Z", t.due)
      assert.equals("20260325T000000Z", t.scheduled)
      assert.equals("ab05fb51", t._short_uuid)
    end)
  end)

  -- ── tags ───────────────────────────────────────────────────────────────────

  describe("tags", function()
    it("parses a single tag", function()
      local t = M.parse_task_line("- [ ] Task +urgent")
      assert.is_not_nil(t)
      assert.is_not_nil(t.tags)
      assert.is_true(vim.tbl_contains(t.tags, "urgent"))
    end)

    it("parses multiple tags and sorts them", function()
      local t = M.parse_task_line("- [ ] Multi tag +zebra +apple +mango")
      assert.is_not_nil(t)
      assert.same({ "apple", "mango", "zebra" }, t.tags)
    end)

    it("deduplicates repeated tags", function()
      local t = M.parse_task_line("- [ ] Task +foo +foo +bar")
      assert.is_not_nil(t)
      local seen = {}
      for _, tag in ipairs(t.tags) do
        assert.is_nil(seen[tag], "duplicate tag: " .. tag)
        seen[tag] = true
      end
    end)
  end)

  -- ── UUID comment ───────────────────────────────────────────────────────────

  describe("UUID comment", function()
    it("extracts _short_uuid from <!-- uuid:XXXXXXXX --> comment", function()
      local t = M.parse_task_line("- [ ] Buy groceries <!-- uuid:ab05fb51 -->")
      assert.is_not_nil(t)
      assert.equals("ab05fb51", t._short_uuid)
    end)

    it("does not include UUID comment text in description", function()
      local t = M.parse_task_line("- [ ] Buy groceries <!-- uuid:ab05fb51 -->")
      assert.is_not_nil(t)
      assert.is_nil(t.description:find("uuid"), "uuid should not be in description")
      assert.is_nil(t.description:find("<!--"), "comment should not be in description")
    end)

    it("returns nil _short_uuid when no comment present", function()
      local t = M.parse_task_line("- [ ] No uuid here")
      assert.is_not_nil(t)
      assert.is_nil(t._short_uuid)
    end)
  end)

  -- ── UDA / extra fields ─────────────────────────────────────────────────────

  describe("UDA / extra_fields", function()
    it("parses a custom UDA field when passed in extra_fields", function()
      local t = M.parse_task_line("- [ ] Custom task utility:5", { "utility" })
      assert.is_not_nil(t)
      assert.equals("5", t.utility)
    end)

    it("treats unknown field tokens as part of description when not in extra_fields", function()
      -- 'utility' is not a known field, so it stays in the description
      local t = M.parse_task_line("- [ ] Custom task utility:5")
      assert.is_not_nil(t)
      assert.is_not_nil(t.description:find("utility:5"), "unknown field should remain in description")
    end)
  end)

  -- ── unicode ────────────────────────────────────────────────────────────────

  describe("unicode descriptions", function()
    it("parses CJK description", function()
      local t = M.parse_task_line("- [ ] 日本語のタスク")
      assert.is_not_nil(t)
      assert.equals("日本語のタスク", t.description)
    end)

    it("parses description with emoji", function()
      local t = M.parse_task_line("- [ ] Task with emoji \xf0\x9f\x8e\xaf")
      assert.is_not_nil(t)
      assert.is_not_nil(t.description)
    end)

    it("parses Arabic RTL text", function()
      local t = M.parse_task_line("- [ ] العربية RTL text")
      assert.is_not_nil(t)
      assert.equals("العربية RTL text", t.description)
    end)

    it("parses latin combining characters", function()
      local t = M.parse_task_line("- [ ] Héllo wörld")
      assert.is_not_nil(t)
      assert.equals("Héllo wörld", t.description)
    end)

    it("round-trips CJK description with a field", function()
      local t = M.parse_task_line("- [ ] 中文描述 project:Work")
      assert.is_not_nil(t)
      -- The project field must be parsed, stripping it from the description
      assert.equals("Work", t.project)
      assert.equals("中文描述", t.description)
    end)
  end)

  -- ── description with colons ─────────────────────────────────────────────

  describe("description with colons", function()
    it("keeps 'Word: rest' in description if it precedes known fields", function()
      local t = M.parse_task_line("- [ ] Note: do this thing project:Work")
      assert.is_not_nil(t)
      assert.equals("Note: do this thing", t.description)
      assert.equals("Work", t.project)
    end)
  end)

  -- ── leading whitespace ────────────────────────────────────────────────────

  describe("leading whitespace", function()
    it("strips leading spaces before the list marker", function()
      local t = M.parse_task_line("  - [ ] Indented task project:Work")
      assert.is_not_nil(t)
      assert.equals("Indented task", t.description)
      assert.equals("Work", t.project)
    end)
  end)

  -- ── depends (LIST_FIELDS) ─────────────────────────────────────────────────

  describe("depends field", function()
    it("parses comma-separated depends as sorted list", function()
      local t = M.parse_task_line("- [ ] Task depends:ab05fb51,cd12ef34")
      assert.is_not_nil(t)
      assert.is_not_nil(t.depends)
      assert.is_true(type(t.depends) == "table")
      -- Both IDs present
      local dep_set = {}
      for _, v in ipairs(t.depends) do dep_set[v] = true end
      assert.is_true(dep_set["ab05fb51"])
      assert.is_true(dep_set["cd12ef34"])
    end)
  end)

  -- ── round-trip ────────────────────────────────────────────────────────────

  describe("round-trip (parse → serialize → parse)", function()
    it("preserves all fields through a round-trip", function()
      local original = "- [ ] Deploy service project:Work priority:H due:2026-04-01 +backend"
      local task = M.parse_task_line(original)
      assert.is_not_nil(task)
      local serialized = M.serialize_task_line(task)
      local reparsed = M.parse_task_line(serialized)
      assert.is_not_nil(reparsed)
      assert.equals(task.description, reparsed.description)
      assert.equals(task.project, reparsed.project)
      assert.equals(task.priority, reparsed.priority)
      assert.equals(task.due, reparsed.due)
      assert.same(task.tags, reparsed.tags)
    end)
  end)

end)

-- ── date helper tests ──────────────────────────────────────────────────────

describe("tw_date_to_human / human_date_to_tw", function()
  it("converts TW wire format to YYYY-MM-DD", function()
    assert.equals("2026-03-22", M.tw_date_to_human("20260322T134834Z"))
  end)

  it("leaves YYYY-MM-DD unchanged", function()
    assert.equals("2026-03-22", M.tw_date_to_human("2026-03-22"))
  end)

  it("converts YYYY-MM-DD to TW wire format", function()
    assert.equals("20260401T000000Z", M.human_date_to_tw("2026-04-01"))
  end)

  it("leaves TW wire format unchanged", function()
    assert.equals("20260322T134834Z", M.human_date_to_tw("20260322T134834Z"))
  end)

  it("returns non-string input unchanged", function()
    assert.equals(42, M.tw_date_to_human(42))
    assert.equals(42, M.human_date_to_tw(42))
  end)
end)

-- ── effort helper tests ────────────────────────────────────────────────────

describe("format_effort / parse_effort", function()
  it("formats PT1H30M to 1h30m", function()
    assert.equals("1h30m", M.format_effort("PT1H30M"))
  end)

  it("formats PT30M to 30m (no leading hours)", function()
    assert.equals("30m", M.format_effort("PT30M"))
  end)

  it("formats PT2H to 2h", function()
    assert.equals("2h", M.format_effort("PT2H"))
  end)

  it("formats PT45S to 45s", function()
    assert.equals("45s", M.format_effort("PT45S"))
  end)

  it("parses 1h30m to PT1H30M", function()
    assert.equals("PT1H30M", M.parse_effort("1h30m"))
  end)

  it("parses 30m to PT30M", function()
    assert.equals("PT30M", M.parse_effort("30m"))
  end)

  it("parses 2h to PT2H", function()
    assert.equals("PT2H", M.parse_effort("2h"))
  end)

  it("returns already-ISO durations unchanged", function()
    assert.equals("PT1H30M", M.parse_effort("PT1H30M"))
  end)

  it("returns unknown string unchanged from format_effort", function()
    assert.equals("not-a-duration", M.format_effort("not-a-duration"))
  end)
end)
