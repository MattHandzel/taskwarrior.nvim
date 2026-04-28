-- tests/e2e/minimal_init.lua — like tests/lua/minimal_init.lua but without
-- hardcoded assumptions. The e2e runner sets TASKRC / TASKDATA before nvim
-- starts so every `task` invocation from inside nvim is isolated.

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
vim.opt.runtimepath:prepend(repo_root)
vim.opt.runtimepath:prepend(repo_root .. "/tests/lua/.deps/plenary.nvim")
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
require("plenary")
