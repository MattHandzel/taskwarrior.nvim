local M = {}

-- setup: register every :Task* user command on the running nvim.
--   main: the require("taskwarrior") module (so we can forward to M.open, M.filter, …)
--   complete_filter: arg-lead → completion list (kept as a closure in init.lua)
function M.setup(main, complete_filter)
  vim.api.nvim_create_user_command("Task", function(cmd_opts)
    main.open(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Open Taskwarrior tasks as markdown",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  vim.api.nvim_create_user_command("TaskFilter", function(cmd_opts)
    main.filter(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Change task filter",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  vim.api.nvim_create_user_command("TaskRefresh", function()
    main.refresh()
  end, { nargs = 0, desc = "Refresh task buffer" })

  vim.api.nvim_create_user_command("TaskUndo", function()
    main.undo()
  end, { nargs = 0, desc = "Undo last save" })

  vim.api.nvim_create_user_command("TaskSort", function(cmd_opts)
    main.sort(cmd_opts.args)
  end, {
    nargs = 1,
    desc = "Change task sort order (e.g. due+, urgency-)",
    complete = function(arg_lead)
      local fields = { "urgency-", "urgency+", "due+", "due-", "priority-",
                       "priority+", "project+", "project-", "description+" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  vim.api.nvim_create_user_command("TaskGroup", function(cmd_opts)
    main.group(cmd_opts.args)
  end, {
    nargs = "?",
    desc = "Change task grouping (e.g. project, tag, none)",
    complete = function(arg_lead)
      local fields = { "project", "priority", "status", "tag", "none" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  vim.api.nvim_create_user_command("TaskAdd", function()
    main.capture()
  end, { nargs = 0, desc = "Quick-capture a new task" })

  vim.api.nvim_create_user_command("TaskHelp", function()
    main.help()
  end, { nargs = 0, desc = "Show taskwarrior.nvim help" })

  vim.api.nvim_create_user_command("TaskProjectAdd", function(cmd_opts)
    main.project_add(cmd_opts.args)
  end, { nargs = "?", desc = "Register cwd as a Taskwarrior project" })

  vim.api.nvim_create_user_command("TaskProjectRemove", function()
    main.project_remove()
  end, { nargs = 0, desc = "Unregister cwd as a project" })

  vim.api.nvim_create_user_command("TaskProjectList", function()
    main.project_list()
  end, { nargs = 0, desc = "List registered projects" })

  vim.api.nvim_create_user_command("TaskDelegate", function(cmd_opts)
    local sub = cmd_opts.args
    if sub == "copy" or sub == "copy-command" then
      main.delegate_copy(sub)
    else
      main.delegate()
    end
  end, {
    nargs = "?",
    range = true,
    desc = "Delegate task(s) to Claude",
    complete = function() return { "copy", "copy-command" } end,
  })

  vim.api.nvim_create_user_command("TaskStart", function()
    main.start_stop("start")
  end, { nargs = 0, desc = "Start the task on the cursor" })

  vim.api.nvim_create_user_command("TaskStop", function()
    main.start_stop("stop")
  end, { nargs = 0, desc = "Stop the task on the cursor" })

  vim.api.nvim_create_user_command("TaskSave", function(cmd_opts)
    main.view_save(cmd_opts.args)
  end, { nargs = 1, desc = "Save the current filter+sort+group as a named view" })

  vim.api.nvim_create_user_command("TaskLoad", function(cmd_opts)
    main.view_load(cmd_opts.args)
  end, {
    nargs = "?",
    desc = "Load a saved view",
    complete = function(arg_lead)
      local names = main.view_list_names() or {}
      local results = {}
      for _, n in ipairs(names) do
        if n:sub(1, #arg_lead) == arg_lead then table.insert(results, n) end
      end
      return results
    end,
  })

  vim.api.nvim_create_user_command("TaskReview", function()
    main.review()
  end, { nargs = 0, desc = "Walk through pending tasks one at a time" })

  vim.api.nvim_create_user_command("TaskDiffPreview", function(cmd_opts)
    local dp = require("taskwarrior.diff_preview")
    local a = cmd_opts.args
    if a == "on" then dp.enable()
    elseif a == "off" then dp.disable()
    else dp.toggle() end
  end, {
    nargs = "?",
    desc = "Toggle live diff preview (virtual text)",
    complete = function() return { "on", "off", "toggle" } end,
  })

  -- Visualization commands
  local views = require("taskwarrior.views")

  vim.api.nvim_create_user_command("TaskBurndown", function()
    views.burndown()
  end, { nargs = 0, desc = "Show burndown chart" })

  vim.api.nvim_create_user_command("TaskTree", function()
    views.tree()
  end, { nargs = 0, desc = "Show dependency tree" })

  vim.api.nvim_create_user_command("TaskSummary", function()
    views.summary()
  end, { nargs = 0, desc = "Show project summary" })

  vim.api.nvim_create_user_command("TaskCalendar", function()
    views.calendar()
  end, { nargs = 0, desc = "Show calendar view of due dates" })

  vim.api.nvim_create_user_command("TaskTags", function()
    views.tags()
  end, { nargs = 0, desc = "Show tag distribution" })

  -- Structured feedback buffer (opt-in; needs feedback_endpoint in setup)
  vim.api.nvim_create_user_command("TaskFeedback", function()
    require("taskwarrior.feedback").open()
  end, { desc = "Send structured feedback about taskwarrior.nvim" })

  -- Task-level ops
  vim.api.nvim_create_user_command("TaskAppend", function(o)
    main.append(o.args)
  end, { nargs = "*", desc = "Append text to description of task under cursor" })

  vim.api.nvim_create_user_command("TaskPrepend", function(o)
    main.prepend(o.args)
  end, { nargs = "*", desc = "Prepend text to description of task under cursor" })

  vim.api.nvim_create_user_command("TaskDuplicate", function()
    main.duplicate()
  end, { nargs = 0, desc = "Duplicate the task under cursor" })

  vim.api.nvim_create_user_command("TaskPurge", function(o)
    main.purge(o.args)
  end, { nargs = "*", desc = "Irreversibly purge deleted tasks (by filter)" })

  vim.api.nvim_create_user_command("TaskDenotate", function()
    main.denotate()
  end, { nargs = 0, desc = "Remove an annotation from the task under cursor" })

  vim.api.nvim_create_user_command("TaskModifyField", function(o)
    main.modify_field_by_name(o.args)
  end, {
    nargs = 1,
    desc = "Modify a single field of the task under cursor via picker",
    complete = function() return { "project", "priority", "due", "tag" } end,
  })

  vim.api.nvim_create_user_command("TaskBulkModify", function(o)
    main.bulk_modify({ o.line1, o.line2 }, o.args)
  end, {
    nargs = "+", range = true,
    desc = "Apply the same modify to every task in the selected range",
  })

  -- Named reports (task next / active / overdue / ...)
  vim.api.nvim_create_user_command("TaskReport", function(o)
    main.report(o.args)
  end, {
    nargs = "?",
    desc = "Open a named Taskwarrior report",
    complete = function(arg_lead)
      local names = main.report_names() or {}
      local out = {}
      for _, n in ipairs(names) do
        if n:sub(1, #arg_lead) == arg_lead then table.insert(out, n) end
      end
      return out
    end,
  })

  -- Differentiators
  vim.api.nvim_create_user_command("TaskGraph", function()
    main.graph()
  end, { nargs = 0, desc = "Render the dependency graph as a Mermaid diagram" })

  vim.api.nvim_create_user_command("TaskInbox", function()
    main.inbox()
  end, { nargs = 0, desc = "Triage recently-added tasks with no project/due/tags" })

  vim.api.nvim_create_user_command("TaskExport", function(o)
    main.export(o.args)
  end, { nargs = "?", desc = "Write the rendered task buffer to a markdown file" })

  vim.api.nvim_create_user_command("TaskSync", function()
    main.sync()
  end, { nargs = 0, desc = "Run `task sync` with progress and error handling" })

  vim.api.nvim_create_user_command("TaskFloat", function(o)
    require("taskwarrior.buffer").open_float(o.args)
  end, {
    nargs = "*",
    desc = "Open tasks in a centered floating window",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  -- Nested checkbox → dependency helpers
  vim.api.nvim_create_user_command("TaskLinkChildren", function()
    require("taskwarrior.nested").link_children()
  end, {
    nargs = 0,
    desc = "Mark indented tasks below cursor as depends: of the cursor task",
  })
  vim.api.nvim_create_user_command("TaskUnlinkChildren", function()
    require("taskwarrior.nested").unlink_children()
  end, { nargs = 0, desc = "Remove depends: for indented children of cursor task" })
end

return M
