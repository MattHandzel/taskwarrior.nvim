#!/usr/bin/env bash
# bootstrap.sh — clone plenary.nvim if needed, then run the Lua test suite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLENARY_DIR="${SCRIPT_DIR}/.deps/plenary.nvim"

# ── 1. Ensure plenary.nvim is available ─────────────────────────────────────
if [[ ! -d "${PLENARY_DIR}/.git" ]]; then
  echo "[bootstrap] Cloning plenary.nvim (shallow)..."
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git "${PLENARY_DIR}"
fi

# ── 2. Run the test suite ────────────────────────────────────────────────────
echo "[bootstrap] Running Lua test suite..."

# PlenaryBustedDirectory exits non-zero when any test fails.
nvim \
  --headless \
  -u "${SCRIPT_DIR}/minimal_init.lua" \
  -c "PlenaryBustedDirectory ${SCRIPT_DIR}/spec {minimal_init='${SCRIPT_DIR}/minimal_init.lua'}" \
  -c "qa!" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
  echo "[bootstrap] FAILED (exit ${EXIT_CODE})"
  exit $EXIT_CODE
fi

echo "[bootstrap] All Lua tests passed."
