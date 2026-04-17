# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Email the maintainer at `matt.handzel@proton.me` with:

- A description of the issue.
- Reproduction steps (a minimal snippet is ideal).
- The commit SHA or tag where you observed it.

You can expect an acknowledgement within a week. Public disclosure will be
coordinated — the goal is to land a fix before the details are published.

## Scope

task.nvim shells out to `task`, `claude`, and (optionally) `python3` via
`vim.fn.system` with `shellescape`-quoted arguments. High-interest areas:

- Any path where user-supplied text reaches a shell invocation without
  `shellescape`.
- Any path where `apply` could modify / delete tasks the user didn't intend
  — the P0 stress-test fix (missing-header check) is the canonical example.
- Delegation (`:TaskDelegate`) writes prompts to a tmpfile and pipes them
  into an external binary. Tmpfile leaks or injection would be relevant.
- Feedback endpoint (`:TaskFeedback`) posts structured JSON to a
  user-configured URL. The endpoint is off by default; when enabled, the
  contents of the feedback buffer and scrubbed environment metadata are
  sent.

## Not in scope

- Taskwarrior's own security model. task.nvim trusts `task` to be
  well-behaved with respect to its data directory.
- Third-party plugins that integrate with task.nvim (telescope, cmp, your
  statusline).
