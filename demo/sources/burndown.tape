# Asset: demo/assets/burndown.png
# Purpose: README "Visualize" section — show the ASCII burndown chart
# Capture mode: single-frame PNG (chart doesn't animate)
#
# Privacy: TASKRC + TASKDATA are pinned to the demo db via both VHS Env and
# inline shell exports. The `:only` after `:TaskBurndown` drops the auto-opened
# :Task split so the burndown is the only pane in the screenshot.

Output "demo/assets/burndown.gif"

Require nvim
Require task

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 16
Set Width 1100
Set Height 720
Set Padding 30

Env TASKRC "/tmp/task-nvim-demo/.taskrc-demo"
Env TASKDATA "/tmp/task-nvim-demo/.task-demo"

Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-views.sh && clear"
Enter
Sleep 2s
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua"
Enter
Sleep 2s
Type ":TaskBurndown"
Enter
Sleep 800ms
Ctrl+w
Type "o"
Sleep 500ms
Show
Sleep 300ms
Screenshot "demo/assets/burndown.png"
