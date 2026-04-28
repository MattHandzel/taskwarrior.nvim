-- taskwarrior/icons.lua — centralized glyph/icon resolution.
--
-- Single source of truth for every icon the plugin renders. Resolves in
-- priority order:
--
--   1. Explicit `config.options.icons[slot]` user override (string).
--   2. Nerd-font glyph if `vim.g.have_nerd_font` is truthy OR the user
--      passed `icons = {}` (any non-false value opts into auto-detect).
--   3. ASCII fallback — always safe, width-stable, SSH / tmux friendly.
--
-- Setting `config.options.icons = false` forces the full ASCII set even
-- when the user has a nerd-font terminal. This is the accessibility path.

local M = {}

-- Slot table. Each entry is { nf = <NF glyph>, ascii = <fallback> }.
-- Adding a slot: pick an NF codepoint from https://www.nerdfonts.com/cheat-sheet
-- and a 1-3 char ASCII stand-in. Do NOT use emoji — their width is
-- font-dependent and they corrupt alignment in terminals.
M.slots = {
  -- Checkbox states
  checkbox_pending  = { nf = "󰄱",  ascii = "[ ]" },    -- nf-fa-square_o
  checkbox_started  = { nf = "󰐊",  ascii = "[>]" },    -- nf-fa-play
  checkbox_done     = { nf = "󰸞",  ascii = "[x]" },    -- nf-fa-check_square
  checkbox_blocked  = { nf = "󰏥",  ascii = "[-]" },    -- nf-md-pause_circle

  -- Priority glyphs (for sign column). ASCII is the literal TW value.
  priority_h = { nf = "󰜷", ascii = "H" },              -- nf-md-chevron_triple_up
  priority_m = { nf = "󰅃", ascii = "M" },              -- nf-md-chevron_double_up
  priority_l = { nf = "󰅀", ascii = "L" },              -- nf-md-chevron_down

  -- Status glyphs (for sign column slot 2)
  status_started  = { nf = "󰐊", ascii = ">" },          -- nf-md-play
  status_overdue  = { nf = "󰨱", ascii = "!" },          -- nf-md-calendar_alert
  status_note     = { nf = "󰋑", ascii = "*" },          -- nf-md-comment_text_outline
  status_blocked  = { nf = "󱃋", ascii = "@" },          -- nf-md-link_lock

  -- Field chips (for inline/EOL virt-text)
  project = { nf = "", ascii = "" },                  -- nf-oct-project
  tag     = { nf = "", ascii = "#" },                 -- nf-fa-tag
  recur   = { nf = "󰑖", ascii = "~" },                  -- nf-md-repeat
  wait    = { nf = "󰅐", ascii = "w" },                  -- nf-md-clock_outline
  effort  = { nf = "󰝓", ascii = "~" },                  -- nf-md-timer_sand
  depends = { nf = "󱃋", ascii = "@" },                  -- nf-md-link_lock

  -- Date variants (used in right-align virt-text)
  due_normal  = { nf = "󰃁", ascii = "due" },            -- nf-md-calendar_clock
  due_today   = { nf = "󰻘", ascii = "!today" },         -- nf-md-calendar_today
  due_overdue = { nf = "󰨱", ascii = "!OVERDUE" },       -- nf-md-calendar_alert
  scheduled   = { nf = "󱖀", ascii = "sched" },          -- nf-md-calendar_arrow_right

  -- Urgency bar glyphs (8 bands)
  urg_1 = { nf = "▁", ascii = "." },
  urg_2 = { nf = "▂", ascii = "." },
  urg_3 = { nf = "▃", ascii = "-" },
  urg_4 = { nf = "▄", ascii = "-" },
  urg_5 = { nf = "▅", ascii = "+" },
  urg_6 = { nf = "▆", ascii = "+" },
  urg_7 = { nf = "▇", ascii = "*" },
  urg_8 = { nf = "█", ascii = "*" },

  -- Overdue badge (right-align pill)
  badge_overdue = { nf = "!OVERDUE", ascii = "!OVERDUE" },
}

-- Resolve a single slot name to its glyph, honoring user overrides
-- and nerd-font availability.
--
-- Accepted forms for `config.options.icons`:
--   true  | nil  — use nerd-font glyphs (default; matches the
--                   "use nerd font icons" wording on the config option)
--   false        — force ASCII (accessibility path)
--   "auto"       — detect: NF if vim.g.have_nerd_font is truthy, else ASCII
--   table        — partial override; unspecified slots fall through to
--                   the same default-NF behavior as `true`
function M.get(slot_name)
  local config = require("taskwarrior.config")
  local user = config.options.icons

  -- Forced ASCII
  if user == false then
    local slot = M.slots[slot_name]
    return slot and slot.ascii or ""
  end

  -- Explicit user override (string)
  if type(user) == "table" and user[slot_name] then
    return user[slot_name]
  end

  local slot = M.slots[slot_name]
  if not slot then return "" end

  -- Detection mode: only when explicitly requested via `icons = "auto"`.
  if user == "auto" then
    if vim.g.have_nerd_font then return slot.nf end
    return slot.ascii
  end

  -- Default (`true`, `nil`, or table-without-this-slot): emit the NF
  -- glyph. Users on terminals without a nerd-font set `icons = false`.
  return slot.nf
end

-- Return the full {name → glyph} resolved map, for display in :TaskHelp
-- and the health check.
function M.resolved_table()
  local out = {}
  for name in pairs(M.slots) do out[name] = M.get(name) end
  return out
end

-- Map a numeric urgency to its bar-glyph slot name (urg_1..urg_8).
-- Bands: 0-2, 2-4, 4-6, 6-8, 8-10, 10-12, 12-15, 15+.
function M.urgency_bar_slot(urgency)
  if not urgency then return nil end
  if urgency >= 15 then return "urg_8"
  elseif urgency >= 12 then return "urg_7"
  elseif urgency >= 10 then return "urg_6"
  elseif urgency >=  8 then return "urg_5"
  elseif urgency >=  6 then return "urg_4"
  elseif urgency >=  4 then return "urg_3"
  elseif urgency >=  2 then return "urg_2"
  else                      return "urg_1" end
end

return M
