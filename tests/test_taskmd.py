"""Comprehensive pytest tests for the taskmd CLI."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys

import pytest

# ---------------------------------------------------------------------------
# Module import
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_BIN_DIR = os.path.join(_REPO_ROOT, "bin")
_SCRIPT_PATH = os.path.join(_BIN_DIR, "taskmd")

sys.path.insert(0, _BIN_DIR)

# The script has no .py extension; we must supply the loader explicitly.
import importlib.machinery
_loader = importlib.machinery.SourceFileLoader("taskmd", _SCRIPT_PATH)
_spec = importlib.util.spec_from_loader("taskmd", _loader)
taskmd = importlib.util.module_from_spec(_spec)
_loader.exec_module(taskmd)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_full_uuid(prefix: str) -> str:
    """Pad a short prefix into a valid full UUID for test base tasks."""
    # prefix must be 8 hex chars
    assert len(prefix) == 8
    return f"{prefix}-1234-5678-9abc-def012345678"


# ---------------------------------------------------------------------------
# TestParser
# ---------------------------------------------------------------------------

class TestParser:
    def test_parse_simple_line(self):
        task = taskmd.parse_task_line("- [ ] Do thing")
        assert task is not None
        assert task["status"] == "pending"
        assert task["description"] == "Do thing"

    def test_parse_completed(self):
        task = taskmd.parse_task_line("- [x] Done thing")
        assert task is not None
        assert task["status"] == "completed"
        assert task["description"] == "Done thing"

    def test_parse_with_all_fields(self):
        line = "- [ ] Deploy service project:Work priority:H due:2026-04-01 scheduled:2026-03-25 +backend +devops <!-- uuid:ab05fb51 -->"
        task = taskmd.parse_task_line(line)
        assert task is not None
        assert task["status"] == "pending"
        assert task["description"] == "Deploy service"
        assert task["project"] == "Work"
        assert task["priority"] == "H"
        assert task["due"] == "2026-04-01"
        assert task["scheduled"] == "2026-03-25"
        assert "backend" in task["tags"]
        assert "devops" in task["tags"]
        assert task["_short_uuid"] == "ab05fb51"

    def test_parse_with_uuid(self):
        line = "- [ ] Buy groceries <!-- uuid:ab05fb51 -->"
        task = taskmd.parse_task_line(line)
        assert task is not None
        assert task["_short_uuid"] == "ab05fb51"
        # UUID comment should not appear in description
        assert "uuid" not in task["description"]
        assert "<!--" not in task["description"]

    def test_parse_no_uuid(self):
        task = taskmd.parse_task_line("- [ ] No uuid here")
        assert task is not None
        assert task.get("_short_uuid") is None

    def test_parse_description_with_colon(self):
        line = "- [ ] Note: do this thing project:Work"
        task = taskmd.parse_task_line(line)
        assert task is not None
        assert task["description"] == "Note: do this thing"
        assert task["project"] == "Work"

    def test_parse_empty_line(self):
        assert taskmd.parse_task_line("") is None

    def test_parse_header_line(self):
        assert taskmd.parse_task_line("# Tasks:") is None

    def test_parse_group_header(self):
        assert taskmd.parse_task_line("## Inbox") is None

    def test_parse_tags_sorted(self):
        line = "- [ ] Multi tag task +zebra +apple +mango"
        task = taskmd.parse_task_line(line)
        assert task is not None
        assert task["tags"] == ["apple", "mango", "zebra"]

    def test_serialize_roundtrip(self):
        original_line = "- [ ] Deploy service project:Work priority:H due:2026-04-01 +backend"
        task = taskmd.parse_task_line(original_line)
        assert task is not None
        serialized = taskmd.serialize_task_line(task)
        # Re-parse the serialized line and compare fields
        reparsed = taskmd.parse_task_line(serialized)
        assert reparsed is not None
        assert reparsed["description"] == task["description"]
        assert reparsed["project"] == task["project"]
        assert reparsed["priority"] == task["priority"]
        assert reparsed["due"] == task["due"]
        assert reparsed["tags"] == task["tags"]

    def test_serialize_field_order(self):
        task = {
            "status": "pending",
            "description": "Ordered task",
            "tags": ["z", "a"],
            "priority": "M",
            "due": "2026-05-01",
            "project": "Test",
            "scheduled": "2026-04-15",
            "effort": "1h",
        }
        line = taskmd.serialize_task_line(task)
        # Fields must appear in canonical order: project, priority, due, scheduled,
        # recur, wait, until, effort, then tags
        pos_project = line.index("project:")
        pos_priority = line.index("priority:")
        pos_due = line.index("due:")
        pos_scheduled = line.index("scheduled:")
        pos_effort = line.index("effort:")
        pos_tag_a = line.index("+a")
        pos_tag_z = line.index("+z")

        assert pos_project < pos_priority < pos_due < pos_scheduled < pos_effort
        assert pos_effort < pos_tag_a < pos_tag_z

    def test_serialize_with_uuid(self):
        task = {
            "status": "pending",
            "description": "UUID task",
            "uuid": "ab05fb51-1234-5678-9abc-def012345678",
        }
        line = taskmd.serialize_task_line(task)
        assert "<!-- uuid:ab05fb51 -->" in line
        # UUID comment must be at the end
        assert line.endswith("<!-- uuid:ab05fb51 -->")

    def test_parse_only_task_lines(self):
        # Lines that are not markdown task format must return None
        non_task_lines = [
            "  - [ ] indented",          # indented — doesn't match ^
            "[ ] no dash",
            "- [] no space in brackets",
            "- [X] capital X",           # only lowercase x is completed
            "plain text",
            "<!-- taskmd filter: | sort: urgency- | rendered_at: 2026-01-01 -->",
        ]
        for line in non_task_lines:
            result = taskmd.parse_task_line(line)
            assert result is None, f"Expected None for line: {repr(line)}, got {result}"

    def test_parse_recur_wait_until_fields(self):
        line = "- [ ] Recurring task recur:weekly wait:2026-04-01 until:2026-12-31"
        task = taskmd.parse_task_line(line)
        assert task is not None
        assert task["recur"] == "weekly"
        assert task["wait"] == "2026-04-01"
        assert task["until"] == "2026-12-31"
        assert task["description"] == "Recurring task"


# ---------------------------------------------------------------------------
# TestDiff
# ---------------------------------------------------------------------------

_BASE_TASK_1_UUID = _make_full_uuid("ab05fb51")
_BASE_TASK_2_UUID = _make_full_uuid("cd12ef34")

BASE_TASKS = [
    {
        "uuid": _BASE_TASK_1_UUID,
        "description": "Buy groceries",
        "status": "pending",
        "project": "Inbox",
    },
    {
        "uuid": _BASE_TASK_2_UUID,
        "description": "Fix bug",
        "status": "pending",
        "project": "Work",
        "priority": "H",
    },
]


def _parsed(line: str) -> dict:
    task = taskmd.parse_task_line(line)
    assert task is not None, f"Failed to parse: {repr(line)}"
    return task


class TestDiff:
    def test_no_changes(self):
        lines = [
            _parsed("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert actions == []

    def test_add_new_task(self):
        lines = [
            _parsed("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
            _parsed("- [ ] Brand new task project:Personal"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert len(actions) == 1
        assert actions[0]["type"] == "add"
        assert actions[0]["description"] == "Brand new task"
        assert actions[0]["fields"].get("project") == "Personal"

    def test_modify_description(self):
        lines = [
            _parsed("- [ ] Buy MORE groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert len(actions) == 1
        assert actions[0]["type"] == "modify"
        assert actions[0]["uuid"] == _BASE_TASK_1_UUID
        assert actions[0]["fields"]["description"] == "Buy MORE groceries"

    def test_modify_priority(self):
        lines = [
            _parsed("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:L <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert len(actions) == 1
        assert actions[0]["type"] == "modify"
        assert actions[0]["uuid"] == _BASE_TASK_2_UUID
        assert actions[0]["fields"]["priority"] == "L"

    def test_modify_project(self):
        lines = [
            _parsed("- [ ] Buy groceries project:Home <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert len(actions) == 1
        assert actions[0]["type"] == "modify"
        assert actions[0]["uuid"] == _BASE_TASK_1_UUID
        assert actions[0]["fields"]["project"] == "Home"

    def test_complete_task(self):
        lines = [
            _parsed("- [x] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert len(actions) == 1
        assert actions[0]["type"] == "done"
        assert actions[0]["uuid"] == _BASE_TASK_1_UUID

    def test_uncomplete_task(self):
        base_with_completed = [
            {
                "uuid": _BASE_TASK_1_UUID,
                "description": "Buy groceries",
                "status": "completed",
                "project": "Inbox",
            },
        ]
        lines = [
            _parsed("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
        ]
        actions = taskmd.compute_diff(lines, base_with_completed)
        assert len(actions) == 1
        assert actions[0]["type"] == "modify"
        assert actions[0]["uuid"] == _BASE_TASK_1_UUID
        assert actions[0]["fields"].get("status") == "pending"

    def test_delete_task(self):
        # Task 1 is absent from lines → default on_delete="done" → done action
        lines = [
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert len(actions) == 1
        assert actions[0]["type"] == "done"
        assert actions[0]["uuid"] == _BASE_TASK_1_UUID

    def test_delete_task_hard(self):
        lines = [
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS, on_delete="delete")
        assert len(actions) == 1
        assert actions[0]["type"] == "delete"
        assert actions[0]["uuid"] == _BASE_TASK_1_UUID

    def test_add_tag(self):
        lines = [
            _parsed("- [ ] Buy groceries project:Inbox +urgent <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert len(actions) == 1
        assert actions[0]["type"] == "modify"
        assert actions[0]["uuid"] == _BASE_TASK_1_UUID
        assert "urgent" in actions[0]["fields"]["tags"]

    def test_remove_tag(self):
        # Implementation limitation: compute_diff only iterates fields present in the
        # parsed line. If a tag is removed (no +tag tokens → no "tags" key in parsed
        # dict), the omission is NOT detected and no modify action is emitted.
        # This test documents that known behavior.
        base_with_tag = [
            {
                "uuid": _BASE_TASK_1_UUID,
                "description": "Buy groceries",
                "status": "pending",
                "project": "Inbox",
                "tags": ["urgent"],
            },
            BASE_TASKS[1],
        ]
        lines = [
            # No +urgent tag on the line — tag removal is invisible to the diff engine
            _parsed("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, base_with_tag)
        # No actions: the diff engine does not detect tag removal when tags key is absent
        assert actions == []

    def test_duplicate_uuid(self):
        # Two lines sharing the same UUID: first is treated normally, second as add
        lines = [
            _parsed("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Duplicate line project:Inbox <!-- uuid:ab05fb51 -->"),
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        add_actions = [a for a in actions if a["type"] == "add"]
        assert len(add_actions) == 1
        assert add_actions[0]["description"] == "Duplicate line"

    def test_reorder_only(self):
        # Tasks in reversed order — no actual changes, so no actions
        lines = [
            _parsed("- [ ] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
            _parsed("- [ ] Buy groceries project:Inbox <!-- uuid:ab05fb51 -->"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)
        assert actions == []

    def test_multiple_changes(self):
        lines = [
            # task 1: description changed
            _parsed("- [ ] Buy ALL the groceries project:Inbox <!-- uuid:ab05fb51 -->"),
            # task 2: marked complete
            _parsed("- [x] Fix bug project:Work priority:H <!-- uuid:cd12ef34 -->"),
            # task 3: brand new
            _parsed("- [ ] Write tests project:Dev"),
        ]
        actions = taskmd.compute_diff(lines, BASE_TASKS)

        types = {a["type"] for a in actions}
        assert "modify" in types
        assert "done" in types
        assert "add" in types

        modify_actions = [a for a in actions if a["type"] == "modify"]
        assert any(a["uuid"] == _BASE_TASK_1_UUID for a in modify_actions)

        done_actions = [a for a in actions if a["type"] == "done"]
        assert any(a["uuid"] == _BASE_TASK_2_UUID for a in done_actions)

        add_actions = [a for a in actions if a["type"] == "add"]
        assert any(a["description"] == "Write tests" for a in add_actions)


# ---------------------------------------------------------------------------
# TestIntegration
# ---------------------------------------------------------------------------

@pytest.fixture
def tw_env(tmp_path):
    """Create an isolated Taskwarrior environment and patch taskmd._run."""
    taskdata = tmp_path / ".task"
    taskdata.mkdir()
    taskrc = tmp_path / ".taskrc"
    taskrc.write_text(
        f"data.location={taskdata}\n"
        "json.array=on\n"
        "confirmation=off\n"
        "bulk=0\n"
    )
    env = os.environ.copy()
    env["TASKRC"] = str(taskrc)
    env["TASKDATA"] = str(taskdata)

    original_run = taskmd._run

    def patched_run(args: list, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(args, capture_output=True, text=True, check=check, env=env)

    taskmd._run = patched_run
    yield env
    taskmd._run = original_run


def _tw_add(env: dict, *add_args: str) -> None:
    subprocess.run(
        ["task", "rc.confirmation=off", "rc.bulk=0", "add"] + list(add_args),
        env=env,
        capture_output=True,
        check=True,
    )


def _tw_export_all(env: dict) -> list[dict]:
    result = subprocess.run(
        ["task", "rc.confirmation=off", "rc.json.array=on", "export"],
        env=env,
        capture_output=True,
        text=True,
    )
    text = result.stdout.strip()
    if not text:
        return []
    return json.loads(text)


def _render_to_string(filter_args: list[str] | None = None) -> str:
    """Capture cmd_render output by temporarily redirecting stdout."""
    import io
    from contextlib import redirect_stdout

    f = io.StringIO()
    ns = _build_render_ns(filter_args or [])
    with redirect_stdout(f):
        taskmd.cmd_render(ns)
    return f.getvalue()


def _build_render_ns(filter_args: list[str], sort: str = "urgency-", fields: str | None = None, group: str | None = None):
    import argparse
    ns = argparse.Namespace()
    ns.filter = filter_args
    ns.sort = sort
    ns.fields = fields
    ns.group = group
    return ns


def _apply_markdown(content: str, tmp_path, dry_run: bool = False, on_delete: str = "done", force: bool = False) -> dict:
    import argparse
    import io
    from contextlib import redirect_stdout

    md_file = tmp_path / "tasks.md"
    md_file.write_text(content)

    ns = argparse.Namespace()
    ns.file = str(md_file)
    ns.dry_run = dry_run
    ns.on_delete = on_delete
    ns.force = force

    f = io.StringIO()
    with redirect_stdout(f):
        taskmd.cmd_apply(ns)
    return json.loads(f.getvalue())


class TestIntegration:
    def test_render_empty(self, tw_env, tmp_path):
        output = _render_to_string()
        assert "# Tasks:" in output
        # No task lines
        task_lines = [l for l in output.splitlines() if l.startswith("- [")]
        assert task_lines == []

    def test_add_via_markdown(self, tw_env, tmp_path):
        # Start with empty TW; write a markdown file with one new task
        content = (
            "<!-- taskmd filter:  | sort: urgency- | rendered_at: 2026-01-01T00:00:00 -->\n\n"
            "# Tasks: \n\n"
            "- [ ] New task from markdown project:Test\n"
        )
        summary = _apply_markdown(content, tmp_path)
        assert summary["added"] == 1
        assert summary["errors"] == []

        tasks = _tw_export_all(tw_env)
        descriptions = [t["description"] for t in tasks]
        assert "New task from markdown" in descriptions

    def test_complete_via_markdown(self, tw_env, tmp_path):
        _tw_add(tw_env, "Complete me", "project:Test")
        tasks = _tw_export_all(tw_env)
        assert len(tasks) == 1
        task = tasks[0]
        uuid_short = task["uuid"][:8]

        content = (
            "<!-- taskmd filter:  | sort: urgency- | rendered_at: 2026-01-01T00:00:00 -->\n\n"
            "# Tasks: \n\n"
            f"- [x] Complete me project:Test <!-- uuid:{uuid_short} -->\n"
        )
        summary = _apply_markdown(content, tmp_path, force=True)
        assert summary["completed"] == 1
        assert summary["errors"] == []

        tasks_after = _tw_export_all(tw_env)
        done = [t for t in tasks_after if t["status"] == "completed"]
        assert any(t["description"] == "Complete me" for t in done)

    def test_modify_via_markdown(self, tw_env, tmp_path):
        _tw_add(tw_env, "Original description", "project:Work")
        tasks = _tw_export_all(tw_env)
        task = tasks[0]
        uuid_short = task["uuid"][:8]

        content = (
            "<!-- taskmd filter:  | sort: urgency- | rendered_at: 2026-01-01T00:00:00 -->\n\n"
            "# Tasks: \n\n"
            f"- [ ] Modified description project:Work priority:H <!-- uuid:{uuid_short} -->\n"
        )
        summary = _apply_markdown(content, tmp_path, force=True)
        assert summary["modified"] == 1
        assert summary["errors"] == []

        tasks_after = _tw_export_all(tw_env)
        pending = [t for t in tasks_after if t["status"] == "pending"]
        assert any(t["description"] == "Modified description" for t in pending)

    def test_delete_via_markdown(self, tw_env, tmp_path):
        _tw_add(tw_env, "Task to delete", "project:Test")
        tasks = _tw_export_all(tw_env)
        assert len(tasks) == 1

        # Markdown has no task lines — task was "deleted" from the file
        content = (
            "<!-- taskmd filter:  | sort: urgency- | rendered_at: 2026-01-01T00:00:00 -->\n\n"
            "# Tasks: \n\n"
        )
        summary = _apply_markdown(content, tmp_path, force=True)
        # Default on_delete="done" → completed
        assert summary["completed"] == 1
        assert summary["errors"] == []

        tasks_after = _tw_export_all(tw_env)
        done = [t for t in tasks_after if t["status"] == "completed"]
        assert any(t["description"] == "Task to delete" for t in done)

    def test_dry_run(self, tw_env, tmp_path):
        _tw_add(tw_env, "Dry run task", "project:Test")
        tasks = _tw_export_all(tw_env)
        uuid_short = tasks[0]["uuid"][:8]

        content = (
            "<!-- taskmd filter:  | sort: urgency- | rendered_at: 2026-01-01T00:00:00 -->\n\n"
            "# Tasks: \n\n"
            f"- [x] Dry run task project:Test <!-- uuid:{uuid_short} -->\n"
        )
        result = _apply_markdown(content, tmp_path, dry_run=True, force=True)

        # dry-run returns {"actions": [...], "conflicts": [...]}
        assert "actions" in result
        done_actions = [a for a in result["actions"] if a["type"] == "done"]
        assert len(done_actions) == 1

        # Verify nothing actually changed in TW
        tasks_after = _tw_export_all(tw_env)
        assert all(t["status"] == "pending" for t in tasks_after)

    def test_full_roundtrip(self, tw_env, tmp_path):
        """Add 3 tasks, render, then modify one, complete one, add one, delete one."""
        _tw_add(tw_env, "Task A", "project:Alpha")
        _tw_add(tw_env, "Task B", "project:Beta")
        _tw_add(tw_env, "Task C", "project:Gamma")

        rendered = _render_to_string()
        lines = rendered.splitlines()

        # Collect task lines with their UUIDs
        task_lines = [l for l in lines if l.startswith("- [")]
        assert len(task_lines) == 3

        # Build uuid → line map
        uuid_to_line: dict[str, str] = {}
        for l in task_lines:
            import re
            m = re.search(r"<!--\s*uuid:([0-9a-fA-F]{8})\s*-->", l)
            if m:
                uuid_to_line[m.group(1)] = l

        tasks = _tw_export_all(tw_env)
        desc_to_uuid = {t["description"]: t["uuid"][:8] for t in tasks}

        uuid_a = desc_to_uuid["Task A"]
        uuid_b = desc_to_uuid["Task B"]
        # Task C will be removed (done)

        # Build modified markdown:
        # - Task A: modify description
        # - Task B: complete
        # - Task C: omit (→ done)
        # - New task D: add
        modified_lines = [
            lines[0],  # header
            "",
            lines[2],  # # Tasks: heading
            "",
            f"- [ ] Task A modified project:Alpha <!-- uuid:{uuid_a} -->",
            f"- [x] Task B project:Beta <!-- uuid:{uuid_b} -->",
            "- [ ] Task D project:Delta",
        ]
        modified_content = "\n".join(modified_lines) + "\n"

        summary = _apply_markdown(modified_content, tmp_path, force=True)
        assert summary["errors"] == []
        assert summary["added"] == 1       # Task D
        assert summary["modified"] == 1    # Task A description
        assert summary["completed"] >= 2   # Task B + Task C

        tasks_final = _tw_export_all(tw_env)
        descriptions = {t["description"]: t["status"] for t in tasks_final}

        assert descriptions.get("Task A modified") == "pending"
        assert descriptions.get("Task B") == "completed"
        assert descriptions.get("Task C") == "completed"
        assert descriptions.get("Task D") == "pending"
