# Custom "clean" stdout callback for Ansible
# - Replaces star-padded banners with clean separator lines
# - Adds task counter (e.g., [3])
# - Shows role group headers when role changes
# - Shows per-task elapsed time
# - Marks changed tasks with a ✦ indicator
# - Shows total playbook elapsed time in PLAY RECAP
# GNU General Public License v3.0+

from __future__ import annotations

import time

DOCUMENTATION = """
    name: clean
    type: stdout
    short_description: Clean output with task counters and no star padding
    description:
        - Based on the default callback but replaces ugly star-padded banners
          with clean separator lines and adds task progress counters.
        - Shows role group headers when switching between roles.
        - Displays per-task elapsed time and total playbook run time.
        - Marks changed tasks with a visual indicator.
    extends_documentation_fragment:
      - default_callback
      - result_format_callback
    requirements:
      - set as stdout in configuration
"""

from ansible import constants as C
from ansible.plugins.callback.default import CallbackModule as DefaultCallback
from ansible.utils.color import colorize, hostcolor


class CallbackModule(DefaultCallback):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "clean"

    def __init__(self):
        super().__init__()
        self._task_counter = 0
        self._task_total = 0
        self._current_role = None
        self._task_start_time = None
        self._playbook_start_time = None

    @staticmethod
    def _format_duration(seconds):
        """Format seconds into a human-readable duration string."""
        if seconds < 1:
            return "%.1fs" % seconds
        elif seconds < 60:
            return "%.1fs" % seconds
        elif seconds < 3600:
            m, s = divmod(seconds, 60)
            return "%dm%ds" % (m, s)
        else:
            h, remainder = divmod(seconds, 3600)
            m, s = divmod(remainder, 60)
            return "%dh%dm%ds" % (h, m, s)

    def _get_role_name(self, task):
        """Extract role name from task, return None if not in a role."""
        if task._role:
            return task._role.get_name()
        return None

    def v2_playbook_on_start(self, playbook):
        self._playbook_start_time = time.time()
        super().v2_playbook_on_start(playbook)

    def v2_playbook_on_play_start(self, play):
        self._play = play

        # Count total tasks in this play
        try:
            self._task_total = sum(len(block) for block in self._play.get_tasks())
        except Exception:
            self._task_total = 0
        self._task_counter = 0
        self._current_role = None

        name = play.get_name().strip()
        checkmsg = ""
        if play.check_mode and self.get_option("check_mode_markers"):
            checkmsg = " [CHECK MODE]"

        if not name:
            msg = "PLAY%s" % checkmsg
        else:
            msg = "PLAY [%s]%s" % (name, checkmsg)

        self._display.display("")
        self._display.display("─" * 60, color="bright blue")
        self._display.display(msg, color="bright blue")
        self._display.display("─" * 60, color="bright blue")

    def _task_start(self, task, prefix=None):
        # Record task start time
        self._task_start_time = time.time()

        if prefix is not None:
            self._task_type_cache[task._uuid] = prefix

        from ansible.utils.fqcn import add_internal_fqcns

        if self._play.strategy in add_internal_fqcns(("free", "host_pinned")):
            self._last_task_name = None
        else:
            self._last_task_name = task.get_name().strip()
            if self.get_option("display_skipped_hosts") and self.get_option(
                "display_ok_hosts"
            ):
                self._print_task_banner(task)

    def _print_task_banner(self, task):
        args = ""
        if not task.no_log and C.DISPLAY_ARGS_TO_STDOUT:
            args = ", ".join("%s=%s" % a for a in task.args.items())
            args = " %s" % args

        prefix = self._task_type_cache.get(task._uuid, "TASK")

        task_name = self._last_task_name
        if task_name is None:
            task_name = task.get_name().strip()

        # Role group header
        role_name = self._get_role_name(task)
        if role_name and role_name != self._current_role:
            self._current_role = role_name
            label = " %s " % role_name
            pad = 60 - len(label)
            left = pad // 2
            right = pad - left
            self._display.display(
                "─" * left + label + "─" * right,
                color="bright cyan",
            )

        self._task_counter += 1

        checkmsg = ""
        if task.check_mode and self.get_option("check_mode_markers"):
            checkmsg = " [CHECK MODE]"

        counter = "[%d]" % self._task_counter

        self._display.display(
            "%s %s · [%s%s]%s" % (counter, prefix, task_name, args, checkmsg),
        )

        if self._display.verbosity >= 2:
            self._print_task_path(task)

        self._last_task_banner = task._uuid

    def _get_elapsed(self):
        """Return formatted elapsed time since task start, or empty string."""
        if self._task_start_time is not None:
            elapsed = time.time() - self._task_start_time
            return " (%s)" % self._format_duration(elapsed)
        return ""

    def v2_runner_on_ok(self, result):
        """Override to append elapsed time and changed marker."""
        from ansible.playbook.task_include import TaskInclude

        host_label = self.host_label(result)
        elapsed = self._get_elapsed()

        if isinstance(result.task, TaskInclude):
            if self._last_task_banner != result.task._uuid:
                self._print_task_banner(result.task)
            return
        elif result.result.get("changed", False):
            if self._last_task_banner != result.task._uuid:
                self._print_task_banner(result.task)
            msg = "✦ changed: [%s]%s" % (host_label, elapsed)
            color = C.COLOR_CHANGED
        else:
            if not self.get_option("display_ok_hosts"):
                return
            if self._last_task_banner != result.task._uuid:
                self._print_task_banner(result.task)
            msg = "ok: [%s]%s" % (host_label, elapsed)
            color = C.COLOR_OK

        self._handle_warnings_and_exception(result)

        if result.task.loop and "results" in result.result:
            self._process_items(result)
        else:
            self._clean_results(result.result, result.task.action)
            if self._run_is_verbose(result):
                msg += " => %s" % (self._dump_results(result.result),)
            self._display.display(msg, color=color)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        """Override to append elapsed time."""
        host_label = self.host_label(result)
        elapsed = self._get_elapsed()

        if self._last_task_banner != result.task._uuid:
            self._print_task_banner(result.task)

        self._handle_warnings_and_exception(result)
        self._clean_results(result.result, result.task.action)

        if result.task.loop and "results" in result.result:
            self._process_items(result)
        else:
            if self._display.verbosity < 2 and self.get_option(
                "show_task_path_on_failure"
            ):
                self._print_task_path(result.task)
            msg = "✘ fatal: [%s]: FAILED!%s => %s" % (
                host_label,
                elapsed,
                self._dump_results(result.result),
            )
            self._display.display(
                msg,
                color=C.COLOR_ERROR,
                stderr=self.get_option("display_failed_stderr"),
            )

        if ignore_errors:
            self._display.display("...ignoring", color=C.COLOR_SKIP)

    def v2_runner_item_on_ok(self, result):
        """Override to add changed marker on item results."""
        from ansible.playbook.task_include import TaskInclude

        host_label = self.host_label(result)
        if isinstance(result.task, TaskInclude):
            return
        elif result.result.get("changed", False):
            if self._last_task_banner != result.task._uuid:
                self._print_task_banner(result.task)
            msg = "✦ changed"
            color = C.COLOR_CHANGED
        else:
            if not self.get_option("display_ok_hosts"):
                return
            if self._last_task_banner != result.task._uuid:
                self._print_task_banner(result.task)
            msg = "ok"
            color = C.COLOR_OK

        self._handle_warnings_and_exception(result)

        msg = "%s: [%s] => (item=%s)" % (
            msg,
            host_label,
            self._get_item_label(result.result),
        )
        self._clean_results(result.result, result.task.action)
        if self._run_is_verbose(result):
            msg += " => %s" % self._dump_results(result.result)
        self._display.display(msg, color=color)

    def v2_playbook_on_stats(self, stats):
        self._display.display("")
        self._display.display("─" * 60, color="bright blue")

        # Total elapsed time
        total_msg = "PLAY RECAP"
        if self._playbook_start_time is not None:
            total_elapsed = time.time() - self._playbook_start_time
            total_msg += "  (%s)" % self._format_duration(total_elapsed)

        self._display.display(total_msg, color="bright blue")
        self._display.display("─" * 60, color="bright blue")

        hosts = sorted(stats.processed.keys())
        for h in hosts:
            t = stats.summarize(h)

            self._display.display(
                "%s : %s %s %s %s %s %s %s"
                % (
                    hostcolor(h, t),
                    colorize("ok", t["ok"], C.COLOR_OK),
                    colorize("changed", t["changed"], C.COLOR_CHANGED),
                    colorize("unreachable", t["unreachable"], C.COLOR_UNREACHABLE),
                    colorize("failed", t["failures"], C.COLOR_ERROR),
                    colorize("skipped", t["skipped"], C.COLOR_SKIP),
                    colorize("rescued", t["rescued"], C.COLOR_OK),
                    colorize("ignored", t["ignored"], C.COLOR_WARN),
                ),
                screen_only=True,
            )

        self._display.display("", screen_only=True)

        if stats.custom and self.get_option("show_custom_stats"):
            self._display.display("─" * 60)
            self._display.display("CUSTOM STATS:")
            for k in sorted(stats.custom.keys()):
                if k == "_run":
                    continue
                self._display.display(
                    "  %s: %s"
                    % (
                        k,
                        self._dump_results(stats.custom[k], indent=1).replace("\n", ""),
                    )
                )
            if "_run" in stats.custom:
                self._display.display("")
                self._display.display(
                    "  RUN: %s"
                    % self._dump_results(stats.custom["_run"], indent=1).replace(
                        "\n", ""
                    )
                )
            self._display.display("", screen_only=True)

    def v2_playbook_on_no_hosts_remaining(self):
        self._display.display("")
        self._display.display("NO MORE HOSTS LEFT", color="bright red")
