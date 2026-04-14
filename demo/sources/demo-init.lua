-- Minimal, opinionated init.lua for task.nvim demo recordings.
-- Keeps the plugin surface visible with no distractions: no plugin manager,
-- no statusline clutter, no telescope popups, just task.nvim + basic colors.

vim.opt.termguicolors = true
vim.opt.number = false
vim.opt.relativenumber = false
vim.opt.signcolumn = "no"
vim.opt.laststatus = 0
vim.opt.showcmd = false
vim.opt.showmode = false
vim.opt.ruler = false
vim.opt.cmdheight = 1
vim.opt.cursorline = false
vim.opt.fillchars = { eob = " " }
vim.opt.shortmess:append("I")
vim.opt.updatetime = 100
vim.opt.wrap = false
vim.opt.sidescrolloff = 8

-- Resolve the plugin directory from the script path
local this = debug.getinfo(1, "S").source:sub(2)
local demo_dir = vim.fn.fnamemodify(this, ":h")
local plugin_dir = vim.fn.fnamemodify(demo_dir, ":h:h")
vim.opt.runtimepath:prepend(plugin_dir)

-- Leader before setup so <leader>ta binding takes effect
vim.g.mapleader = " "

require("task").setup({
  confirm = false, -- auto-apply so the demo doesn't stall on a dialog
  sort = "urgency-",
  group = nil,
})

-- Only auto-open :Task if no file was given on the command line. The hero
-- and filter-group demos launch with no file and want the instant task view;
-- the quick-capture demo launches with a source file and wants to stay there.
if vim.fn.argc() == 0 then
  vim.schedule(function()
    pcall(vim.cmd, "Task")
  end)
end
