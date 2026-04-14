# task.nvim

Edit your Taskwarrior tasks as markdown. Inspired by [oil.nvim](https://github.com/stevearc/oil.nvim).

![hero demo: bulk-edit priorities with a substitute, save, watch them apply](demo/assets/hero.gif)

## Why task.nvim?

Taskwarrior is powerful but editing tasks one-by-one with `task modify` is slow. task.nvim renders your tasks as markdown checkboxes in a neovim buffer. Every vim motion, macro, and visual-mode operation becomes a task management operation for free.

```
:Task                                   -- open all pending tasks
V20j:s/project:Inbox/project:career/    -- reassign 20 tasks
dd                                      -- mark task done
o                                       -- add new task inline
:w                                      -- sync all changes at once
```

### Filter and group on the fly

![filter and group demo](demo/assets/filter-group.gif)

`:TaskFilter project.startswith:work` narrows to a project. `:TaskGroup project` splits it into `## sections`. `:TaskSort due+` re-sorts within groups. None of this touches your Taskwarrior database — just the view.

### Quick-capture from any buffer

![quick capture demo](demo/assets/quick-capture.gif)

`<leader>ta` pops a floating window in any buffer. Type `Fix auth bug project:work priority:H`, press Enter, go back to what you were doing. The task is in Taskwarrior before your hand leaves the keyboard.

## Features

- **Edit as markdown** — tasks are checkboxes with inline metadata
- **Full vim power** — `dd`, `yy`+`p`, `:s/`, macros, visual mode all work
- **Dynamic highlighting** — priority colors, overdue dates in red, tag colors update as you type
- **Virtual text** — urgency scores and annotation counts shown inline
- **Quick-capture** — `<leader>ta` opens a floating window to add a task from anywhere
- **Recurring task collapsing** — only shows the next instance of recurring tasks
- **UDA auto-discovery** — custom fields (effort, utility, etc.) detected automatically
- **Confirmation dialog** — preview every change before it touches Taskwarrior
- **Undo** — `:TaskUndo` reverses the last save
- **CLI tool** — `bin/taskmd` works standalone for scripting and automation
- **TW2 and TW3 compatible** — uses stable Taskwarrior CLI interface

## Requirements

- Neovim >= 0.9
- Taskwarrior >= 2.6 (compatible with 3.x)
- Python >= 3.8

## Installation

```lua
-- lazy.nvim
{
  "matthandzel/task.nvim",
  config = function()
    require("task").setup()
  end,
}
```

## Quick Start

```
:Task                          -- view all pending tasks
:Task project:career +ais      -- filter tasks
:Task due.before:eow           -- tasks due this week
```

Edit any line. `:w` to sync. That's it.

## Commands

| Command | Description |
|---------|-------------|
| `:Task [filter]` | Open task buffer with optional Taskwarrior filter |
| `:TaskFilter [filter]` | Change filter on current buffer |
| `:TaskSort <spec>` | Change sort order (e.g. `due+`, `urgency-`, `priority-`) |
| `:TaskGroup [field]` | Change grouping (`project`, `tag`, or `none`) |
| `:TaskRefresh` | Reload from Taskwarrior |
| `:TaskAdd` | Quick-capture a task (floating window) |
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
| `gf` | View full task info |
| `<leader>ta` | Quick-capture (global, works from any buffer) |

## Metadata Syntax

Tasks use Taskwarrior-native syntax after the description:

```
- [ ] Fix login bug project:Work priority:H due:2026-04-01 +urgent +backend
```

**Fields:** `project:`, `priority:` (H/M/L), `due:`, `scheduled:`, `recur:`, `wait:`, `until:`, `effort:`

**Tags:** `+tagname` (supports hyphens: `+my-tag`)

**UDAs:** Custom fields are auto-discovered from your Taskwarrior config and included automatically.

## Configuration

```lua
require("task").setup({
  on_delete = "done",        -- "done" or "delete" when lines are removed
  confirm = true,            -- show confirmation dialog before applying
  sort = "urgency-",         -- default sort (field+ for asc, field- for desc)
  group = "project",         -- default group field (nil to disable)
  fields = nil,              -- fields to show (nil = all)
  capture_key = "<leader>ta", -- global keybind for quick capture (nil to disable)
})
```

## How It Works

1. `:Task` renders tasks as markdown via `bin/taskmd render`
2. You edit the buffer with standard vim operations
3. On `:w`, the plugin diffs your edits against Taskwarrior state
4. A confirmation dialog shows what will change
5. Changes are applied via Taskwarrior commands
6. The buffer re-renders from Taskwarrior truth

Task identity is tracked via concealed HTML comments (`<!-- uuid:ab05fb51 -->`), invisible in the buffer but preserved through edits.

## Health Check

Run `:checkhealth task` to verify your setup (neovim version, Taskwarrior, Python, data directory).

## CLI Usage

The bundled `taskmd` CLI works standalone for scripting:

```bash
taskmd render project:Inbox --sort=due+     # markdown to stdout
taskmd render --group=project               # grouped view
taskmd apply tasks.md                        # sync edits back
taskmd apply tasks.md --dry-run             # preview changes as JSON
taskmd completions                           # JSON for editor completion
```

## Comparison

| Feature | task.nvim | taskwiki | vim-taskwarrior |
|---------|-----------|----------|-----------------|
| Edit as markdown | Yes | Yes (vimwiki) | No |
| Neovim-native (extmarks, float) | Yes | No | No |
| Bulk edit with vim motions | Yes | Limited | No |
| UDA auto-discovery | Yes | No | Partial |
| Live dynamic highlighting | Yes | No | No |
| Quick-capture popup | Yes | No | No |
| Standalone CLI | Yes | No | No |
| TW3 compatible | Yes | Partial | No |
| Recurring task collapsing | Yes | No | No |
| Zero external dependencies | Yes (stdlib Python) | Requires vimwiki | N/A |

## Contributing

PRs welcome. Run tests:

```bash
python3 -m pytest tests/ -v
```

## License

MIT
