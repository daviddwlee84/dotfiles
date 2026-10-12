"""Offline inventory/action tests: never focus or close a real Herdr pane."""

import base64
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "herdr_panes", ROOT / "dot_config/television/executable_herdr-panes.py"
)
h = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(h)


def info(*names):
    return {"shell_pid": 100, "foreground_processes": [
        {"pid": 100 + i, "argv0": name, "name": name.rsplit("/", 1)[-1]}
        for i, name in enumerate(names)
    ]}


def pane(pid="w1:p1", **extra):
    return {"pane_id": pid, "workspace_id": "w1", "tab_id": "w1:t1", "cwd": "/tmp", **extra}


def route(**extra):
    return {
        "schema_version": 1, "socket_path": "/tmp/selected.sock",
        "workspace_id": "w1", "tab_id": "w1:t1", "pane_id": "w1:p1",
        "workspace": "專案", "tab": "1", "kind": "shell", "programs": ["zsh"],
        "agent": "", "agent_status": "unknown", "cwd": "/tmp", "title": "", **extra,
    }


class ClassificationTests(unittest.TestCase):
    def test_login_and_nested_shells(self):
        self.assertEqual(h.classify(pane(), info("/bin/zsh", "-bash"))[0], "shell")

    def test_exec_replaces_shell_without_changing_pid(self):
        self.assertEqual(h.classify(pane(), info("nvim"))[0], "process")

    def test_foreground_group_with_shell_and_other_program(self):
        self.assertEqual(h.classify(pane(), info("bash", "node"))[0], "process")

    def test_agent_and_ordinary_process_are_distinct(self):
        self.assertEqual(h.classify(pane(agent="codex"), info("codex", "specstory"))[0], "agent")
        self.assertEqual(h.classify(pane(), info("ssh"))[0], "process")

    def test_missing_or_malformed_foreground_is_not_shell(self):
        for data in ({}, {"foreground_processes": []}, {"foreground_processes": [{}]},
                     {"foreground_processes": [None]}):
            with self.subTest(data=data), self.assertRaises(h.PaneError):
                h.classify(pane(agent="codex"), data)


class InventoryTests(unittest.TestCase):
    def query(self, socket, key, *args):
        self.assertEqual(socket, "/tmp/selected.sock")
        if key == "workspaces":
            return [{"workspace_id": "w1", "label": "same name"}]
        if key == "tabs":
            return [{"tab_id": "w1:t2", "label": "same tab"}, {"tab_id": "w1:t1", "label": "same tab"}]
        if key == "panes":
            return [pane("shell"), pane("agent", agent="codex"),
                    pane("process", tab_id="w1:t2"), pane("gone"), pane("picker")]
        if args[-1] == "gone":
            raise h.PaneError("pane not found")
        return info({"shell": "zsh", "agent": "codex", "process": "nvim"}[args[-1]])

    def test_views_order_unknown_and_caller_exclusion(self):
        expected = {"non-shell": ["process", "agent", "gone"], "agent": ["agent"],
                    "process": ["process"], "shell": ["shell"]}
        with patch.object(h, "query", side_effect=self.query), patch.dict(os.environ, HERDR_PANE_ID="picker"):
            for view, ids in expected.items():
                rows = h.inventory("/tmp/selected.sock", view)
                self.assertEqual([r["pane_id"] for r in rows], ids)
                if view == "non-shell":
                    self.assertEqual(rows[-1]["kind"], "unknown")

    def test_server_failure_produces_visible_non_actionable_row(self):
        output = io.StringIO()
        with patch.dict(os.environ, HERDR_ENV="1", HERDR_SOCKET_PATH="/tmp/selected.sock"), \
             patch.object(h, "query", side_effect=h.PaneError("server unavailable")), redirect_stdout(output):
            self.assertEqual(h.main(["list", "non-shell"]), 1)
        token, label, _ = output.getvalue().strip().split("\t")
        self.assertIn("ERROR", label)
        self.assertIn("server unavailable", h.decode(token)["notice"])

    def test_outside_herdr_never_queries_server(self):
        with patch.dict(os.environ, HERDR_ENV=""), patch.object(h, "query") as query, redirect_stdout(io.StringIO()):
            self.assertEqual(h.main(["list", "shell"]), 1)
            query.assert_not_called()

    def test_empty_view_is_explained(self):
        output = io.StringIO()
        with patch.dict(os.environ, HERDR_ENV="1", HERDR_SOCKET_PATH="/tmp/selected.sock"), \
             patch.object(h, "inventory", return_value=[]), redirect_stdout(output):
            self.assertEqual(h.main(["list", "process"]), 0)
        self.assertIn("No process panes", output.getvalue())


class ActionTests(unittest.TestCase):
    def test_titles_remain_data_and_rows_have_exactly_three_fields(self):
        value = "中文 ' $(touch /tmp/SHOULD_NOT_RUN) `echo nope`\t\n\x1b[31m"
        original = route(title=value, cwd=value)
        fields = h.row(original).split("\t")
        self.assertEqual(len(fields), 3)
        self.assertNotIn("\n", fields[1])
        self.assertNotIn("\x1b", fields[1])
        self.assertEqual(h.decode(fields[0]), original)
        self.assertRegex(fields[0], r"^[A-Za-z0-9_-]+$")

    def test_route_is_accepted_by_shared_focus_helper(self):
        import sys
        spec = importlib.util.spec_from_file_location("herdr_focus_test", ROOT / "dot_config/herdr/executable_focus-pane.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        decoded = module.decode_route(h.encode(route()))
        self.assertEqual(decoded.pane_id, "w1:p1")
        self.assertEqual(decoded.socket_path, "/tmp/selected.sock")

    def test_reject_invalid_tokens_and_routes(self):
        for token in ("'bad'", "a", h.encode({}), h.encode({"schema_version": True}),
                      base64.urlsafe_b64encode(b"[]").decode().rstrip("=")):
            with self.subTest(token=token), self.assertRaises(h.PaneError):
                h.decode(token)

    def test_moved_pane_is_not_actionable(self):
        with patch.object(h, "query", return_value=pane(tab_id="w1:t2")), self.assertRaises(h.PaneError):
            h.current_pane(route())

    def test_close_cancel_and_eof_do_not_mutate(self):
        for answer in ("", "n", EOFError()):
            kwargs = {"side_effect": answer} if isinstance(answer, Exception) else {"return_value": answer}
            with patch.object(h, "current_pane", return_value=pane()), patch("builtins.input", **kwargs), \
                 patch.object(h, "run") as run, redirect_stdout(io.StringIO()):
                h.close(route())
                run.assert_not_called()

    def test_close_confirms_then_revalidates_exact_route(self):
        with patch.object(h, "current_pane", return_value=pane()) as current, \
             patch("builtins.input", return_value="yes"), patch.object(h, "run") as run, redirect_stdout(io.StringIO()):
            h.close(route())
            self.assertEqual(current.call_count, 2)
            run.assert_called_once_with("/tmp/selected.sock", "pane", "close", "w1:p1")

    def test_disappeared_after_confirmation_is_not_closed(self):
        with patch.object(h, "current_pane", side_effect=[pane(), h.PaneError("gone")]), \
             patch("builtins.input", return_value="y"), patch.object(h, "run") as run, redirect_stdout(io.StringIO()):
            with self.assertRaises(h.PaneError):
                h.close(route())
            run.assert_not_called()

    def test_copy_directory_uses_fresh_literal_value(self):
        value = "/tmp/中文 ' $(nope)\nnext"
        with patch.object(h, "current_pane", return_value=pane(foreground_cwd=value)), \
             patch.object(h.shutil, "which", return_value="/usr/bin/pbcopy"), patch.object(h.subprocess, "run") as run:
            h.copy(route(), "dir")
            self.assertEqual(run.call_args.kwargs["input"], value.encode())
            self.assertNotIn("shell", run.call_args.kwargs)

    def test_focus_passes_exact_token_to_shared_helper(self):
        token = h.encode(route())
        with patch.dict(os.environ, XDG_CONFIG_HOME="/tmp/test config"), \
             patch.object(Path, "is_file", return_value=True), patch.object(h.subprocess, "call", return_value=0) as call:
            self.assertEqual(h.focus(token), 0)
            self.assertEqual(call.call_args.args[0][1:],
                             ["/tmp/test config/herdr/focus-pane.py", "--route-token", token])

    def test_preview_reads_fresh_metadata_and_visible_text(self):
        output = io.StringIO()
        with patch.object(h, "current_pane", return_value=pane(terminal_title="new title")), \
             patch.object(h, "query", return_value=info("zsh")), patch.object(h, "run", return_value="LIVE SCREEN\n") as run, \
             redirect_stdout(output):
            h.preview(route())
        self.assertIn("new title", output.getvalue())
        self.assertIn("background jobs have NOT been checked", output.getvalue())
        self.assertIn("LIVE SCREEN", output.getvalue())
        self.assertIn("visible", run.call_args.args)

    def test_run_sets_socket_and_bounds_timeout(self):
        with patch.object(h.subprocess, "run", side_effect=subprocess.TimeoutExpired("herdr", 5)) as run:
            with self.assertRaises(h.PaneError):
                h.run("/tmp/selected.sock", "pane", "list")
            self.assertEqual(run.call_args.kwargs["env"]["HERDR_SOCKET_PATH"], "/tmp/selected.sock")
            self.assertEqual(run.call_args.kwargs["timeout"], 5)


if __name__ == "__main__":
    unittest.main()
