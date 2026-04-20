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
	capture_width = nil, -- quick-capture window width (nil = auto: min(80, 60% of editor))
	capture_height = 3, -- quick-capture window height (lines visible; task is still 1 line)
	group_separator = true, -- show separator lines between groups
	animation = true, -- enable open/transition animations
	clamp_cursor = true, -- clamp cursor before UUID comment (prevents invisible cursor movement)
	day_start_hour = 4, -- hour (0-23) when "today" starts (for night owls: 4 = 4am)
	-- Custom urgency: map UDA field names to TW urgency coefficients (linear).
	-- Example: { utility = 0.5, effort = -0.1 }
	-- Sets rc.urgency.uda.FIELD.coefficient=VALUE for each entry.
	urgency_coefficients = {},
	-- Map UDA field names to functions(value) → number. Used by
	-- `urgency_coefficients` when a raw UDA value isn't directly numeric
	-- (e.g. effort stored as ISO 8601 duration "PT1H30M"). Default: nil,
	-- which lets the plugin apply its built-in defaults (see
	-- DEFAULT_URGENCY_VALUE_MAPPERS in taskmd.lua). Set to {} to disable
	-- all defaults and fall back to plain tonumber(). Override per-field
	-- to change units or handle custom UDA formats:
	--   urgency_value_mappers = {
	--     effort = tonumber,                            -- plain minutes, no ISO parse
	--     difficulty = function(v)
	--       return ({ low = 1, medium = 3, high = 10 })[v]
	--     end,
	--   }
	urgency_value_mappers = nil,
	-- Non-linear custom urgency: a Lua function(task) -> number.
	-- Receives the full task table (from TW export). Return adjusted urgency.
	-- When set, tasks are re-sorted by this value instead of TW urgency.
	custom_urgency = nil,
	-- Copy the Taskwarrior data directory to stdpath("data")/taskwarrior.nvim/backups/
	-- before any :w applies changes. Keeps the ten most recent backups and
	-- prunes older ones. Safe to disable if your data directory is large and
	-- you have an external backup strategy.
	auto_backup = true,
	auto_backup_keep = 10, -- number of recent backups to retain (>=1)
	feedback_endpoint = false, -- set to "https://matthandzel.com/api/task-feedback" to enable
	feedback_github_repo = "MattHandzel/taskwarrior.nvim", -- for GitHub issue fallback
	-- :TaskDelegate — claude-code delegation defaults. Each field is overridable
	-- per-invocation via the popup prompt.
	delegate = {
		command = "claude", -- binary to invoke
		-- Extra CLI flags passed to the delegate command. Default is empty —
		-- for unattended use you can opt into Claude Code's
		-- "--dangerously-skip-permissions" here, but it's not the default
		-- because it silently disables tool-permission prompts.
		flags = "",
		system_prompt_file = nil, -- path to a file passed via --append-system-prompt
		model = nil, -- e.g. "claude-opus-4-6" or "sonnet"
		height = 0.5, -- terminal split height as a fraction of editor height
	},
}

M.options = {}

function M.setup(opts)
	require("taskwarrior.validate").validate(opts)
	M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
