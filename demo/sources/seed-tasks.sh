#!/usr/bin/env bash
# Seed a realistic taskwarrior db for the task.nvim demo GIFs.
# This gets run inside the VHS container before each tape. It builds a small
# but believable set of tasks that make the plugin look useful.
set -euo pipefail

TASKRC="${TASKRC:-$HOME/.taskrc-demo}"
TASKDATA="${TASKDATA:-$HOME/.task-demo}"
rm -rf "$TASKDATA" "$TASKRC"
mkdir -p "$TASKDATA"
cat > "$TASKRC" <<EOF
data.location=$TASKDATA
confirmation=no
verbose=nothing
news.version=3.4.2
EOF
export TASKRC TASKDATA

add() {
  task rc.confirmation=no rc.verbose=nothing add "$@" >/dev/null
}

# --- work.api ---
add "Review pull request 1284 for auth refactor" project:work.api priority:H due:tomorrow +review
add "Investigate tail latency spike in /search" project:work.api priority:H +bug +p1
add "Document new rate limiter thresholds" project:work.api priority:L
add "Migrate session store to Redis 7" project:work.api priority:M due:friday

# --- work.infra ---
add "Rotate staging certificates before expiry" project:work.infra priority:H due:tomorrow +blocker
add "Upgrade CI runners to Ubuntu 24.04" project:work.infra priority:M
add "Audit IAM policies for prod buckets" project:work.infra priority:M +security

# --- writing ---
add "Draft launch blog post for task.nvim" project:writing priority:M due:monday
add "Outline talk: editing taskwarrior like oil.nvim" project:writing priority:L

# --- personal ---
add "Book flight for April conference" project:personal priority:H due:friday
add "Pay April electricity bill" project:personal due:2026-04-15
add "Call mom about weekend plans" project:personal

# Start one so we get a [>] marker in the demo
WIP_UUID=$(task rc.confirmation=no rc.verbose=nothing project:work.api \
  description:"Investigate tail latency spike in /search" export \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["uuid"])')
task rc.confirmation=no rc.verbose=nothing "$WIP_UUID" start >/dev/null
