# Asset: demo/assets/delegate.gif
# Purpose: README "Power user" — :TaskDelegate popup form (no actual claude spawn)
# Length target: ~10s

Output "demo/assets/delegate.gif"

Require nvim
Require task

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 18
Set Width 1280
Set Height 720
Set Padding 40
Set TypingSpeed 70ms

Env TASKRC "/tmp/task-nvim-demo/.taskrc-demo"
Env TASKDATA "/tmp/task-nvim-demo/.task-demo"

Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-views.sh && clear"
Enter
Sleep 1500ms
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua"
Enter
Sleep 2500ms
Show

Sleep 1000ms

# Move to a task we want to delegate
Type "/Document new"
Enter
Sleep 1500ms

# Open the delegate form
Type ":TaskDelegate"
Enter
Sleep 3500ms

# Dismiss without actually running claude
Escape
Sleep 800ms
Escape
Sleep 1500ms
