#!/usr/bin/env bash
# Validate every VHS tape for environment isolation.
# Prevents the class of bug where TASKRC/TASKDATA aren't propagated into the
# nvim subprocess, causing the demo to render the user's real task data.
#
# Usage:  demo/validate-tapes.sh                  # validate all
#         demo/validate-tapes.sh demo/sources/hero.tape  # validate one
#
# Exit 0 if all pass, 1 if any fail.  Designed to run in pre-commit hooks
# and in demo/render-all.sh before any rendering happens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

errors=0
warnings=0
checked=0

validate_tape() {
  local tape="$1"
  local name
  name="$(basename "$tape")"
  local fails=0

  # Only validate tapes that launch nvim (i.e., tapes that display task data).
  # Tapes that only run shell commands or echo don't need env isolation.
  if ! grep -qP '^Type\s+".*nvim' "$tape"; then
    return 0
  fi

  ((checked++)) || true

  # Rule 1: Must have Env TASKRC pointing to an isolated path
  if ! grep -qP '^Env\s+TASKRC\s+"[^"]*(?:demo|tmp)' "$tape"; then
    echo -e "${RED}FAIL${NC} [$name] Missing or unsafe 'Env TASKRC' — must contain 'demo' or 'tmp' in path"
    ((fails++)) || true
  fi

  # Rule 2: Must have Env TASKDATA pointing to an isolated path
  if ! grep -qP '^Env\s+TASKDATA\s+"[^"]*(?:demo|tmp)' "$tape"; then
    echo -e "${RED}FAIL${NC} [$name] Missing or unsafe 'Env TASKDATA' — must contain 'demo' or 'tmp' in path"
    ((fails++)) || true
  fi

  # Rule 3: Every Type line containing 'nvim' must also have inline TASKRC= and TASKDATA=
  # (defense-in-depth: VHS Env may not propagate in all versions)
  while IFS= read -r line; do
    if ! echo "$line" | grep -qP 'TASKRC='; then
      echo -e "${RED}FAIL${NC} [$name] nvim launch missing inline TASKRC=: $line"
      ((fails++)) || true
    fi
    if ! echo "$line" | grep -qP 'TASKDATA='; then
      echo -e "${RED}FAIL${NC} [$name] nvim launch missing inline TASKDATA=: $line"
      ((fails++)) || true
    fi
  done < <(grep -P '^Type\s+".*nvim' "$tape")

  # Rule 4: Must seed from a known demo script (not from real data)
  if ! grep -qP 'seed-tasks\.sh|seed-views\.sh' "$tape"; then
    echo -e "${YELLOW}WARN${NC} [$name] No call to seed-tasks.sh or seed-views.sh found"
    ((warnings++)) || true
  fi

  # Rule 5: Must have a Hide block around the seed + launch so boilerplate is invisible
  if ! grep -qP '^Hide' "$tape"; then
    echo -e "${YELLOW}WARN${NC} [$name] No Hide block — seed/launch steps will be visible in the recording"
    ((warnings++)) || true
  fi

  if [ "$fails" -gt 0 ]; then
    ((errors += fails)) || true
    return 1
  fi
  echo -e "${GREEN}OK${NC}   [$name]"
  return 0
}

# Determine which tapes to validate
if [ $# -gt 0 ]; then
  tapes=("$@")
else
  tapes=()
  while IFS= read -r -d '' tape; do
    tapes+=("$tape")
  done < <(find "$REPO_DIR/demo/sources" -name '*.tape' -print0 | sort -z)
fi

echo "Validating ${#tapes[@]} tape(s) for environment isolation..."
echo

for tape in "${tapes[@]}"; do
  validate_tape "$tape" || true
done

echo
echo "Checked $checked tape(s) that launch nvim. $errors error(s), $warnings warning(s)."

if [ "$errors" -gt 0 ]; then
  echo -e "${RED}Validation failed.${NC} Fix the errors above before rendering."
  exit 1
fi

echo -e "${GREEN}All tapes pass.${NC}"
exit 0
