# Feature gap analysis — taskwarrior.nvim vs. the ecosystem

_Last updated: 2026-04-19. Scope: identify features in competing Neovim
Taskwarrior plugins (and adjacent task tooling) that taskwarrior.nvim
doesn't yet ship, and decide which to copy._

## Plugins surveyed

| Plugin | Stars | Approach | Last push |
|---|---|---|---|
| [ribelo/taskwarrior.nvim](https://github.com/ribelo/taskwarrior.nvim) | 128 | Telescope picker + per-project `.taskwarrior.json` + auto time-tracking | 2024-08 |
| [huantrinh1802/m_taskwarrior_d.nvim](https://github.com/huantrinh1802/m_taskwarrior_d.nvim) | 92 | Markdown buffer with embedded queries, nested checkboxes as dependencies | active |
| [duckdm/neowarrior.nvim](https://github.com/duckdm/neowarrior.nvim) | 44 | Dedicated buffer/float with named reports, per-cwd config, color breakpoints | active |
| [skbolton/neorg-taskwarrior](https://github.com/skbolton/neorg-taskwarrior) | 17 | Norg integration for Taskwarrior | active |
| [hugginsio/twig.nvim](https://github.com/hugginsio/twig.nvim) | 5 | Tiny statusline component | sparse |
| _(reference, non-Neovim)_ vit / taskwarrior-tui | n/a | Full-screen TUI with vim keybindings | active |
| _(reference)_ Obsidian Tasks plugin | n/a | Markdown-with-queries pattern in Obsidian | active |

---

## Tier 1 — Table-stakes parity (target: 1.3.x)

These are commodity features at least one well-known plugin ships and we
don't. Most are short-effort. None contradict our architecture.

### Interactive modify shortcuts

- [ ] **`MM` / `Mp` / `MP` / `MD` keymaps** — field-specific modify pickers in
      the task buffer (modify project, priority, due date) instead of the
      single `gm` "type the whole field" prompt.
      _Source:_ neowarrior.nvim. _Effort:_ S. _Why it matters:_ `gm` hides
      a free-form input where most users want a one-character "change due
      date" shortcut. Reduces friction for the most common edit verbs.

### Task-level operations we don't expose

- [ ] **`:TaskAppend` / `:TaskPrepend`** — append or prepend text to the
      description of the task under cursor without entering full modify
      flow. _Source:_ ribelo. _Effort:_ S. _Why:_ "added a blocker, want
      to note it inline" is a common loop; right now you have to `gm` and
      retype the description.
- [ ] **`:TaskDuplicate`** — copy the task under cursor into a new pending
      task with the same project/tags/due fields. _Source:_ ribelo (Task:duplicate).
      _Effort:_ S. _Why:_ recurring-but-not-recurring patterns (weekly
      one-offs, similar bug-fix subtasks) are a real pain point.
- [ ] **`:TaskPurge`** — `task purge` for deleted tasks (irreversibly drop
      from the database). _Source:_ ribelo. _Effort:_ XS. _Why:_ users who
      enable `on_delete = "delete"` accumulate tombstones; we currently
      have no way to clean them.
- [ ] **`:TaskDenotate`** — remove an annotation. We have `ga` for adding
      one and `gf` for viewing them, but no remove. _Source:_ ribelo.
      _Effort:_ S. _Why:_ asymmetry — once added, annotations are sticky.

### Telescope picker actions

We ship a Telescope picker but with only `<C-x>` (done) and `<C-s>`
(start/stop). ribelo's picker has six actions. Worth catching up:

- [ ] **`<C-d>`** delete from picker (current `<C-x>` is done; `<C-d>`
      should delete with confirm)
- [ ] **`<C-y>`** yank UUID
- [ ] **`<C-a>`** add task from inside the picker
- [ ] **`<C-c>`** custom `task <uuid> <command>` prompt
      _Effort:_ S each. _Why:_ once a Telescope user is in the picker,
      escape-then-:Task is more friction than a chord.

### Auto time-tracking nicety

- [ ] **`granulation` / auto-stop-on-idle** — after N ms of Neovim idle,
      auto-stop the active task and notify. Configurable threshold; off by
      default. _Source:_ ribelo. _Effort:_ S. _Why:_ left-running `task
      start` is a perennial taskwarrior complaint; auto-stop on focus
      lost / idle solves the "I forgot to stop the timer for 8 hours"
      bug. _Caveat:_ must be opt-in — users who deliberately track wall
      clock time will hate it.

### Per-cwd auto-load (extending what we have)

- [ ] **Auto-load saved view by cwd**. We already have `:TaskSave`/`:TaskLoad`
      and `:TaskProjectAdd`. Extend the project map so each entry can also
      carry a `view = "<saved-name>"` field; opening `:Task` from inside
      the directory then auto-loads that view. _Source:_ neowarrior's
      per-directory config. _Effort:_ S. _Why:_ "morning standup view"
      and "deep-work weekend view" are different — automating per cwd
      removes a manual `:TaskLoad` step.

### Tag color matching

- [ ] **`tag_colors = {["+urgent"] = "Red", ["+blocked"] = "DarkYellow", …}`**
      config knob. Today tags all render as `Type` highlight. _Source:_
      neowarrior. _Effort:_ S. _Why:_ visual scan — `+urgent` should
      pop, `+someday` should fade.

### Color breakpoints

- [ ] **Tunable urgency / due-date / priority color thresholds**. We
      hardcode "red ≥8, orange ≥4, green below" in views. Move to config:

      ```lua
      urgency_colors = {
        { threshold = 8, hl = "ErrorMsg" },
        { threshold = 4, hl = "WarningMsg" },
        { threshold = 0, hl = "Comment" },
      },
      ```

      _Source:_ neowarrior breakpoint system. _Effort:_ S. _Why:_ "8" is
      arbitrary; a user who sets `urgency.due.coefficient` differently
      wants different bands.

---

## Tier 2 — Distinguishing features (1.4+)

Worth doing but not blocking 1.3. Each requires a real design pass.

### Embedded query blocks in arbitrary markdown

- [ ] **`<!-- taskmd query: due.before:eow priority:H -->` block** that
      auto-renders matching tasks below it on save. The block is the
      anchor; the rendered tasks are scratch and re-rendered every refresh.
      _Source:_ m_taskwarrior_d.nvim's `$query{}` headers; Obsidian Tasks
      `dataview`-style queries. _Effort:_ M. _Why:_ "I want to embed my
      due-this-week list at the top of my project's `notes.md`". This is
      the killer feature that makes the markdown-as-interface model
      genuinely better than a dedicated buffer — every markdown file
      can host a live taskwarrior view.
- [ ] **Multiple query blocks per buffer**, each with its own filter, sort,
      and group. Edits in any block apply to its scope. _Effort:_ M.

### Nested checkboxes → dependencies

- [ ] **Indented `- [ ]` lines under a parent become `depends:` of the
      parent.** Today our parser treats all `- [ ]` lines as siblings at
      the same level. _Source:_ m_taskwarrior_d.nvim. _Effort:_ M (parser
      + diff + serialize all need to handle indentation as semantic).
      _Why:_ "fix bug" with three indented sub-steps is the most natural
      way to express a small project in markdown; right now you have to
      manually wire up `depends:`.
- [ ] **Auto-complete parent when all children done** — config-gated.
      _Effort:_ S after the above.

### Named reports (à la `task next`, `task active`)

- [ ] **`:TaskReport <name>`** with built-in reports mirroring Taskwarrior's
      `task <report>` namespace: `next`, `active`, `overdue`, `recurring`,
      `waiting`, `unblocked`, `ready`. Each report bundles a filter, sort,
      and column set. Configurable, with sensible defaults from `task show
      reports`. _Source:_ neowarrior (17 predefined reports), Taskwarrior
      itself. _Effort:_ M. _Why:_ this is the ONE area where Taskwarrior's
      own UX outshines ours — `task next` is what most CLI users live in.
      We should expose its semantics one-keystroke.

### Float window mode

- [ ] **`:Task float`** — render the task buffer in a centered floating
      window instead of a split. Useful for quick "glance and dismiss"
      reviews. _Source:_ neowarrior `:NeoWarriorOpen float`. _Effort:_ S
      (we already have border + capture-window code).

### Header info area

- [ ] **Conditional stats line** in the task buffer header: "5 due in
      2d · 3 H-priority · 12 active". Configurable formula per slot.
      _Source:_ neowarrior. _Effort:_ S. _Why:_ at-a-glance dashboard
      without leaving the buffer.

### Modify-pickers powered by `task _columns` / `task _udas`

- [ ] **`:TaskModifyField <field>`** that opens a Telescope-style picker
      with valid values for the field (e.g. existing projects for
      `project:`, existing tags for `+`). Today `gm` is a free-form input
      and you have to remember exact spellings. _Source:_ implicit gap.
      _Effort:_ M. _Why:_ typos in project names create silent
      orphan-projects nobody filters by.

### Task `info` floating pane

- [ ] **`gf` should pop a float**, not split. We currently `:enew`/`:read
      task <uuid> info`. A bordered float is less disruptive. _Effort:_
      S. _Source:_ neowarrior task-detail-float, ribelo's preview pane.

### Configurable notifications

- [ ] **`notifications = { start = true, stop = true, error = true,
      apply = true, … }`** config table to silence specific notify-spam.
      _Source:_ ribelo. _Effort:_ XS. _Why:_ apply notifications are
      noisy in heavy-edit sessions.

---

## Tier 3 — Differentiators / experimental

Things no surveyed competitor ships and that fit our markdown-buffer model.

### Task graph as Mermaid

- [ ] **`:TaskGraph`** — render `depends:` relationships as a Mermaid
      diagram in a markdown code-fence (so `iamcco/markdown-preview.nvim`
      or quarto can preview it visually). _Effort:_ M. _Why:_ our `:TaskTree`
      is ASCII; Mermaid handles cycles, multi-parent, and looks great in
      a published `notes.md`.

### Bulk visual-mode operations

- [ ] **`:'<,'>TaskBulkModify project:foo +bar`** — apply the same
      modify to every task in the visual selection. Today users can use
      `:s///g` for substitution, but native Taskwarrior bulk-edit
      semantics (e.g. add a tag without erasing existing tags) require
      the round-trip. _Effort:_ S. _Why:_ "tag every overdue task
      +triage" is one motion, today it's three.

### Inbox / GTD weekly-review mode

- [ ] **`:TaskInbox`** — a curated review of tasks added in the last N
      hours (default 24) with no project, no due, and no tags. Walks the
      user through them one by one, prompting: defer / set project /
      schedule / drop. Subtly different from `:TaskReview` (which walks
      by urgency). _Effort:_ M. _Why:_ Captures the "I dumped 30 ideas
      into Taskwarrior on Monday and need to triage them by Friday"
      ritual.

### Markdown export

- [ ] **`:TaskExport markdown <file>`** — write the current rendered
      buffer (with concealed UUIDs stripped) to a file readable by any
      markdown viewer. Round-trip via `:TaskImport markdown <file>` would
      let users compose tasks offline (e.g. on a phone) and sync later.
      _Effort:_ M. _Why:_ Taskwarrior's official sync is heavyweight;
      "edit a markdown file in Obsidian, then sync" is a real workflow.

### Statusline / Lualine component (already shipped — promote)

- [ ] **Document `lua/taskwarrior/statusline.lua` better** with copy-paste
      lualine and heirline snippets. The README mentions it but the
      example is one line. _Effort:_ XS docs.

### Optional sync wrapper

- [ ] **`:TaskSync`** — wrapper around `task sync` (Taskwarrior 3.x's
      native sync) that shows progress, parses errors, and offers a
      retry. _Source:_ Taskwarrior 3.x feature we don't expose. _Effort:_
      S. _Why:_ users on TW 3.x get sync from the CLI but no editor
      integration.

### Dashboard widget

- [ ] **dashboard.nvim / alpha-nvim section** — Lua snippet that returns
      the top-N urgent tasks for use as a startup dashboard widget.
      _Source:_ Praczet/little-taskwarrior.nvim is exactly this concept.
      _Effort:_ S. _Why:_ "what should I do right now" on `nvim`-only-no-args.

---

## Explicit non-goals

Patterns we deliberately do _not_ want to copy:

- **Re-implementing `task` in Lua.** ribelo's `taskwarrior.lua` is 34K
  bytes of CLI-shelling helpers and a Task class. Our pure-Lua backend
  (`lua/taskwarrior/taskmd.lua`) deliberately stays parser/diff/render
  only — _all_ writes go through `task <command>` to inherit Taskwarrior's
  recurrence engine, urgency formula, hooks, and undo log. Don't grow the
  Lua backend toward Task replication.
- **Custom JSON config files in the project root.** ribelo uses
  `.taskwarrior.json` per project; this is invisible state that breaks
  the "your taskwarrior database is the source of truth" model. Our
  cwd-to-project map lives in `stdpath("data")`, not in user repos.
- **Auto-creating tasks from regex matches in source files.**
  todo-comments.nvim solves this problem in a different domain
  (source-tree TODO/FIXME scanning); blending its semantics into a
  Taskwarrior plugin invites surprise (every `# TODO` line in code
  becomes a task you have to triage).
- **Web UI / browser extension.** Out of scope; if you want this,
  use Taskwarrior 3.x sync + a separate web client.
- **Telescope-as-primary-UI.** Our differentiator is _markdown buffers
  with vim motions_. The Telescope extension exists for "fuzzy-find one
  task and act" but should never grow into the main interface.

---

## Quick wins to land in 1.3.1 (≤2 days of work)

If we want a "1.3 was a polish release" follow-up that ships fast:

1. `:TaskAppend` / `:TaskPrepend` / `:TaskDuplicate` / `:TaskPurge` /
   `:TaskDenotate` — five new commands, all 5–10 lines each, all wrap
   `task <uuid> <verb>`. Add buffer keymaps `>>`, `<<`, `yt`, `dD`, `gA`
   respectively.
2. Telescope picker actions: `<C-d>` delete, `<C-y>` yank UUID,
   `<C-a>` add — three more `map()` calls in
   `lua/telescope/_extensions/task.lua`.
3. `:TaskReport <name>` with the seven Taskwarrior-default report names —
   each is "set filter to X, sort to Y, render". Maybe 60 lines total.
4. Configurable `notifications = {...}` table — wrap every `vim.notify`
   in `if config.options.notifications.<key> then …`. Mechanical.

That's a ~300-line PR that adds three Tier-1 items without breaking
anything.
