---
name: Bug report
about: Something broken in task.nvim
title: ""
labels: bug
assignees: ""
---

## What happened

<!-- Stack trace, error message, unexpected behaviour. Paste the output of
`:messages` if relevant. -->

## What you expected

<!-- One or two sentences. -->

## Minimal reproduction

<!-- A sequence of commands / keystrokes that triggers the bug on a fresh
nvim session. If the bug depends on specific task data, include a
`task export` snippet (scrub anything sensitive). -->

```
:Task ...
```

## Environment

- Neovim: `nvim --version | head -1` →
- Taskwarrior: `task --version` →
- Python (if CLI path involved): `python3 --version` →
- OS / distro:
- Plugin manager:
- Other plugins touching insert-mode keymaps (cmp, copilot, codeium,
  supermaven, etc.):

## `:checkhealth task`

<!-- Paste the output. -->

## Severity

- [ ] Data loss / corrupted tasks
- [ ] Crash / unusable
- [ ] Wrong output but recoverable
- [ ] Cosmetic / inconvenience
