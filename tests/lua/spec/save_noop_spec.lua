-- save_noop_spec.lua — clean :w on an unchanged taskmd buffer must be a
-- true no-op: no toast, no apply pipeline, no fork to `task`. Regression
-- shield for #370.

local apply = require("taskwarrior.apply")
local config = require("taskwarrior.config")
local taskmd = require("taskwarrior.taskmd")

local function fresh_buf(line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  vim.bo[bufnr].modified = true
  return bufnr
end

describe("apply.on_write — no-op behavior (#370)", function()
  local saved_apply, saved_notify

  before_each(function()
    config.setup({})
    saved_apply = taskmd.apply
    saved_notify = vim.notify
  end)

  after_each(function()
    taskmd.apply = saved_apply
    vim.notify = saved_notify
  end)

  it("non-confirm: zero actions + zero conflicts → silent no-op", function()
    config.options.confirm = false
    taskmd.apply = function(_opts) return { actions = {}, conflicts = {} } end

    local notifications = {}
    vim.notify = function(msg, level) table.insert(notifications, { msg, level }) end

    local bufnr = fresh_buf("- [ ] hello <!-- uuid:abc12345 -->")
    local refresh_called, do_apply_called = false, false
    apply.on_write(bufnr,
      function() refresh_called = true end,
      function() do_apply_called = true end)

    assert.is_false(do_apply_called, "do_apply_fn must NOT be called on no-op")
    assert.is_false(refresh_called, "refresh must NOT be called on no-op")
    assert.are.equal(0, #notifications, "no toast on no-op save")
    assert.is_false(vim.bo[bufnr].modified, "modified flag is cleared")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("confirm mode: zero actions still emits the existing 'no changes' toast", function()
    config.options.confirm = true
    taskmd.apply = function(_opts) return { actions = {}, conflicts = {} } end
    local notifications = {}
    vim.notify = function(msg) table.insert(notifications, msg) end

    local bufnr = fresh_buf("- [ ] x <!-- uuid:abc12345 -->")
    local do_apply_called = false
    apply.on_write(bufnr, function() end, function() do_apply_called = true end)
    assert.is_false(do_apply_called)
    assert.are.equal(1, #notifications)
    assert.is_truthy(notifications[1]:match("no changes"))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("non-confirm: real actions still flow through to do_apply_fn", function()
    config.options.confirm = false
    taskmd.apply = function(_opts)
      return {
        actions = { { type = "modify", uuid = "u1" } },
        conflicts = {},
      }
    end
    vim.notify = function() end

    local bufnr = fresh_buf("- [ ] x <!-- uuid:abc12345 -->")
    local do_apply_called = false
    apply.on_write(bufnr, function() end, function() do_apply_called = true end)
    assert.is_true(do_apply_called)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("non-confirm: blocking conflict aborts and surfaces an error toast", function()
    config.options.confirm = false
    taskmd.apply = function(_opts)
      return {
        actions = {},
        conflicts = { { type = "external_modify", uuid = "u1", description = "x" } },
      }
    end
    local notifications = {}
    vim.notify = function(msg, level) table.insert(notifications, { msg = msg, level = level }) end

    local bufnr = fresh_buf("- [ ] x <!-- uuid:abc12345 -->")
    local do_apply_called = false
    apply.on_write(bufnr, function() end, function() do_apply_called = true end)
    assert.is_false(do_apply_called, "blocking conflict must abort save")
    local saw_conflict_msg = false
    for _, n in ipairs(notifications) do
      if n.msg:match("merge conflict") then saw_conflict_msg = true end
    end
    assert.is_true(saw_conflict_msg, "user must see the conflict message")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("non-confirm: zero actions + INFO conflict (external add/delete) still saves silently", function()
    -- Info conflicts are surfaced when there are local actions. With zero
    -- local actions, info-only is also a no-op from the user's perspective.
    config.options.confirm = false
    taskmd.apply = function(_opts)
      return {
        actions = {},
        conflicts = { { type = "external_add", uuid = "u9", description = "added externally" } },
      }
    end
    local notifications = {}
    vim.notify = function(msg) table.insert(notifications, msg) end

    local bufnr = fresh_buf("- [ ] x <!-- uuid:abc12345 -->")
    local do_apply_called = false
    apply.on_write(bufnr, function() end, function() do_apply_called = true end)
    -- Behavior: info conflicts in a zero-action save would notify but not
    -- spawn the apply pipeline. Verify do_apply is not called.
    assert.is_false(do_apply_called, "no actions ⇒ no apply pipeline even with info conflicts")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe("do_apply_and_refresh — toast suppression on action_count == 0", function()
  local saved_apply, saved_notify, saved_system

  before_each(function()
    config.setup({})
    saved_apply = taskmd.apply
    saved_notify = vim.notify
    saved_system = vim.fn.system
  end)

  after_each(function()
    taskmd.apply = saved_apply
    vim.notify = saved_notify
    vim.fn.system = saved_system
  end)

  it("force=true save with zero action_count emits no toast", function()
    -- Stub the Lua backend to return a successful apply summary with 0 actions
    -- (a `:w!` that ended up not actually doing anything).
    taskmd.apply = function(_opts)
      return {
        action_count = 0,
        added = 0, modified = 0, completed = 0, deleted = 0,
        conflicts = {}, errors = {},
      }
    end
    local notifications = {}
    vim.notify = function(msg) table.insert(notifications, msg) end

    local bufnr = fresh_buf("- [ ] x <!-- uuid:abc12345 -->")
    local refresh_called = false
    -- Write a real tmpfile so do_apply_and_refresh's vim.fn.delete is happy.
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ "- [ ] x" }, tmpfile)
    apply.do_apply_and_refresh(bufnr, tmpfile, "done",
      function() refresh_called = true end, { force = true })
    assert.is_true(refresh_called)
    assert.are.equal(0, #notifications,
      "no toast when action_count is zero (suppresses the noisy '+0 added, ~0 modified' line)")
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
