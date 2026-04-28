-- Telescope extension for taskwarrior.nvim. Provides a fuzzy picker over pending
-- Taskwarrior tasks. Loads only when the user has telescope installed; this
-- file is picked up automatically by `require("telescope").load_extension("task")`.

local ok, telescope = pcall(require, "telescope")
if not ok then
  return {}
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local previewers = require("telescope.previewers")

local function tw_export(filter)
  local cmd = string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export",
    filter or "status:pending")
  local out = vim.fn.system(cmd)
  local json_start = out:find("%[")
  if json_start and json_start > 1 then out = out:sub(json_start) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then return {} end
  return tasks
end

local function entry_for(task)
  local short = task.uuid and task.uuid:sub(1, 8) or ""
  local project = task.project or ""
  local tags = task.tags and table.concat(task.tags, ",") or ""
  local urgency = task.urgency or 0
  local display = string.format("%6.1f  %-12s  %s  %s",
    urgency, project:sub(1, 12), task.description or "",
    tags ~= "" and ("+" .. tags) or "")
  return {
    value = task,
    display = display,
    ordinal = table.concat({
      short, project, task.description or "", tags,
    }, " "),
    uuid = task.uuid,
    short = short,
  }
end

local function task_preview()
  return previewers.new_buffer_previewer({
    title = "Task info",
    define_preview = function(self, entry)
      if not entry or not entry.short then return end
      local out = vim.fn.systemlist(string.format("task %s info", entry.short))
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, out)
    end,
  })
end

local function picker(opts)
  opts = opts or {}
  local tasks = tw_export(opts.filter)
  local entries = {}
  for _, t in ipairs(tasks) do table.insert(entries, entry_for(t)) end

  pickers.new(opts, {
    prompt_title = "taskwarrior.nvim — " .. (opts.filter or "status:pending"),
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e) return e end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = task_preview(),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not selection or not selection.short then return end
        -- Open taskwarrior.nvim buffer filtered to this one task
        pcall(require, "taskwarrior")
        require("taskwarrior").open("uuid:" .. selection.short)
      end)
      -- <C-x>: mark task done
      map({ "i", "n" }, "<C-x>", function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.short then return end
        vim.fn.system(string.format(
          "task rc.bulk=0 rc.confirmation=off %s done", selection.short))
        actions.close(prompt_bufnr)
        vim.notify("taskwarrior.nvim: marked " .. selection.short .. " done")
      end)
      -- <C-s>: start/stop
      map({ "i", "n" }, "<C-s>", function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.short then return end
        local is_started = selection.value and selection.value.start
        local cmd = is_started and "stop" or "start"
        vim.fn.system(string.format(
          "task rc.bulk=0 rc.confirmation=off %s %s", selection.short, cmd))
        actions.close(prompt_bufnr)
        vim.notify(string.format("taskwarrior.nvim: %s %s", cmd, selection.short))
      end)
      -- <C-d>: delete (with confirmation)
      map({ "i", "n" }, "<C-d>", function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.short then return end
        actions.close(prompt_bufnr)
        vim.ui.select({ "yes", "no" }, {
          prompt = "Delete task " .. selection.short .. "?",
        }, function(choice)
          if choice ~= "yes" then return end
          vim.fn.system(string.format(
            "task rc.bulk=0 rc.confirmation=off %s delete", selection.short))
          vim.notify("taskwarrior.nvim: deleted " .. selection.short)
        end)
      end)
      -- <C-y>: yank UUID to unnamed register (and + if present)
      map({ "i", "n" }, "<C-y>", function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.uuid then return end
        vim.fn.setreg('"', selection.uuid)
        pcall(vim.fn.setreg, "+", selection.uuid)
        vim.notify("taskwarrior.nvim: yanked " .. selection.uuid)
      end)
      -- <C-a>: add a task from inside the picker (closes + opens quick-capture)
      map({ "i", "n" }, "<C-a>", function()
        actions.close(prompt_bufnr)
        pcall(function() require("taskwarrior").capture() end)
      end)
      -- <C-c>: run a custom `task <uuid> <verb>` on the selection. Prompts for
      -- the verb+args and shells out; ideal for one-off modifies or annotate.
      map({ "i", "n" }, "<C-c>", function()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.short then return end
        local short = selection.short
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "task " .. short .. " " }, function(verb)
          if not verb or verb == "" then return end
          local out = vim.fn.system(string.format(
            "task rc.bulk=0 rc.confirmation=off %s %s", short, verb))
          if vim.v.shell_error == 0 then
            vim.notify("taskwarrior.nvim: " .. short .. " " .. verb)
          else
            vim.notify("taskwarrior.nvim: failed\n" .. out, vim.log.levels.ERROR)
          end
        end)
      end)
      return true
    end,
  }):find()
end

return telescope.register_extension({
  exports = {
    task = picker,
    tasks = picker,
  },
})
