# GIF purpose: Show filtering and grouping — two features the README mentions explicitly
# Story beat: Start unfiltered → filter to a project → group by project → regroup by tag → sort by due date
# Target platform: README "Features" section, r/taskwarrior post
# Length target: ~22s

Output demo/assets/filter-group.gif

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

# Seed the demo db AND launch nvim — hidden so the GIF starts on the rendered buffer.
Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 500ms
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua"
Enter
Sleep 3s
Show

# Start on the all-tasks view
Sleep 2s

# Filter to a single project
Type ":TaskFilter project:work.api"
Sleep 1200ms
Enter
Sleep 2500ms

# Widen filter to all work tasks
Type ":TaskFilter project.startswith:work"
Sleep 1200ms
Enter
Sleep 2500ms

# Now group by project
Type ":TaskGroup project"
Sleep 1200ms
Enter
Sleep 3s

# Resort within groups by due date
Type ":TaskSort due+"
Sleep 1200ms
Enter
Sleep 3s

# Clear group, go back to flat urgency sort (money shot: cycles back)
Type ":TaskGroup none"
Sleep 1000ms
Enter
Sleep 500ms
Type ":TaskSort urgency-"
Sleep 1000ms
Enter

# Hold final state
Sleep 3s
