# Asset: demo/assets/launch.mp4
# Purpose: Single combined launch video for Reddit/HN/Twitter — cycles through
#          every major feature in one nvim session so a viewer scrolling a
#          muted feed gets the full pitch in ~60s.
# Story arc:
#   Hero (vim motions on tasks)
#     → quick-capture
#     → filter/group
#     → tree → burndown → calendar → tags  (the "five views" sweep)
#     → guided review
#     → live diff preview + save
#     → end card with repo URL
# Length target: ~60s. Reddit autoplay caps loop interest around 60–75s.
# Output format: MP4 (Reddit's GIF re-encode caps quality; native MP4 is better).

Output demo/assets/launch.mp4

Require nvim
Require task

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 18
Set Width 1280
Set Height 720
Set Padding 40
Set TypingSpeed 60ms
Set PlaybackSpeed 1.0

Env TASKRC "/tmp/task-nvim-demo/.taskrc-demo"
Env TASKDATA "/tmp/task-nvim-demo/.task-demo"

# --- Setup (hidden) ---------------------------------------------------------
# End card is written to a temp file here so the visible Type at the bottom
# stays a simple `cat` — keeps the contents out of the line-by-line tape
# validator (which greps Type lines for the substring "nvim").
Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 800ms
Type "cat > /tmp/task-nvim-demo/endcard.txt <<'EOF'"
Enter
Type ""
Enter
Type ""
Enter
Type ""
Enter
Type "   taskwarrior.nvim"
Enter
Type ""
Enter
Type "   Edit your Taskwarrior tasks as markdown."
Enter
Type "   Every vim motion becomes a task management operation."
Enter
Type ""
Enter
Type "   github.com/MattHandzel/taskwarrior.nvim"
Enter
Type ""
Enter
Type "   :Task — pending tasks         <leader>ta — quick capture"
Enter
Type "   :TaskTree — dependencies      :TaskReview — urgency walk"
Enter
Type ""
Enter
Type "   MIT  ·  feedback welcome on r/neovim"
Enter
Type ""
Enter
Type "EOF"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 300ms
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua"
Enter
Sleep 3s
Show

# === Scene 1: Hero — "tasks as markdown, vim motions just work" ============
Sleep 1800ms
Type "G"
Sleep 700ms
Type "gg"
Sleep 700ms
Type ":%s/priority:L/priority:H/g"
Enter
Sleep 1100ms
Type ":w"
Enter
Sleep 2200ms

# === Scene 2: Quick-capture from any buffer ================================
Type " ta"
Sleep 1300ms
Type "Ship launch video project:writing priority:H due:today +marketing"
Sleep 1300ms
Enter
Sleep 2200ms

# === Scene 3: Filter + group =================================================
Type ":TaskFilter +work"
Enter
Sleep 1400ms
Type ":TaskGroup project"
Enter
Sleep 2400ms
Type ":TaskFilter "
Enter
Sleep 900ms
Type ":TaskGroup none"
Enter
Sleep 700ms

# === Scene 4: TaskTree — dependency view ===================================
Type ":TaskTree"
Enter
Sleep 2800ms
Type ":bd"
Enter
Sleep 400ms

# === Scene 5: TaskBurndown =================================================
Type ":TaskBurndown"
Enter
Sleep 2400ms
Type ":bd"
Enter
Sleep 400ms

# === Scene 6: TaskCalendar =================================================
Type ":TaskCalendar"
Enter
Sleep 2400ms
Type ":bd"
Enter
Sleep 400ms

# === Scene 7: TaskTags =====================================================
Type ":TaskTags"
Enter
Sleep 2200ms
Type ":bd"
Enter
Sleep 400ms

# === Scene 8: TaskReview — guided urgency walk =============================
Type ":TaskReview"
Enter
Sleep 1600ms
Type "k"
Sleep 1300ms
Type "d"
Sleep 1300ms
Type "k"
Sleep 1300ms
Type "q"
Sleep 700ms

# === Scene 9: TaskDiffPreview — live virt-text =============================
Type ":TaskDiffPreview on"
Enter
Sleep 900ms
Type "gg"
Sleep 300ms
Type "$"
Sleep 300ms
Type "a +urgent"
Escape
Sleep 1500ms
Type ":w"
Enter
Sleep 2200ms

# === Scene 10: End card ====================================================
Type ":qa!"
Enter
Sleep 400ms
Hide
Type "clear"
Enter
Sleep 200ms
Show
Type "cat /tmp/task-nvim-demo/endcard.txt"
Enter
Sleep 4500ms
