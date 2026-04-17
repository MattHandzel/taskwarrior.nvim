# GIF purpose: Show quick-capture — add a task from ANY buffer in one keystroke
# Story beat: Open some code → <leader>ta → type a task → enter → back to code
# Target platform: r/neovim post, tweet thread tweet #2
# Length target: ~14s

Output demo/assets/quick-capture.gif

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

# Seed the demo db AND open a code buffer — hidden so the GIF starts in code,
# not on a shell prompt typing the launch command.
Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 500ms
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua bin/taskmd"
Enter
Sleep 2500ms
Show

Sleep 2s

# Navigate to a real function
Type "gg"
Sleep 400ms
Type "/def cmd_render"
Sleep 600ms
Enter
Sleep 1500ms

# Quick-capture from a code buffer
Type " ta"
Sleep 1500ms

# Type a realistic task with inline metadata
Type "Add --json flag to taskmd render project:work.api priority:H"
Sleep 2500ms
Enter

# Show "added" notification (it'll appear briefly)
Sleep 2s

# Now flip to the task buffer to prove it landed there
Type ":Task"
Sleep 800ms
Enter
Sleep 3s
