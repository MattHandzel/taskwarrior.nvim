-- features_spec.lua — smoke tests for features added in the gap-analysis push.
--
-- Tests that don't need a live Taskwarrior DB: module loading, config
-- validation, parse helpers, query-block extraction, etc. Anything that
-- needs `task` to exist is intentionally skipped here — those paths are
-- already covered by the Python integration tests under tests/test_taskmd*.py
-- and by manual verification documented in CHANGELOG.

describe("taskwarrior feature modules", function()
  it("all new modules load without error", function()
    for _, m in ipairs({
      "taskwarrior.modify",
      "taskwarrior.notify",
      "taskwarrior.granulation",
      "taskwarrior.report",
      "taskwarrior.graph",
      "taskwarrior.inbox",
      "taskwarrior.export",
      "taskwarrior.sync",
      "taskwarrior.bulk",
      "taskwarrior.dashboard",
      "taskwarrior.query_blocks",
      "taskwarrior.nested",
    }) do
      local ok, mod = pcall(require, m)
      assert.is_true(ok, m .. " failed to load: " .. tostring(mod))
      assert.is_table(mod)
    end
  end)
end)

describe("taskwarrior.config new keys", function()
  local config = require("taskwarrior.config")
  before_each(function() config.options = {} end)

  it("tag_colors defaults to empty table", function()
    config.setup({})
    assert.same({}, config.options.tag_colors)
  end)

  it("urgency_colors defaults has three bands sorted high-to-low", function()
    config.setup({})
    assert.is_true(#config.options.urgency_colors >= 3)
    for i = 1, #config.options.urgency_colors - 1 do
      assert.is_true(
        config.options.urgency_colors[i].threshold
          >= config.options.urgency_colors[i + 1].threshold,
        "urgency_colors must be sorted high-to-low")
    end
  end)

  it("notifications keys default to true", function()
    config.setup({})
    assert.is_true(config.options.notifications.start)
    assert.is_true(config.options.notifications.modify)
    assert.is_true(config.options.notifications.apply)
  end)

  it("granulation is disabled by default", function()
    config.setup({})
    assert.is_false(config.options.granulation.enabled)
    assert.is_number(config.options.granulation.idle_ms)
  end)

  it("accepts tag_colors map", function()
    config.setup({ tag_colors = { ["+urgent"] = "ErrorMsg" } })
    assert.equals("ErrorMsg", config.options.tag_colors["+urgent"])
  end)

  it("rejects non-string/non-table tag_colors value", function()
    local ok, err = pcall(config.setup, { tag_colors = { ["+x"] = 42 } })
    assert.is_false(ok)
    assert.matches("tag_colors", err)
  end)

  it("rejects urgency_colors entry without threshold", function()
    local ok, err = pcall(config.setup, { urgency_colors = { { hl = "X" } } })
    assert.is_false(ok)
    assert.matches("threshold", err)
  end)

  it("rejects non-boolean notifications value", function()
    local ok, err = pcall(config.setup, { notifications = { start = "yes" } })
    assert.is_false(ok)
    assert.matches("notifications", err)
  end)

  it("rejects unknown granulation key", function()
    local ok, err = pcall(config.setup, { granulation = { bogus = 1 } })
    assert.is_false(ok)
    assert.matches("granulation", err)
  end)

  it("accepts extended projects entry", function()
    config.setup({
      projects = {
        ["/tmp/foo"] = { name = "foo", view = "morning" },
      },
    })
    assert.equals("foo", config.options.projects["/tmp/foo"].name)
    assert.equals("morning", config.options.projects["/tmp/foo"].view)
  end)

  it("rejects unknown key in extended projects entry", function()
    local ok, err = pcall(config.setup, {
      projects = { ["/x"] = { name = "x", bogus = "y" } },
    })
    assert.is_false(ok)
    assert.matches("bogus", err)
  end)
end)

describe("taskwarrior.report", function()
  local report = require("taskwarrior.report")

  it("has the core Taskwarrior report names", function()
    local have = {}
    for _, n in ipairs(report.names()) do have[n] = true end
    assert.is_true(have["next"])
    assert.is_true(have.active)
    assert.is_true(have.overdue)
    assert.is_true(have.ready)
    assert.is_true(have.waiting)
  end)

  it("each report has a filter and sort", function()
    for name, r in pairs(report.reports) do
      assert.is_string(r.filter, name .. ".filter must be a string")
      assert.is_string(r.sort, name .. ".sort must be a string")
    end
  end)
end)

describe("taskwarrior.query_blocks", function()
  local qb = require("taskwarrior.query_blocks")

  local function make_buffer(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("finds a single block with filter only", function()
    local buf = make_buffer({
      "# notes",
      "<!-- taskmd query: status:pending -->",
      "- [ ] old",
      "<!-- taskmd endquery -->",
      "prose",
    })
    local blocks = qb.find_blocks(buf)
    assert.equals(1, #blocks)
    assert.equals("status:pending", blocks[1].spec.filter)
    assert.equals(1, blocks[1].open_line)
    assert.equals(3, blocks[1].close_line)
  end)

  it("parses sort + group from spec", function()
    local buf = make_buffer({
      "<!-- taskmd query: +urgent | sort:due+ | group:project -->",
      "<!-- taskmd endquery -->",
    })
    local blocks = qb.find_blocks(buf)
    assert.equals(1, #blocks)
    assert.equals("+urgent", blocks[1].spec.filter)
    assert.equals("due+", blocks[1].spec.sort)
    assert.equals("project", blocks[1].spec.group)
  end)

  it("handles multiple blocks per buffer", function()
    local buf = make_buffer({
      "<!-- taskmd query: a -->",
      "<!-- taskmd endquery -->",
      "middle",
      "<!-- taskmd query: b -->",
      "<!-- taskmd endquery -->",
    })
    local blocks = qb.find_blocks(buf)
    assert.equals(2, #blocks)
    assert.equals("a", blocks[1].spec.filter)
    assert.equals("b", blocks[2].spec.filter)
  end)

  it("ignores unclosed blocks", function()
    local buf = make_buffer({
      "<!-- taskmd query: orphan -->",
      "some content without closing tag",
    })
    local blocks = qb.find_blocks(buf)
    assert.equals(0, #blocks)
  end)
end)

describe("taskwarrior.export", function()
  local exp = require("taskwarrior.export")

  it("exposes write() as the main entry point", function()
    assert.is_function(exp.write)
  end)
end)

describe("taskwarrior.dashboard", function()
  local dash = require("taskwarrior.dashboard")

  it("top_urgent returns a list", function()
    local lines = dash.top_urgent(3)
    assert.is_table(lines)
    assert.is_true(#lines >= 1)
  end)
end)

describe("taskwarrior.graph", function()
  local graph = require("taskwarrior.graph")

  it("render handles absence of tasks (returns nil or empty)", function()
    -- graph.render shells to `task export`; on systems without data this
    -- should still come back as a flowchart with only the preamble lines.
    local lines = graph.render("status:pending")
    if lines ~= nil then
      assert.is_true(#lines >= 4)
      assert.equals("```mermaid", lines[3])
    end
  end)
end)

describe("taskwarrior.projects per-cwd extended entries", function()
  local projects = require("taskwarrior.projects")
  local config = require("taskwarrior.config")

  it("detect_entry returns a name-only table for legacy string form", function()
    config.options = { projects = { [vim.fn.getcwd()] = "legacy" } }
    local entry = projects.detect_entry()
    assert.same({ name = "legacy" }, entry)
  end)

  it("detect_entry returns the full table for extended form", function()
    config.options = {
      projects = { [vim.fn.getcwd()] = { name = "full", view = "morning" } },
    }
    local entry = projects.detect_entry()
    assert.equals("full", entry.name)
    assert.equals("morning", entry.view)
  end)

  it("detect() returns the project name for either form", function()
    config.options = { projects = { [vim.fn.getcwd()] = { name = "bar" } } }
    assert.equals("bar", projects.detect())
  end)

  it("longest-prefix wins on overlapping entries", function()
    local cwd = vim.fn.getcwd()
    config.options = {
      projects = {
        [cwd]            = "outer",
        [cwd:match("(.*)/") or cwd] = "parent",
      },
    }
    -- With two matches, the deeper path (cwd itself) wins.
    assert.equals("outer", projects.detect())
  end)
end)

describe("taskwarrior.notify", function()
  it("is a callable (metatable __call)", function()
    local notify = require("taskwarrior.notify")
    assert.is_true(pcall(function() notify("modify", "hi") end))
  end)
end)

describe("taskwarrior.buffer.urgency_hl", function()
  local buffer = require("taskwarrior.buffer")
  local config = require("taskwarrior.config")

  before_each(function()
    config.setup({
      urgency_colors = {
        { threshold = 10, hl = "RED" },
        { threshold = 5,  hl = "YELLOW" },
        { threshold = 0,  hl = "GREEN" },
      },
    })
  end)

  it("selects the first matching band (high urgency)", function()
    assert.equals("RED", buffer.urgency_hl(12))
  end)

  it("selects the middle band for medium urgency", function()
    assert.equals("YELLOW", buffer.urgency_hl(6))
  end)

  it("selects the low band for sub-threshold urgency", function()
    assert.equals("GREEN", buffer.urgency_hl(1))
  end)

  it("returns the fallback when urgency is nil", function()
    assert.equals("Comment", buffer.urgency_hl(nil))
  end)
end)
