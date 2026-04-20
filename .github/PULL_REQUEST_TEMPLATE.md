<!-- One-line summary of the change. -->

## Summary

<!-- What does this PR do, and why? -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor (no user-visible change)
- [ ] Docs / tests / CI
- [ ] Breaking change (explain migration)

## Testing

<!-- How did you verify this works? -->

- [ ] `python3 -m pytest tests/ -v` passes locally (358 tests)
- [ ] `./tests/lua/bootstrap.sh` passes locally (121+ Lua assertions)
- [ ] Added or updated tests for the change
- [ ] Tried the feature in a real Neovim session (attach a GIF / screenshot
  if UI-visible)

## Checklist

- [ ] Commit messages are readable and scoped
- [ ] No `--amend` on public history
- [ ] `CHANGELOG.md` updated under `[Unreleased]` if user-visible
- [ ] No hardcoded field-specific semantics (see CONTRIBUTING.md)
- [ ] `bin/taskmd` changes stay stdlib-only
