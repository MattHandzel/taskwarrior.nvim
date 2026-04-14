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

Hide
Type "bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 500ms
Show

# Start on the all-tasks view
Sleep 2s
Type "nvim -u demo/sources/demo-init.lua"
Sleep 600ms
Enter
Sleep 3s

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
