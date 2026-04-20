# GIF purpose: Show the one-line pitch — "editing tasks with vim motions"
# Story beat: Open task buffer → scan → bulk-edit 3 priorities with visual-mode substitute → save → watch them apply
# Target platform: README hero image, HN/Reddit top-of-post
# Length target: ~14s

Output demo/assets/hero.gif

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
Set PlaybackSpeed 1.0

Env TASKRC "/tmp/task-nvim-demo/.taskrc-demo"
Env TASKDATA "/tmp/task-nvim-demo/.task-demo"

# Seed the demo taskwarrior db AND launch nvim — hidden so the GIF starts
# directly on the rendered task buffer (no boilerplate typing).
Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 500ms
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua"
Enter
Sleep 3s
Show

# Entry pause — viewer reads the rendered buffer
Sleep 2s

# Scan the list — vim motion
Type "G"
Sleep 1500ms
Type "gg"
Sleep 1500ms

# Reorder a task down to showcase raw vim power on task lines
Type "j"
Sleep 500ms
Type "j"
Sleep 500ms

# The bulk-edit money shot: substitute priority:L → priority:H across whole buffer
Type ":%s/priority:L/priority:H/g"
Sleep 1500ms
Enter
Sleep 1200ms

# Save — taskwarrior.nvim diffs against Taskwarrior and applies
Type ":w"
Sleep 800ms
Enter

# Money shot: the re-rendered buffer with promoted tasks at the top
Sleep 3s
