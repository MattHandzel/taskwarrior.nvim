#!/usr/bin/env bash
# tests/e2e/run.sh — end-to-end feature verification.
#
# Spawns an isolated Taskwarrior DB in a temp dir, seeds a known fixture,
# then runs the plenary spec against it. Each spec drives a real feature
# (TaskAppend, TaskGraph, …) and asserts the observable downstream effect
# (exported task fields, mmdc-validatable output, nvim window state).
#
# Usage: ./tests/e2e/run.sh [spec_name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP="$(mktemp -d -t taskwarrior-e2e-XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# ── 1. Isolated Taskwarrior environment ──────────────────────────────────────
mkdir -p "${TMP}/.task"
cat > "${TMP}/.taskrc" <<EOF
data.location=${TMP}/.task
json.array=on
confirmation=off
bulk=0
verbose=none
hooks=off
news.version=3.4.2
EOF

export TASKRC="${TMP}/.taskrc"
export TASKDATA="${TMP}/.task"
export HOME="${TMP}"   # belt-and-braces: no ~/.taskrc leak
# Propagate the temp path so the spec can read fixture UUIDs written during seeding
export TASKWARRIOR_E2E_TMP="${TMP}"
# Ensure mmdc's puppeteer can find a browser even in sandboxed environments
export PUPPETEER_SKIP_DOWNLOAD="${PUPPETEER_SKIP_DOWNLOAD:-true}"

# ── 2. Seed a fixture covering the shapes every spec reuses ─────────────────
# Parent with two children (for :TaskLinkChildren, :TaskGraph dependency test)
parent_uuid="$(task add "Parent task" project:demo priority:M | \
               sed -n 's/Created task \([0-9]*\).*/\1/p')"
parent_full_uuid="$(task _get "${parent_uuid}.uuid")"
task add "Child one" project:demo depends:"${parent_full_uuid}" > /dev/null
task add "Child two" project:demo +urgent depends:"${parent_full_uuid}" > /dev/null

# Solo task for :TaskAppend / :TaskPrepend / :TaskDuplicate / :TaskModifyField
task add "Solo task" project:other > /dev/null

# Task with annotation for :TaskDenotate
anno_uuid="$(task add "Has annotation" | sed -n 's/Created task \([0-9]*\).*/\1/p')"
task "${anno_uuid}" annotate "first note" > /dev/null
task "${anno_uuid}" annotate "second note" > /dev/null

# Overdue + H priority for :TaskReport overdue / next
task add "Overdue item" due:2020-01-01 priority:H > /dev/null

# Deleted task for :TaskPurge
purge_uuid="$(task add "To be purged" | sed -n 's/Created task \([0-9]*\).*/\1/p')"
task "${purge_uuid}" delete < /dev/null > /dev/null 2>&1 || true
# Force the delete (task 3.x prompts even with confirmation=off for some verbs)
task rc.confirmation=off "${purge_uuid}" delete 2>&1 || true

# Active (started) task for :TaskStart/Stop + granulation + active report
active_uuid="$(task add "Active item" project:demo | sed -n 's/Created task \([0-9]*\).*/\1/p')"
task "${active_uuid}" start > /dev/null

# Bare inbox task (recent, no project, no due, no tags) for :TaskInbox
inbox_uuid="$(task add "Unsorted thought" | sed -n 's/Created task \([0-9]*\).*/\1/p')"

# Emit fixture IDs where the spec can read them
cat > "${TMP}/fixture.json" <<EOF
{
  "parent":  "${parent_full_uuid}",
  "anno":    "$(task _get "${anno_uuid}".uuid)",
  "purge":   "$(task _get "${purge_uuid}".uuid 2>/dev/null || echo '')",
  "active":  "$(task _get "${active_uuid}".uuid)",
  "inbox":   "$(task _get "${inbox_uuid}".uuid)"
}
EOF

echo "[e2e] TASKDATA=${TASKDATA}"
echo "[e2e] seeded $(task status:pending count) pending + $(task status:deleted count) deleted tasks"

# ── 3. Plenary dependencies ──────────────────────────────────────────────────
PLENARY_DIR="${REPO_ROOT}/tests/lua/.deps/plenary.nvim"
if [[ ! -d "${PLENARY_DIR}/.git" ]]; then
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git "${PLENARY_DIR}"
fi

# ── 4. Run the specs ─────────────────────────────────────────────────────────
SPEC_DIR="${SCRIPT_DIR}/spec"
if [[ $# -ge 1 ]]; then
  SPEC_DIR="${SCRIPT_DIR}/spec/${1}"
fi

nvim --headless \
  -u "${SCRIPT_DIR}/minimal_init.lua" \
  -c "PlenaryBustedDirectory ${SPEC_DIR} {minimal_init='${SCRIPT_DIR}/minimal_init.lua', sequential=true}" \
  -c "qa!"
