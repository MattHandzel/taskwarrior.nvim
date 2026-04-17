# Asset: demo/assets/diff-preview.gif
# Purpose: README "Power user" — live diff-preview virtual text as user edits
# Length target: ~14s

Output "demo/assets/diff-preview.gif"

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

# Enable live diff preview
Type ":TaskDiffPreview on"
Enter
Sleep 1500ms

# Find a task and bump its priority
Type "/priority:M"
Enter
Sleep 1000ms
Type "fM"
Sleep 500ms
Type "rH"
Sleep 1500ms

# Wait for the 400ms debounce + virt_text to render
Sleep 1500ms

# Add a brand new task line
Type "o"
Type "- [ ] Add --json flag to taskmd render project:work.api priority:H"
Sleep 1500ms
Escape
Sleep 1500ms

# Wait for the ADD virt_text to appear
Sleep 1500ms
