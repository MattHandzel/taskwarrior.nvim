-- icons_spec.lua — checkbox virt_text overlay correctness.
--
-- The literal "- [ ]" in the markdown source is sacred (parser depends on
-- it). The plugin paints a 5-cell virt_text overlay on top so the rendered
-- buffer shows a nerd-font checkbox while the source round-trips cleanly.

local config = require("taskwarrior.config")
local buffer = require("taskwarrior.buffer")
local icons = require("taskwarrior.icons")

describe("checkbox_overlay_text", function()
  local saved_have_nf

  before_each(function()
    config.setup({})
    saved_have_nf = vim.g.have_nerd_font
  end)

  after_each(function() vim.g.have_nerd_font = saved_have_nf end)

  it("returns nil when icons = false (forced ASCII)", function()
    config.options.icons = false
    vim.g.have_nerd_font = true
    assert.is_nil(buffer._checkbox_overlay_text("checkbox_pending"))
  end)

  it("returns nil when icons = 'auto' and no nerd font", function()
    config.options.icons = "auto"
    vim.g.have_nerd_font = false
    assert.is_nil(buffer._checkbox_overlay_text("checkbox_pending"))
  end)

  it("returns NF glyph when icons = true regardless of vim.g.have_nerd_font", function()
    config.options.icons = true
    vim.g.have_nerd_font = nil
    local out = buffer._checkbox_overlay_text("checkbox_pending")
    assert.is_string(out)
    assert.are.equal(out, icons.get("checkbox_pending"))
  end)

  it("returns NF glyph when icons = 'auto' AND nerd font is available", function()
    config.options.icons = "auto"
    vim.g.have_nerd_font = true
    local out = buffer._checkbox_overlay_text("checkbox_pending")
    assert.is_string(out)
    assert.is_truthy(#out > 0)
  end)

  it("user table override is honored regardless of NF state", function()
    config.options.icons = { checkbox_pending = "X" }
    vim.g.have_nerd_font = false
    local out = buffer._checkbox_overlay_text("checkbox_pending")
    assert.are.equal("X", out)
  end)

  it("returns nil for an unknown slot name", function()
    config.options.icons = true
    vim.g.have_nerd_font = true
    assert.is_nil(buffer._checkbox_overlay_text("not_a_slot"))
    assert.is_nil(buffer._checkbox_overlay_text(nil))
  end)

  it("returns a non-empty glyph for every checkbox slot", function()
    config.options.icons = true
    vim.g.have_nerd_font = nil
    for _, slot in ipairs({ "checkbox_pending", "checkbox_started",
                            "checkbox_done", "checkbox_blocked" }) do
      local out = buffer._checkbox_overlay_text(slot)
      assert.is_string(out, "slot " .. slot .. " produced no glyph")
      assert.is_truthy(#out > 0, "slot " .. slot .. " glyph is empty")
    end
  end)
end)

describe("paint_checkbox_line", function()
  local saved_have_nf
  local ns

  before_each(function()
    config.setup({})
    saved_have_nf = vim.g.have_nerd_font
    -- Reach into the module for the namespace used by paint_checkbox_line.
    ns = vim.api.nvim_get_namespaces()["taskwarrior_vt"]
  end)

  after_each(function() vim.g.have_nerd_font = saved_have_nf end)

  it("places conceal + inline virt_text extmarks on a pending task line", function()
    config.options.icons = true
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [ ] hello" })

    local ok = buffer._paint_checkbox_line(bufnr, 0, "- [ ] hello")
    assert.is_true(ok)

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    -- Expect exactly two marks at lnum=0: one conceal (with end_col), one
    -- inline virt_text.
    assert.are.equal(2, #marks)
    local saw_conceal, saw_virt_text = false, false
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.conceal ~= nil then
        saw_conceal = true
        -- "- [ ] " is 6 bytes, conceal end_col should be 6 (with trailing
        -- space hidden) or 5 (no trailing space).
        assert.is_truthy(d.end_col == 5 or d.end_col == 6)
      end
      if d.virt_text and d.virt_text_pos == "inline" then
        saw_virt_text = true
        -- 2 chunks: glyph + " "
        assert.are.equal(2, #d.virt_text)
        assert.are.equal(" ", d.virt_text[2][1])
      end
    end
    assert.is_true(saw_conceal, "conceal extmark missing")
    assert.is_true(saw_virt_text, "inline virt_text extmark missing")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("returns false (no extmarks) on non-task lines", function()
    config.options.icons = true
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "## Section header" })
    assert.is_false(buffer._paint_checkbox_line(bufnr, 0, "## Section header"))
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    assert.are.equal(0, #marks)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("returns false when icons disabled (parser-faithful source visible)", function()
    config.options.icons = false
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [ ] task" })
    assert.is_false(buffer._paint_checkbox_line(bufnr, 0, "- [ ] task"))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
