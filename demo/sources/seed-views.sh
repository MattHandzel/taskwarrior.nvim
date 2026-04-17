#!/usr/bin/env bash
# Richer seed for the visualization-view screenshots (burndown, tree,
# summary, calendar, tags). Builds a 40+ task db with backdated entries,
# backdated completions, multiple projects, dependencies, and varied tags.
#
# Used by: demo/sources/{burndown,tree,summary,calendar,tags,review}.tape
# Not used by: hero/filter-group/quick-capture (those use seed-tasks.sh)
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

q() { task rc.bulk=0 rc.confirmation=no rc.verbose=nothing "$@" >/dev/null 2>&1; }
add() { q add "$@"; }

# Add a task and return its UUID (uses the verbose=new-id banner)
add_uuid() {
  local id
  id=$(task rc.bulk=0 rc.confirmation=no rc.verbose=new-id add "$@" 2>&1 \
    | grep -oP '(?<=Created task )\d+' | head -1)
  task rc.bulk=0 rc.confirmation=no rc.verbose=nothing _get "${id}.uuid"
}

days_ago()   { date -u -d "$1 days ago" +%Y-%m-%d; }
days_hence() { date -u -d "$1 days"     +%Y-%m-%d; }

# ----- Pending tasks across 6 projects ----------------------------------

# work.api (8 tasks, 2 with dependencies)
add "Review pull request 1284 for auth refactor" project:work.api priority:H due:tomorrow +review +pr
add "Investigate tail latency spike in /search" project:work.api priority:H due:tomorrow +bug +p1
add "Document new rate limiter thresholds" project:work.api priority:L +docs
add "Migrate session store to Redis 7" project:work.api priority:M due:friday +infra
add "Add OpenTelemetry traces to ingest path" project:work.api priority:M +observability
AUTH=$(add_uuid "Refactor auth middleware for compliance" project:work.api priority:H "due:$(days_hence 5)" +compliance +blocker)
q add "Write deprecation guide for v1 API" project:work.api priority:L "due:$(days_hence 10)" +docs "depends:$AUTH"
q add "Sunset v1 API after deprecation window" project:work.api priority:M "due:$(days_hence 14)" "depends:$AUTH"

# work.infra (5 tasks)
add "Rotate staging certificates before expiry" project:work.infra priority:H due:tomorrow +blocker +security
add "Upgrade CI runners to Ubuntu 24.04" project:work.infra priority:M "due:$(days_hence 7)"
add "Audit IAM policies for prod buckets" project:work.infra priority:M +security +compliance
add "Migrate metrics pipeline to Prometheus" project:work.infra priority:M +observability "due:$(days_hence 12)"
add "Set up canary deploy lane" project:work.infra priority:L

# work.security (4 tasks, 1 dependency chain)
PEN=$(add_uuid "Run quarterly pen test" project:work.security priority:H "due:$(days_hence 3)" +security)
q add "Triage pen-test findings" project:work.security priority:H +security +blocker "due:$(days_hence 5)" "depends:$PEN"
add "Update threat model doc" project:work.security priority:M +security +docs
add "Implement SAML SSO" project:work.security priority:M "due:$(days_hence 14)" +blocker

# writing (4 tasks)
add "Draft launch blog post for task.nvim" project:writing priority:M due:monday +launch
add "Outline talk: editing taskwarrior like oil.nvim" project:writing priority:L
add "Reply to comments on previous post" project:writing priority:L
add "Pitch guest article to LWN" project:writing priority:L +outreach

# personal (5 tasks)
add "Book flight for April conference" project:personal priority:H due:friday +travel
add "Pay April electricity bill" project:personal "due:$(days_hence 0)"
add "Call mom about weekend plans" project:personal +family
add "Renew gym membership" project:personal priority:L "due:$(days_hence 7)" +health
add "Schedule dental cleaning" project:personal priority:L +health

# learning (3 tasks)
add "Finish Rust async book chapter 7" project:learning +rust +reading
add "Build a toy raft implementation" project:learning priority:M +rust
add "Read A Philosophy of Software Design ch 3-5" project:learning +reading

# ----- Backdated completed tasks (for burndown history) ------------------

for i in 28 25 22 20 18 16 14 12 10 8 7 5 4 3 2 1; do
  uuid=$(add_uuid "Completed item from sprint day -${i}" project:work.api +retro)
  q "$uuid" modify "entry:$(days_ago $((i+5)))"
  q "$uuid" done
  q "$uuid" modify "end:$(days_ago "$i")"
done

# ----- A few backdated pending tasks (older carryover) -------------------

for i in 25 18 12 7 3; do
  uuid=$(add_uuid "Older pending carryover item -${i}d" project:work.api +carryover)
  q "$uuid" modify "entry:$(days_ago "$i")"
done

# ----- Start one task so the [>] marker is visible -----------------------

ACTIVE=$(task rc.bulk=0 rc.confirmation=no rc.verbose=nothing \
  project:work.api description:"Review pull request 1284 for auth refactor" \
  export | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["uuid"])')
q "$ACTIVE" start
