# Asset: demo/assets/review.gif
# Purpose: README "Power user" — :TaskReview guided walk through urgent tasks
# Length target: ~12s

Output "demo/assets/review.gif"

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

Sleep 1500ms

# Start guided review — walks urgent tasks one at a time
Type ":TaskReview"
Enter
Sleep 2500ms

# Keep this one as-is
Type "k"
Sleep 2000ms

# Defer the next
Type "d"
Sleep 2000ms

# Keep the third
Type "k"
Sleep 2000ms

# Quit the review session
Type "q"
Sleep 2000ms
