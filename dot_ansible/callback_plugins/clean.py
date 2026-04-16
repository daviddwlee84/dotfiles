# Custom "clean" stdout callback for Ansible
# - Replaces star-padded banners with clean lines
# - Adds task counter (e.g., [3/42])
# - Keeps all info from the default callback
# GNU General Public License v3.0+

from __future__ import annotations

DOCUMENTATION = """
    name: clean
    type: stdout
    short_description: Clean output with task counters and no star padding
    description:
        - Based on the default callback but replaces ugly star-padded banners
          with clean separator lines and adds task progress counters.
    extends_documentation_fragment:
      - default_callback
      - result_format_callback
    requirements:
      - set as stdout in configuration
"""

from ansible.plugins.callback.default import CallbackModule as DefaultCallback


class CallbackModule(DefaultCallback):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "clean"

    def __init__(self):
        super().__init__()
        self._task_counter = 0
        self._task_total = 0

    def v2_playbook_on_play_start(self, play):
        self._play = play

        # Count total tasks in this play
        try:
            self._task_total = sum(len(block) for block in self._play.get_tasks())
        except Exception:
            self._task_total = 0
        self._task_counter = 0

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
        from ansible import constants as C

        if not task.no_log and C.DISPLAY_ARGS_TO_STDOUT:
            args = ", ".join("%s=%s" % a for a in task.args.items())
            args = " %s" % args

        prefix = self._task_type_cache.get(task._uuid, "TASK")

        task_name = self._last_task_name
        if task_name is None:
            task_name = task.get_name().strip()

        self._task_counter += 1

        checkmsg = ""
        if task.check_mode and self.get_option("check_mode_markers"):
            checkmsg = " [CHECK MODE]"

        if self._task_total > 0:
            counter = "[%d/%d]" % (self._task_counter, self._task_total)
        else:
            counter = "[%d]" % self._task_counter

        self._display.display(
            "%s %s %s [%s%s]%s" % (counter, prefix, "·", task_name, args, checkmsg),
        )

        if self._display.verbosity >= 2:
            self._print_task_path(task)

        self._last_task_banner = task._uuid

    def v2_playbook_on_stats(self, stats):
        self._display.display("")
        self._display.display("─" * 60, color="bright blue")
        self._display.display("PLAY RECAP", color="bright blue")
        self._display.display("─" * 60, color="bright blue")

        from ansible.utils.color import colorize, hostcolor
        from ansible import constants as C

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
