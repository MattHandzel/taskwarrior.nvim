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

Hide
Type "bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 500ms
Show

Sleep 2s

# Start in a random code buffer — NOT a task buffer. This is the point.
Type "nvim -u demo/sources/demo-init.lua bin/taskmd"
Sleep 800ms
Enter
Sleep 2500ms

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
