Output demo/demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1000
Set Height 600
Set Theme "Catppuccin Mocha"
Set Padding 20

# Setup: create isolated Taskwarrior environment
Hide
Type "export TASKDATA=$(mktemp -d) && export TASKRC=$(mktemp) && echo 'data.location='$TASKDATA > $TASKRC"
Enter
Sleep 0.5
Type "task rc.confirmation=off add 'Fix authentication bug' project:Backend priority:H due:2026-04-01 +security +urgent"
Enter
Sleep 0.3
Type "task rc.confirmation=off add 'Write API documentation' project:Backend +docs"
Enter
Sleep 0.3
Type "task rc.confirmation=off add 'Design landing page' project:Frontend priority:M due:2026-04-15 +design"
Enter
Sleep 0.3
Type "task rc.confirmation=off add 'Set up CI/CD pipeline' project:DevOps +infra"
Enter
Sleep 0.3
Type "task rc.confirmation=off add 'Review pull requests' project:Backend +review"
Enter
Sleep 0.3
Type "task rc.confirmation=off add 'Update dependencies' project:Frontend priority:L +maintenance"
Enter
Sleep 0.3
Type "clear"
Enter
Sleep 0.5
Show

# Demo starts
Sleep 1

Type "# task.nvim — Edit Taskwarrior tasks as markdown"
Enter
Sleep 1.5

Type "# First, let's see our tasks rendered as markdown:"
Enter
Sleep 1

Type "python3 bin/taskmd render status:pending --sort=priority-"
Enter
Sleep 3

Type "# Group by project:"
Enter
Sleep 1

Type "python3 bin/taskmd render status:pending --group=project --sort=priority-"
Enter
Sleep 3

Type "# Now let's edit tasks. Save to a file, make changes, apply:"
Enter
Sleep 1

Type "python3 bin/taskmd render status:pending > /tmp/tasks.md"
Enter
Sleep 1

Type "cat /tmp/tasks.md"
Enter
Sleep 2

Type "# Complete 'Fix authentication bug' by changing [ ] to [x]"
Enter
Sleep 1

Type "sed -i 's/- \[ \] Fix authentication bug/- [x] Fix authentication bug/' /tmp/tasks.md"
Enter
Sleep 0.5

Type "# Change priority of 'Design landing page' from M to H"
Enter
Sleep 1

Type "sed -i 's/Design landing page project:Frontend priority:M/Design landing page project:Frontend priority:H/' /tmp/tasks.md"
Enter
Sleep 0.5

Type "# Add a new task"
Enter
Sleep 1

Type "echo '- [ ] Write unit tests project:Backend +testing priority:H' >> /tmp/tasks.md"
Enter
Sleep 0.5

Type "# Preview what will change (dry run):"
Enter
Sleep 1

Type "python3 bin/taskmd apply /tmp/tasks.md --dry-run 2>&1 | python3 -m json.tool"
Enter
Sleep 4

Type "# Apply the changes:"
Enter
Sleep 1

Type "python3 bin/taskmd apply /tmp/tasks.md"
Enter
Sleep 2

Type "# Verify — the bug is done, priority changed, new task added:"
Enter
Sleep 1

Type "task status:pending list"
Enter
Sleep 3

Sleep 2
