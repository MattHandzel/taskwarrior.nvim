# Asset: demo/assets/summary.png
# Purpose: README "Visualize" — show project summary (:TaskSummary)

Output "demo/assets/summary.gif"

Require nvim
Require task

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 16
Set Width 1200
Set Height 600
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
Type ":TaskSummary"
Enter
Sleep 800ms
Ctrl+w
Type "o"
Sleep 500ms
Show
Sleep 300ms
Screenshot "demo/assets/summary.png"
