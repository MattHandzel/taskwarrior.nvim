# task.nvim

Edit your Taskwarrior tasks as markdown. Inspired by oil.nvim.

![demo](assets/demo.gif)

## Features

- View tasks as markdown checkboxes
- Complete tasks by checking boxes
- Add tasks by typing new lines
- Edit metadata inline (project, tags, priority, due dates)
- Any Taskwarrior filter works
- Bulk edit with vim motions, macros, visual select + `:s`
- Undo saves with `:TaskUndo`
- Group by field, sort by field
- Autocomplete field names, projects, tags
- Confirmation dialog before applying changes
- CLI tool for scripting and automation

## Requirements

- Neovim >= 0.9
- Taskwarrior >= 2.6
- Python >= 3.8

## Installation

```lua
{
  "matthandzel/task.nvim",
  config = function()
    require("task").setup()
  end,
}
```

The plugin automatically finds `bin/taskmd` from its install directory. Alternatively, add `bin/` to your PATH.

## Quick Start

```
:Task                          -- view all pending tasks
:Task project:Work +urgent     -- filter tasks
```

Edit any line. `:w` to sync. That's it.

## Commands

| Command | Description |
|---------|-------------|
| `:Task [filter]` | Open task buffer with optional filter |
| `:TaskFilter [filter]` | Change filter on current buffer |
| `:TaskRefresh` | Reload from Taskwarrior |
| `:TaskUndo` | Reverse last save's changes |
| `:TaskHelp` | Show all commands, keybindings, syntax |

## Keybindings (buffer-local)

| Key | Action |
|-----|--------|
| `<CR>` | Toggle task complete/pending |
| `o` | New task below |
| `O` | New task above |
| `dd` | Delete task (marks done on save) |
| `yy` + `p` | Duplicate task |
| `ga` | Add annotation |
| `gf` | View annotations |

## Metadata Syntax

Tasks use Taskwarrior-native syntax after the description:

```
- [ ] Fix login bug project:Work priority:H due:2026-04-01 +urgent +backend
```

Available fields: `project:`, `priority:` (H/M/L), `due:`, `scheduled:`, `recur:`, `wait:`, `until:`, `effort:`

Tags: `+tagname`

## Configuration

```lua
require("task").setup({
  on_delete = "done",      -- "done" or "delete" when lines are removed
  confirm = true,          -- show confirmation dialog before applying
  sort = "urgency-",       -- default sort (field+/field- for asc/desc)
  group = nil,             -- default group field (e.g., "project")
  fields = nil,            -- fields to show (nil = all present)
})
```

## How It Works

1. `:Task` renders Taskwarrior tasks as markdown via `bin/taskmd render`
2. You edit the buffer with standard vim operations
3. On `:w`, the plugin diffs your edits against Taskwarrior state
4. A confirmation dialog shows what will change
5. Changes are applied via Taskwarrior commands
6. The buffer re-renders from Taskwarrior truth

Task identity is tracked via concealed HTML comments (`<!-- uuid:ab05fb51 -->`), invisible in the buffer but preserved through edits.

## CLI Usage

The bundled `taskmd` CLI works standalone for scripting:

```bash
taskmd render project:Inbox --sort=due+     # markdown to stdout
taskmd render --group=project               # grouped view
taskmd apply tasks.md                        # sync edits back
taskmd apply tasks.md --dry-run             # preview changes
taskmd completions                           # JSON for editors
```

## Contributing

PRs welcome. Run tests with `python3 -m pytest tests/ -v`.

## License

MIT
