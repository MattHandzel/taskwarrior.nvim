-- Deprecation shim — task.nvim was renamed to taskwarrior.nvim in v1.3.0.
-- Forwards to taskwarrior.delegate. Slated for removal in v1.5.
return require("taskwarrior.delegate")
