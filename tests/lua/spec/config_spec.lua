-- config_spec.lua — tests for require('taskwarrior.config').setup({...}).
--
-- Covers:
--   • setup() stores merged options in M.options
--   • Overrides replace defaults (shallow fields)
--   • Deep-merge of nested tables (e.g. `delegate`)
--   • Calling setup() twice: second call replaces options
--   • Calling setup() with no argument (or nil) uses defaults unchanged
--   • All documented default values are present after setup({})
--   • Extra/unknown keys passed to setup() are preserved as-is
--   • M.defaults is never mutated by setup() calls

local config = require("taskwarrior.config")

-- Helper: deep-clone a table so we can detect mutations to M.defaults
local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end

describe("taskwarrior.config", function()

  -- Snapshot of defaults before any tests run
  local defaults_snapshot

  before_each(function()
    -- Fresh snapshot each test so mutations are caught per-test
    defaults_snapshot = deep_copy(config.defaults)
    -- Reset options to empty table before each test
    config.options = {}
  end)

  after_each(function()
    -- Verify M.defaults was not mutated
    assert.same(defaults_snapshot, config.defaults, "M.defaults was mutated by setup()")
  end)

  -- ── setup with no arg ────────────────────────────────────────────────────

  describe("setup() with no argument", function()
    it("populates M.options with defaults when called with nil", function()
      config.setup(nil)
      assert.is_not_nil(config.options)
      assert.equals(config.defaults.backend, config.options.backend)
    end)

    it("populates M.options with defaults when called with empty table", function()
      config.setup({})
      assert.equals(config.defaults.on_delete, config.options.on_delete)
      assert.equals(config.defaults.sort,      config.options.sort)
      assert.equals(config.defaults.backend,   config.options.backend)
      assert.equals(config.defaults.confirm,   config.options.confirm)
    end)
  end)

  -- ── documented default values ────────────────────────────────────────────

  describe("documented default values", function()
    before_each(function()
      config.setup({})
    end)

    it("on_delete defaults to 'done'", function()
      assert.equals("done", config.options.on_delete)
    end)

    it("confirm defaults to true", function()
      assert.is_true(config.options.confirm)
    end)

    it("sort defaults to 'urgency-'", function()
      assert.equals("urgency-", config.options.sort)
    end)

    it("group defaults to nil", function()
      assert.is_nil(config.options.group)
    end)

    it("fields defaults to nil", function()
      assert.is_nil(config.options.fields)
    end)

    it("backend defaults to 'lua'", function()
      assert.equals("lua", config.options.backend)
    end)

    it("icons defaults to true", function()
      assert.is_true(config.options.icons)
    end)

    it("border_style defaults to 'rounded'", function()
      assert.equals("rounded", config.options.border_style)
    end)

    it("animation defaults to true", function()
      assert.is_true(config.options.animation)
    end)

    it("clamp_cursor defaults to true", function()
      assert.is_true(config.options.clamp_cursor)
    end)

    it("day_start_hour defaults to 4", function()
      assert.equals(4, config.options.day_start_hour)
    end)

    it("delegate table is present", function()
      assert.is_not_nil(config.options.delegate)
      assert.equals("claude", config.options.delegate.command)
    end)
  end)

  -- ── shallow override ─────────────────────────────────────────────────────

  describe("shallow field overrides", function()
    it("honors on_delete override", function()
      config.setup({ on_delete = "delete" })
      assert.equals("delete", config.options.on_delete)
    end)

    it("honors sort override", function()
      config.setup({ sort = "project+" })
      assert.equals("project+", config.options.sort)
    end)

    it("honors backend override", function()
      config.setup({ backend = "python" })
      assert.equals("python", config.options.backend)
    end)

    it("preserves unmentioned defaults after override", function()
      config.setup({ sort = "project+" })
      assert.equals("done", config.options.on_delete)
      assert.equals("lua",  config.options.backend)
    end)
  end)

  -- ── deep-merge nested tables ─────────────────────────────────────────────

  describe("deep-merge nested tables", function()
    it("merges delegate sub-table: overriding command leaves other delegate keys intact", function()
      config.setup({ delegate = { command = "aider" } })
      assert.equals("aider", config.options.delegate.command)
      -- Other delegate keys from defaults should survive
      assert.is_not_nil(config.options.delegate.height,
        "delegate.height should survive deep merge")
    end)

    it("merges delegate sub-table: overriding height leaves command intact", function()
      config.setup({ delegate = { height = 0.8 } })
      assert.equals(0.8, config.options.delegate.height)
      assert.equals("claude", config.options.delegate.command)
    end)
  end)

  -- ── second setup() call replaces options ────────────────────────────────

  describe("calling setup() twice", function()
    it("second call replaces options from first call", function()
      config.setup({ sort = "project+" })
      config.setup({ sort = "urgency-" })
      assert.equals("urgency-", config.options.sort)
    end)

    it("second call with new key does not retain previous call's overrides", function()
      config.setup({ on_delete = "delete" })
      config.setup({ sort = "project+" })
      -- on_delete should be back to default because second call starts fresh
      assert.equals("done", config.options.on_delete)
    end)
  end)

  -- ── unknown / extra keys ─────────────────────────────────────────────────

  describe("extra/unknown keys", function()
    it("rejects unknown keys with a clear error", function()
      local ok, err = pcall(config.setup, { my_custom_option = "hello" })
      assert.is_false(ok)
      assert.matches("unknown setup key 'my_custom_option'", err)
    end)
  end)

  -- ── urgency_coefficients ─────────────────────────────────────────────────

  describe("urgency_coefficients", function()
    it("defaults to empty table", function()
      config.setup({})
      assert.same({}, config.options.urgency_coefficients)
    end)

    it("accepts a coefficients map", function()
      config.setup({ urgency_coefficients = { utility = 0.5 } })
      assert.equals(0.5, config.options.urgency_coefficients.utility)
    end)
  end)

  -- ── custom_urgency function ───────────────────────────────────────────────

  describe("custom_urgency", function()
    it("defaults to nil", function()
      config.setup({})
      assert.is_nil(config.options.custom_urgency)
    end)

    it("accepts a function", function()
      local fn = function(task) return (task.urgency or 0) + 1 end
      config.setup({ custom_urgency = fn })
      assert.equals(fn, config.options.custom_urgency)
    end)
  end)

end)
