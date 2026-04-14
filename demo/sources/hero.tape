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

# Seed the demo taskwarrior db (silent)
Hide
Type "bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 500ms
Show

# Entry pause — viewer reads the empty prompt
Sleep 2s

# The aha moment: open the task buffer
Type "nvim -u demo/sources/demo-init.lua"
Sleep 800ms
Enter

# Let task.nvim render + paint highlights
Sleep 3s

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

# Save — task.nvim diffs against Taskwarrior and applies
Type ":w"
Sleep 800ms
Enter

# Money shot: the re-rendered buffer with promoted tasks at the top
Sleep 3s
