-- minimal_init.lua — minimal neovim init for running plenary tests headlessly.
-- Sets up runtimepath to include:
--   1. The repo root (so `require('taskwarrior.taskmd')` etc. work)
--   2. plenary.nvim from the vendored/cached clone at tests/lua/.deps/plenary.nvim

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

vim.opt.runtimepath:prepend(repo_root)
vim.opt.runtimepath:prepend(repo_root .. "/tests/lua/.deps/plenary.nvim")

-- Disable swapfiles / shada so headless runs stay clean.
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- Load plenary now so its busted shim is available.
require("plenary")
