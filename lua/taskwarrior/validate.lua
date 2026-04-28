--- taskwarrior.nvim setup-option validation.
--- Raises a Lua error (level 0 = no location prefix) on the first problem found.

local M = {}

-- All valid top-level setup keys (explicit list — includes nil-defaulted keys
-- that pairs(defaults) would skip).
local KNOWN_KEYS = {
	"on_delete", "confirm", "sort", "group", "fields", "taskmd_path",
	"backend", "capture_key", "open_key", "filter_key", "sort_key",
	"group_key", "project_add_key", "filters", "projects", "icons",
	"border_style", "capture_width", "capture_height", "capture_confirm_close",
	"group_separator",
	"animation", "clamp_cursor", "day_start_hour", "urgency_coefficients",
	"urgency_value_mappers", "custom_urgency", "auto_backup", "auto_backup_keep",
	"feedback_endpoint", "feedback_github_repo", "delegate",
	"tag_colors", "urgency_colors", "notifications", "granulation",
	"header_stats", "icons", "urgency_bar", "relative_dates",
	"relative_date_refresh_ms", "show_urgency", "overdue_badge",
}

-- All valid delegate sub-keys (nil-defaulted keys included).
local KNOWN_DELEGATE_KEYS = {
	"command", "flags", "system_prompt_file", "model", "height",
}

-- Expected types for top-level keys. Keys absent from this table (e.g.
-- feedback_endpoint) are validated separately with custom logic.
local TOP_LEVEL_TYPES = {
	on_delete             = "string",
	confirm               = "boolean",
	sort                  = "string",
	group                 = "string",    -- nil OK
	fields                = "table",     -- nil OK
	taskmd_path           = "string",    -- nil OK
	backend               = "string",
	capture_key           = "string",    -- nil OK
	open_key              = "string",    -- nil OK
	filter_key            = "string",    -- nil OK
	sort_key              = "string",    -- nil OK
	group_key             = "string",    -- nil OK
	project_add_key       = "string",    -- nil OK
	filters               = "table",
	projects              = "table",
	icons                 = "boolean",
	border_style          = "string",
	capture_width         = "number",    -- nil OK
	capture_height        = "number",
	capture_confirm_close = "boolean",
	group_separator       = "boolean",
	animation             = "boolean",
	clamp_cursor          = "boolean",
	day_start_hour        = "number",
	urgency_coefficients  = "table",
	urgency_value_mappers = "table",     -- nil OK
	custom_urgency        = "function",  -- nil OK
	auto_backup           = "boolean",
	auto_backup_keep      = "number",
	feedback_github_repo  = "string",
	delegate              = "table",
	tag_colors            = "table",
	urgency_colors        = "table",
	notifications         = "table",
	granulation           = "table",
	header_stats          = "table", -- false OK (custom check below)
	urgency_bar           = "boolean",
	show_urgency          = "boolean",
	overdue_badge         = "boolean",
	relative_dates        = "boolean",
	relative_date_refresh_ms = "number",
	-- icons may be a table (partial override), nil (auto-detect), or false
	-- (force ASCII). Custom-checked below.
}

-- Expected types for delegate sub-keys.
local DELEGATE_TYPES = {
	command            = "string",
	flags              = "string",  -- nil OK
	system_prompt_file = "string",  -- nil OK
	model              = "string",  -- nil OK
	height             = "number",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Compute Levenshtein distance between two strings (capped for performance).
local function levenshtein(a, b)
	if #a > 40 or #b > 40 then return 99 end
	local m, n = #a, #b
	local dp = {}
	for i = 0, m do dp[i] = { [0] = i } end
	for j = 0, n do dp[0][j] = j end
	for i = 1, m do
		for j = 1, n do
			if a:sub(i, i) == b:sub(j, j) then
				dp[i][j] = dp[i - 1][j - 1]
			else
				dp[i][j] = 1 + math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
			end
		end
	end
	return dp[m][n]
end

--- Return the closest key from known_keys within Levenshtein distance 3, or nil.
local function suggest(key, known_keys)
	local best, best_dist = nil, 3
	for _, k in ipairs(known_keys) do
		local d = levenshtein(key, k)
		if d < best_dist then
			best, best_dist = k, d
		end
	end
	return best
end

--- Assert that all keys in `tbl` appear in `known`; error with suggestion if not.
local function check_unknown_keys(tbl, known, prefix)
	for k in pairs(tbl) do
		local found = false
		for _, kk in ipairs(known) do
			if k == kk then found = true; break end
		end
		if not found then
			local hint = suggest(k, known)
			local key_path = prefix and (prefix .. "." .. k) or k
			local msg = ("taskwarrior.nvim: unknown setup key '%s'"):format(key_path)
			if hint then
				msg = msg .. (" — did you mean '%s'?"):format(
					prefix and (prefix .. "." .. hint) or hint
				)
			end
			error(msg, 0)
		end
	end
end

--- Assert each non-nil value in `tbl` matches `type_map[key]`.
local function check_types(tbl, type_map, path_prefix)
	for key, expected_type in pairs(type_map) do
		local val = tbl[key]
		if val ~= nil and type(val) ~= expected_type then
			local key_path = path_prefix and (path_prefix .. "." .. key) or key
			error(
				("taskwarrior.nvim: setup key '%s' must be a %s, got %s"):format(
					key_path, expected_type, type(val)
				),
				0
			)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

--- Validate opts passed to require('taskwarrior').setup(opts).
--- Raises on the first validation failure with an actionable message.
function M.validate(opts)
	if opts == nil then return end

	-- 1. Unknown top-level keys.
	check_unknown_keys(opts, KNOWN_KEYS, nil)

	-- 2. Top-level type checks.
	check_types(opts, TOP_LEVEL_TYPES, nil)

	-- feedback_endpoint: boolean false OR a string URL.
	local fe = opts.feedback_endpoint
	if fe ~= nil and fe ~= false and type(fe) ~= "string" then
		error(
			("taskwarrior.nvim: setup key 'feedback_endpoint' must be false or a string, got %s"):format(
				type(fe)
			),
			0
		)
	end

	-- 3. Nested: delegate fields.
	if opts.delegate ~= nil then
		check_unknown_keys(opts.delegate, KNOWN_DELEGATE_KEYS, "delegate")
		check_types(opts.delegate, DELEGATE_TYPES, "delegate")
	end

	-- 4. Nested: filters — each entry must be a table.
	if opts.filters ~= nil then
		for i, entry in ipairs(opts.filters) do
			if type(entry) ~= "table" then
				error(
					("taskwarrior.nvim: filters[%d] must be a table, got %s"):format(i, type(entry)),
					0
				)
			end
		end
	end

	-- 5. Nested: projects — values must be strings (legacy form) or tables
	--    with { name, view?, filter?, sort? } keys (extended form).
	if opts.projects ~= nil then
		local PROJECT_ENTRY_KEYS = {
			name = "string", view = "string", filter = "string", sort = "string",
		}
		for path, proj in pairs(opts.projects) do
			if type(proj) == "string" then
				-- legacy form — always valid
			elseif type(proj) == "table" then
				for k, v in pairs(proj) do
					local expected = PROJECT_ENTRY_KEYS[k]
					if not expected then
						error(
							("taskwarrior.nvim: projects['%s'].%s is not a recognized key"):format(
								tostring(path), tostring(k)
							),
							0
						)
					end
					if type(v) ~= expected then
						error(
							("taskwarrior.nvim: projects['%s'].%s must be a %s, got %s"):format(
								tostring(path), tostring(k), expected, type(v)
							),
							0
						)
					end
				end
			else
				error(
					("taskwarrior.nvim: projects['%s'] must be a string or table, got %s"):format(
						tostring(path), type(proj)
					),
					0
				)
			end
		end
	end

	-- 6. Nested: urgency_coefficients — values must be numbers.
	if opts.urgency_coefficients ~= nil then
		for field, coeff in pairs(opts.urgency_coefficients) do
			if type(coeff) ~= "number" then
				error(
					("taskwarrior.nvim: urgency_coefficients['%s'] must be a number, got %s"):format(
						tostring(field), type(coeff)
					),
					0
				)
			end
		end
	end

	-- 7. Nested: urgency_value_mappers — values must be functions.
	if opts.urgency_value_mappers ~= nil then
		for field, fn in pairs(opts.urgency_value_mappers) do
			if type(fn) ~= "function" then
				error(
					("taskwarrior.nvim: urgency_value_mappers['%s'] must be a function, got %s"):format(
						tostring(field), type(fn)
					),
					0
				)
			end
		end
	end

	-- 8. Nested: tag_colors — values must be a string (highlight group) or
	--    a table (spec passed to nvim_set_hl).
	if opts.tag_colors ~= nil then
		for tag, val in pairs(opts.tag_colors) do
			if type(val) ~= "string" and type(val) ~= "table" then
				error(
					("taskwarrior.nvim: tag_colors['%s'] must be a string or table, got %s"):format(
						tostring(tag), type(val)
					),
					0
				)
			end
		end
	end

	-- 9. Nested: urgency_colors — list of { threshold = number, hl = string|table }.
	if opts.urgency_colors ~= nil then
		for i, entry in ipairs(opts.urgency_colors) do
			if type(entry) ~= "table" then
				error(
					("taskwarrior.nvim: urgency_colors[%d] must be a table, got %s"):format(
						i, type(entry)
					),
					0
				)
			end
			if type(entry.threshold) ~= "number" then
				error(
					("taskwarrior.nvim: urgency_colors[%d].threshold must be a number"):format(i),
					0
				)
			end
			if type(entry.hl) ~= "string" and type(entry.hl) ~= "table" then
				error(
					("taskwarrior.nvim: urgency_colors[%d].hl must be a string or table"):format(i),
					0
				)
			end
		end
	end

	-- 10. Nested: notifications — values must be booleans.
	if opts.notifications ~= nil then
		for cat, val in pairs(opts.notifications) do
			if type(val) ~= "boolean" then
				error(
					("taskwarrior.nvim: notifications['%s'] must be a boolean, got %s"):format(
						tostring(cat), type(val)
					),
					0
				)
			end
		end
	end

	-- 11. Nested: granulation sub-keys.
	if opts.granulation ~= nil then
		local gkeys = { enabled = "boolean", idle_ms = "number", notify_on_stop = "boolean" }
		for k, v in pairs(opts.granulation) do
			local expected = gkeys[k]
			if not expected then
				error(
					("taskwarrior.nvim: unknown setup key 'granulation.%s'"):format(k),
					0
				)
			end
			if type(v) ~= expected then
				error(
					("taskwarrior.nvim: setup key 'granulation.%s' must be a %s, got %s"):format(
						k, expected, type(v)
					),
					0
				)
			end
		end
	end

	-- 12. Nested: header_stats — list of functions, or empty list.
	if opts.header_stats ~= nil then
		for i, fn in ipairs(opts.header_stats) do
			if type(fn) ~= "function" then
				error(
					("taskwarrior.nvim: header_stats[%d] must be a function, got %s"):format(
						i, type(fn)
					),
					0
				)
			end
		end
	end

	-- 13. Icons: boolean, nil (auto), false (force ASCII), or partial override table.
	if opts.icons ~= nil then
		local t = type(opts.icons)
		if t ~= "boolean" and t ~= "table" then
			error(
				("taskwarrior.nvim: setup key 'icons' must be a boolean or table, got %s"):format(t),
				0
			)
		end
		if t == "table" then
			for k, v in pairs(opts.icons) do
				if type(v) ~= "string" then
					error(
						("taskwarrior.nvim: icons['%s'] must be a string, got %s"):format(
							tostring(k), type(v)
						),
						0
					)
				end
			end
		end
	end
end

return M
