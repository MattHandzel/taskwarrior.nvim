# Asset: demo/assets/personal-test.png
# Purpose: SMOKE TEST — render one asset using the user's personal nvim
#          config (~/.config/nvim/init.lua) instead of demo-init.lua, so
#          we can see whether the personal look is acceptable for the
#          launch video before re-pointing all 12 tapes.
# Notes:
#   - Personal config loads taskwarrior.nvim from ~/Projects/task.nvim (lazy.nvim local
#     dir spec). My uncommitted edits will appear.
#   - Personal config uses lazy.nvim → first-startup may install plugins
#     (slow). Bigger sleep after launch to let the dashboard settle.
#   - TASKRC/TASKDATA still pinned to /tmp/task-nvim-demo so this can't
#     leak the user's real task data.

Output "demo/assets/personal-test.gif"

Require nvim
Require task

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 16
Set Width 1280
Set Height 720
Set Padding 30

Env TASKRC "/tmp/task-nvim-demo/.taskrc-demo"
Env TASKDATA "/tmp/task-nvim-demo/.task-demo"

Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 2s
# Use personal init.lua. Bigger initial sleep — lazy.nvim plugins take longer
# to settle than the minimal demo-init.
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u /home/matth/.config/nvim/init.lua"
Enter
Sleep 5s
# If a dashboard / alpha buffer caught focus, :Task will replace it.
Type ":Task"
Enter
Sleep 2500ms
Show
Sleep 500ms
Screenshot "demo/assets/personal-test.png"
