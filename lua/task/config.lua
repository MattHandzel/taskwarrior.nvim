local M = {}

M.defaults = {
	on_delete = "done", -- "done" or "delete" when lines are removed
	confirm = true, -- show confirmation dialog before applying
	sort = "urgency-", -- default sort
	group = nil, -- default group field (nil to disable)
	fields = nil, -- fields to show (nil = all)
	taskmd_path = nil, -- path to taskmd binary (auto-detected if nil)
	backend = "lua", -- "lua" (pure-Lua, no python dep) or "python" (bin/taskmd subprocess)
	capture_key = "<leader>ta", -- global keybind for quick capture (nil to disable)
	open_key = "<leader>tt", -- global keybind to open task buffer (nil to disable)
	filter_key = "<leader>tf", -- buffer-local keybind to change filter (nil to disable)
	sort_key = "<leader>ts", -- buffer-local keybind to change sort (nil to disable)
	group_key = "<leader>tg", -- buffer-local keybind to change grouping (nil to disable)
	project_add_key = "<leader>tpa", -- global keybind to register cwd as a project (nil to disable)
	filters = {}, -- named filter presets: { { key = "<key>", filter = "filter_str", label = "label" }, ... }
	projects = {}, -- directory-to-project mapping: { ["/path/to/dir"] = "project_name", ... }
	icons = true, -- use nerd font icons for checkboxes and group headers
	border_style = "rounded", -- border style for floating windows: "rounded", "single", "double", "none"
	group_separator = true, -- show separator lines between groups
	animation = true, -- enable open/transition animations
	clamp_cursor = true, -- clamp cursor before UUID comment (prevents invisible cursor movement)
	day_start_hour = 4, -- hour (0-23) when "today" starts (for night owls: 4 = 4am)
	-- Custom urgency: map UDA field names to TW urgency coefficients (linear).
	-- Example: { utility = 0.5, effort = -0.1 }
	-- Sets rc.urgency.uda.FIELD.coefficient=VALUE for each entry.
	urgency_coefficients = {},
	-- Non-linear custom urgency: a Lua function(task) -> number.
	-- Receives the full task table (from TW export). Return adjusted urgency.
	-- When set, tasks are re-sorted by this value instead of TW urgency.
	-- Example:
	--   custom_urgency = function(task)
	--     local base = task.urgency or 0
	--     local utility = tonumber(task.utility) or 0
	--     local effort_mins = tonumber(task.effort_minutes) or 60
	--     return base + math.log(utility + 1) * 3 - math.sqrt(effort_mins) * 0.1
	--   end
	custom_urgency = nil,
	-- :TaskDelegate — claude-code delegation defaults. Each field is overridable
	-- per-invocation via the popup prompt.
	delegate = {
		command = "claude", -- binary to invoke
		flags = "--dangerously-skip-permissions", -- extra CLI flags
		system_prompt_file = nil, -- path to a file passed via --append-system-prompt
		model = nil, -- e.g. "claude-opus-4-6" or "sonnet"
		height = 0.5, -- terminal split height as a fraction of editor height
	},
}

M.options = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
