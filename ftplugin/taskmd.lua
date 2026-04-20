-- Filetype plugin for the taskwarrior.nvim markdown rendering.
-- Idempotent: harmless if loaded multiple times or from a non-task buffer.

vim.bo.commentstring = "<!-- %s -->"

-- UUID comments are visually noisy; the main plugin sets conceallevel but
-- browsing a saved taskmd file outside the plugin benefits from the same.
vim.wo.conceallevel = 2
vim.wo.concealcursor = "nc"
