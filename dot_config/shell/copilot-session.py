#!/usr/bin/env python3
"""Private Copilot launcher backend. Python >=3.11; no third-party dependencies.

Agent stdin/stdout/stderr remain attached to the original terminal. Only the
post-exit SpecStory process is detached from terminal signals. State is outside
the checkout; flock leases distinguish live launches from interrupted runs.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tomllib
import uuid

SYNC_TIMEOUT = 30


class Error(Exception):
    pass


def say(message):
    print(f"copilot: {message}", file=sys.stderr, flush=True)


def state_dir():
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "copilot-proxy"


def private_dir(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path, value):
    atomic_write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def object_json(text, label):
    try:
        value = json.loads(text)
    except ValueError as exc:
        raise Error(f"invalid JSON in {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise Error(f"{label} must contain a JSON object")
    return value


def merge(base, override):
    result = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def split_command(text):
    """Match SpecStory spi.SplitCommandLine, including its non-shell escaping."""
    parts, current, quote, escaped = [], [], None, False
    for char in text:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif quote:
            if char == quote:
                quote = None
            else:
                current.append(char)
        elif char in "'\"":
            quote = char
        elif char in " \t\n":
            if current:
                parts.append("".join(current))
                current = []
        else:
            current.append(char)
    if current:
        parts.append("".join(current))
    return parts


def specstory_command(provider):
    for path in (Path.cwd() / ".specstory/cli/config.toml",
                 Path.home() / ".specstory/cli/config.toml"):
        if not path.exists():
            continue
        try:
            data = tomllib.loads(path.read_text())
        except (ValueError, OSError) as exc:
            raise Error(f"cannot read {path}: {exc}") from exc
        providers = data.get("providers", {})
        if not isinstance(providers, dict):
            raise Error(f"{path}: providers must be a TOML table")
        command = providers.get(f"{provider}_cmd")
        if command is not None:
            if not isinstance(command, str):
                raise Error(f"{path}: {provider}_cmd must be a string")
            if command.strip():
                return command
    return provider


# Options with values must be consumed before examining flag-looking prompt or
# settings data. -p/--print is a boolean in Claude, not a prompt-value option.
VALUE_FLAGS = {
    "--settings", "--model", "-m", "--permission-mode", "--permission-prompts",
    "--permission-prompt-tool", "--append-system-prompt", "--system-prompt",
    "--append-system-prompt-file", "--system-prompt-file", "--resume", "-r",
    "--session-id", "--agent", "--agents", "--effort", "--name", "-n",
    "--input-format", "--output-format", "--json-schema", "--max-budget-usd",
    "--setting-sources", "--fallback-model", "--debug-file", "--autocompact",
    "--ask-for-approval", "-a", "--sandbox", "-s", "--config", "--profile",
    "--cd", "-C",
}
CLAUDE_POLICY = {
    "--dangerously-skip-permissions", "--permission-mode", "--restricted",
    "--permission-prompts", "--permission-prompt-tool",
}
CODEX_COMPOUND = {"--full-auto", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox"}


def options(argv, provider):
    """Yield (start, end, option, value), stopping at the explicit -- boundary."""
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            return
        key, equals, value = arg.partition("=")
        if key == "-c" and provider == "codex":
            takes_value = True
        else:
            takes_value = key in VALUE_FLAGS
        # Codex supports attached short values, e.g. -sread-only and -cfoo=1.
        if provider == "codex" and arg[:2] in ("-m", "-s", "-a", "-c", "-C") and len(arg) > 2:
            key, value, equals, takes_value = arg[:2], arg[2:].removeprefix("="), True, True
        end = index + 1
        if takes_value and not equals:
            if provider == "claude" and key in ("--resume", "-r") and (end >= len(argv) or argv[end].startswith("-")):
                yield index, end, key, None
                index = end
                continue
            if end >= len(argv) or argv[end] == "--":
                raise Error(f"{key} needs a value")
            value = argv[end]
            end += 1
        yield index, end, key, value if takes_value or equals else None
        index = end


def settings_arg(argv):
    result, retained, end = {}, [], 0
    for start, stop, key, value in options(argv, "claude"):
        retained.extend(argv[end:start])
        if key == "--settings":
            if value.lstrip().startswith("{"):
                text = value
                label = "--settings"
            else:
                path = Path(value).expanduser()
                try:
                    text = path.read_text(encoding="utf-8-sig")
                except OSError as exc:
                    raise Error(f"cannot read --settings file {path}: {exc}") from exc
                label = str(path)
            result = object_json(text, label)
        else:
            retained.extend(argv[start:stop])
        end = stop
    retained.extend(argv[end:])
    for field in ("env", "permissions"):
        if field in result and not isinstance(result[field], dict):
            raise Error(f"--settings {field} must be an object")
    return result, retained


def command_prefix(argv):
    """Support SpecStory's executable wrappers and env assignments, not eval."""
    if os.path.basename(argv[0]) != "env":
        if os.path.basename(argv[0]) in ("sh", "bash", "zsh", "dash"):
            raise Error("shell-expression provider commands cannot receive agent overrides; use an executable wrapper forwarding its arguments")
        return 1
    index = 1
    while index < len(argv):
        item = argv[index]
        if item == "--":
            index += 1
            break
        if item in ("-i", "--ignore-environment") or "=" in item and not item.startswith("-"):
            index += 1
        elif item in ("-u", "--unset"):
            index += 2
        elif item.startswith("--unset="):
            index += 1
        elif item.startswith("-"):
            raise Error(f"unsupported env wrapper option {item}; use an executable wrapper")
        else:
            break
    if index >= len(argv):
        raise Error("env provider command needs an agent executable")
    return index + 1


def codex_config(argv):
    config = {}
    for _, _, key, value in options(argv, "codex"):
        if key in ("-c", "--config"):
            name, separator, raw = value.partition("=")
            if not separator:
                raise Error(f"{key} needs key=value (check the SpecStory codex_cmd)")
            try:
                parsed = tomllib.loads("value=" + raw)["value"]
            except ValueError:
                parsed = raw
            config[name.strip()] = parsed
    return config


def policy_axes(argv, provider, settings=None):
    opts = {key for _, _, key, _ in options(argv, provider)}
    if provider == "claude":
        permissions = (settings or {}).get("permissions", {})
        explicit = isinstance(permissions, dict) and "defaultMode" in permissions
        return {"permission"} if opts & CLAUDE_POLICY or explicit else set()
    config = codex_config(argv)
    axes = set()
    if opts & CODEX_COMPOUND:
        return {"approval", "sandbox"}
    if opts & {"-a", "--ask-for-approval"} or "approval_policy" in config:
        axes.add("approval")
    if opts & {"-s", "--sandbox"} or "sandbox_mode" in config:
        axes.add("sandbox")
    return axes


def strip_policy(argv, provider, axes):
    result, end = [], 0
    for start, stop, key, value in options(argv, provider):
        remove = False
        if provider == "claude":
            remove = "permission" in axes and key in CLAUDE_POLICY
        else:
            remove = (key in CODEX_COMPOUND and bool(axes)
                      or "approval" in axes and key in ("-a", "--ask-for-approval")
                      or "sandbox" in axes and key in ("-s", "--sandbox"))
            if key in ("-c", "--config"):
                name = value.partition("=")[0].strip()
                remove = (name == "approval_policy" and "approval" in axes
                          or name == "sandbox_mode" and "sandbox" in axes)
        result.extend(argv[end:start])
        if not remove:
            result.extend(argv[start:stop])
        end = stop
    result.extend(argv[end:])
    return result


def inspect(provider, mode, user_args):
    use_config = mode == "exit" or mode == "run" and shutil.which("specstory")
    base = split_command(specstory_command(provider)) if use_config else [provider]
    if not base:
        base = [provider]
    base[0] = os.path.expanduser(base[0])
    head = command_prefix(base)
    base[head - 1] = os.path.expanduser(base[head - 1])
    user_settings = settings_arg(user_args)[0] if provider == "claude" else {}
    axes = policy_axes(user_args, provider, user_settings)
    base_args = base[head:]
    if provider == "codex" and axes:
        expanded, end = [], 0
        for start, stop, key, _ in options(base_args, provider):
            expanded.extend(base_args[end:start])
            if key == "--full-auto":
                expanded.extend(["-a", "on-request", "-s", "workspace-write"])
            elif key == "--dangerously-bypass-approvals-and-sandbox":
                expanded.extend(["-a", "never", "-s", "danger-full-access"])
            elif key == "--approve-for-me" and len(axes) == 1:
                raise Error("configured --approve-for-me controls both permission axes; specify both approval and sandbox explicitly")
            else:
                expanded.extend(base_args[start:stop])
            end = stop
        expanded.extend(base_args[end:])
        base_args = expanded
    base_args = strip_policy(base_args, provider, axes)
    args = base_args + list(user_args)
    settings = {}
    if provider == "claude":
        settings, args = settings_arg(args)
        # --settings defaultMode is also an explicit user permission choice.
        if "permission" in policy_axes([], provider, settings):
            args = strip_policy(args, provider, {"permission"}) if not policy_axes(user_args, provider) else args
        if not policy_axes(args, provider, settings):
            args = ["--dangerously-skip-permissions", *args]
    else:
        present = policy_axes(args, provider)
        for axis, flag, value in (("approval", "--ask-for-approval", "never"),
                                  ("sandbox", "--sandbox", "danger-full-access")):
            if axis not in present:
                args = [flag, value, *args]
    config = codex_config(args) if provider == "codex" else {}
    model = config.get("model", "")
    if provider == "claude":
        env = settings.get("env", {})
        model = settings.get("model") or (env.get("ANTHROPIC_MODEL", "") if isinstance(env, dict) else "")
    for _, _, key, value in options(args, provider):
        if key in ("-m", "--model"):
            model = value
    return {"argv": [*base[:head], *args], "head": head, "settings": settings, "model": model or "",
            "config": config}


def effective_cwd(provider, args):
    origin = cwd = Path.cwd()
    if provider == "codex":
        for _, _, key, value in options(args, provider):
            if key in ("-C", "--cd"):
                cwd = (origin / Path(value).expanduser()).resolve()
    if not cwd.is_dir():
        raise Error(f"agent working directory does not exist: {cwd}")
    return cwd.resolve()


def validate_exit(provider, args):
    opts = {key for _, _, key, _ in options(args, provider)}
    bad = opts & {"--bg", "--background", "--cloud", "--remote-control", "--environment",
                  "--no-session-persistence", "--ephemeral", "--worktree", "--tmux", "-w"}
    if provider == "codex" and opts & {"--remote", "--connect"}:
        bad.add("--connect")
    if bad:
        raise Error("exit recording requires a foreground, persistent session in this checkout; unsupported: " + ", ".join(sorted(bad)))
    if not shutil.which("specstory"):
        raise Error("--specstory-mode exit requires SpecStory")


def group_dir(cwd):
    digest = hashlib.sha256(os.fsencode(str(cwd))).hexdigest()
    return private_dir(state_dir() / "sessions" / digest)


@contextlib.contextmanager
def locked(path):
    with path.open("a+") as handle:
        os.chmod(path, 0o600)
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield handle


def live_runs(directory, provider):
    live = False
    for path in directory.glob(f"{provider}-*.lease"):
        with path.open("a+") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                live = True
            else:
                path.unlink(missing_ok=True)
    return live


def sync_pending(directory, provider, cwd):
    pending = directory / f"{provider}.pending.json"
    if not pending.exists() or live_runs(directory, provider):
        return
    if not shutil.which("specstory"):
        say(f"{provider}: sync pending; install SpecStory and launch again in {cwd}")
        return
    say(f"{provider}: syncing saved sessions in {cwd}")
    # A temporary log file avoids a pipe writer blocking or unbounded RAM use.
    with tempfile.TemporaryFile() as output:
        try:
            proc = subprocess.Popen(["specstory", "sync", provider], cwd=cwd,
                                    stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                    start_new_session=True)
        except OSError as exc:
            say(f"{provider}: sync could not start ({exc}); retained {pending}")
            return
        try:
            rc = proc.wait(timeout=SYNC_TIMEOUT)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            rc = 124
        if rc == 0:
            pending.unlink(missing_ok=True)
            say(f"{provider}: sync complete")
        else:
            # Do not replay arbitrary transcript/log content to the terminal.
            say(f"{provider}: sync failed (exit {rc}); retained {pending}. Retry: specstory sync {provider}")


def model_guard():
    """Undo only a proxy-only /model default written by Claude, after it exits."""
    path = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "settings.json"

    def read():
        if not path.exists():
            return {}
        return object_json(path.read_text(), str(path))

    def proxy_only(value):
        if not isinstance(value, str) or not value:
            return False
        if value.startswith(("gpt-", "gemini-")):
            return True
        state = state_dir() / "model"
        pinned = state.read_text().splitlines()[0] if state.exists() and state.stat().st_size else ""
        return bool(pinned) and value.removesuffix("[1m]") == pinned.removesuffix("[1m]")

    baseline = read().get("model")
    had_native = baseline is not None and not proxy_only(baseline)

    def restore():
        try:
            current = read()
            if not proxy_only(current.get("model")):
                return
            if had_native:
                current["model"] = baseline
                action = "restored native user model"
            else:
                current.pop("model", None)
                action = "removed stale proxy model"
            write_json(path, current)
            say(f"{action} in {path}")
        except (OSError, Error) as exc:
            say(f"could not restore user model: {exc}")
    return restore


def run_session(provider, mode, argv, env, cwd, after_exit=None):
    directory = group_dir(cwd)
    lease_path = directory / f"{provider}-{uuid.uuid4().hex}.lease"
    child = None
    interrupted = 0
    cleaned = False
    old_handlers = {}
    terminal = None
    if sys.stdin.isatty():
        terminal = (sys.stdin.fileno(), termios.tcgetattr(sys.stdin.fileno()))

    def restore_terminal():
        if terminal is not None:
            fd, attrs = terminal
            with contextlib.suppress(OSError, termios.error):
                if os.tcgetpgrp(fd) == os.getpgrp():
                    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    def cleanup_model():
        nonlocal cleaned
        if after_exit is not None and not cleaned:
            cleaned = True
            after_exit()

    def handle_signal(signum, _frame):
        nonlocal interrupted
        interrupted = signum
        # Terminal INT already goes to the foreground group (agent included).
        # TERM/HUP may have targeted only this supervisor, so forward them.
        if child is not None and child.poll() is None and signum != signal.SIGINT:
            with contextlib.suppress(ProcessLookupError):
                child.send_signal(signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        old_handlers[signum] = signal.signal(signum, handle_signal)
    lease = None
    try:
        with locked(directory / "lock"):
            sync_pending(directory, provider, cwd)
            lease = lease_path.open("a+")
            os.chmod(lease_path, 0o600)
            fcntl.flock(lease, fcntl.LOCK_EX)
            if mode == "exit":
                write_json(directory / f"{provider}.pending.json",
                           {"provider": provider, "cwd": str(cwd), "created": time.time()})
        if interrupted:
            return 128 + interrupted
        # Inherit the lease so killing only the supervisor does not make a live
        # agent look stopped. exec'd programs reset caught signal handlers.
        child = subprocess.Popen(argv, env=env, cwd=cwd, pass_fds=(lease.fileno(),))
        rc = child.wait()
        child = None
        restore_terminal()
        cleanup_model()
        lease.close()
        lease = None
        with locked(directory / "lock"):
            lease_path.unlink(missing_ok=True)
            sync_pending(directory, provider, cwd)
        return rc if rc >= 0 else 128 - rc
    finally:
        if lease is not None:
            lease.close()
        if child is None or child.poll() is not None:
            restore_terminal()
        if after_exit is not None and (child is None or child.poll() is not None):
            cleanup_model()
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)


def launch(provider, mode, prepared, injected):
    argv = list(prepared["argv"])
    head = prepared.get("head", 1)
    env = os.environ.copy()
    if provider == "claude":
        settings = merge({"env": injected}, prepared["settings"])
        argv = [*argv[:head], "--settings", json.dumps(settings, ensure_ascii=False), *argv[head:]]
    else:
        env["GITHUB_COPILOT_API_KEY"] = "dummy"
        argv = [*argv[:head], *injected, *argv[head:]]
    cwd = effective_cwd(provider, argv[head:])
    # A relative executable refers to the launch directory, while --cd refers
    # to the agent root. Both the recorder and final sync must use that root.
    if "/" in argv[0] and not os.path.isabs(argv[0]):
        argv[0] = str(Path(argv[0]).resolve())
    if "/" in argv[head - 1] and not os.path.isabs(argv[head - 1]):
        argv[head - 1] = str(Path(argv[head - 1]).resolve())
    if provider == "codex":
        for start, stop, key, _ in reversed(list(options(argv[head:], provider))):
            if key in ("-C", "--cd"):
                argv[start + head:stop + head] = [key, str(cwd)]
    if mode == "exit":
        validate_exit(provider, argv[head:])
    if mode == "run" and shutil.which("specstory"):
        # A tiny exec trampoline keeps arbitrary argv (including empty strings
        # and backslashes) out of SpecStory's lossy command-string tokenizer.
        payload = json.dumps(argv, ensure_ascii=False)
        env["COPILOT_SESSION_ARGV"] = payload
        command = [sys.executable, str(Path(__file__).resolve()), "exec-agent"]
        encoded = " ".join('"' + part.replace("\\", "\\\\").replace('"', '\\"') + '"' for part in command)
        argv = ["specstory", "run", provider, "-c", encoded]
    return run_session(provider, mode, argv, env, cwd,
                       model_guard() if provider == "claude" else None)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def pin_git_check(path):
    root = git("rev-parse", "--show-toplevel")
    if root.returncode:
        if any((parent / ".git").exists() for parent in (Path.cwd(), *Path.cwd().parents)):
            raise Error("cannot determine Git worktree; refusing an unprotected project pin")
        return None
    relative = os.path.relpath(path, root.stdout.strip()).replace(os.sep, "/")
    tracked = git("ls-files", "--error-unmatch", "--", str(path))
    if tracked.returncode == 0:
        raise Error(f"{path} is tracked/staged; use claude-copilot-once")
    if tracked.returncode != 1:
        raise Error("cannot check whether project settings are tracked")
    ignore_rc = git("check-ignore", "-q", "--", str(path)).returncode
    if ignore_rc not in (0, 1):
        raise Error("cannot check Git's ignore rules")
    ignored = ignore_rc == 0
    exclude = git("rev-parse", "--git-path", "info/exclude")
    if exclude.returncode:
        raise Error("cannot locate Git's local exclude file")
    pattern = "/" + "".join("\\" + char if char in "\\*?[ " else char for char in relative)
    return Path(exclude.stdout.strip()).resolve(), pattern, ignored


def confirm(message, yes):
    if yes:
        return True
    if not sys.stdin.isatty():
        say(message + " (non-interactive: kept; use --yes to update)")
        return False
    try:
        return input(message + " [y/N] ").strip().lower() in ("y", "yes")
    except (EOFError, KeyboardInterrupt):
        return False


def redacted(key, value):
    if any(word in key.upper() for word in ("TOKEN", "KEY", "SECRET", "PASSWORD")):
        return "(set)" if value is not None else "(unset)"
    return json.dumps(value, ensure_ascii=False)


def pin(action, desired, owned, yes=False, quiet=False):
    note = (lambda *args: None) if quiet else say
    path = Path.cwd() / ".claude/settings.local.json"
    if path.is_symlink():
        raise Error(f"refusing to replace symlink {path}")
    digest = hashlib.sha256(os.fsencode(str(path.resolve()))).hexdigest()
    directory = private_dir(state_dir() / "pins" / digest)
    journal = directory / "claude.json"
    with locked(directory / "lock"):
        before = path.read_text() if path.exists() else None
        data = object_json(before, str(path)) if before is not None else {}
        current = data.get("env", {})
        if not isinstance(current, dict):
            raise Error(f"{path}: env must be an object")
        record = json.loads(journal.read_text()) if journal.exists() else None
        if action == "status":
            return int(not current.get("ANTHROPIC_BASE_URL"))
        git_info = pin_git_check(path) if path.exists() or action == "on" else None
        new = copy.deepcopy(data)
        if action == "on":
            changes = {key: value for key, value in desired.items() if current.get(key) != value or key not in current}
            drop_compact = ("CLAUDE_CODE_AUTO_COMPACT_WINDOW" not in desired
                            and "CLAUDE_CODE_AUTO_COMPACT_WINDOW" in current
                            and str(current.get("ANTHROPIC_MODEL", "")).removesuffix("[1m]") != str(desired.get("ANTHROPIC_MODEL", "")).removesuffix("[1m]"))
            if drop_compact:
                changes["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = None
            hide_existing = before is not None and git_info is not None and not git_info[2]
            if not changes and not hide_existing:
                note(f"copilot-here: unchanged — {path}")
                return 0
            for key, value in changes.items():
                note(f"{key}: {redacted(key, current.get(key))} -> {redacted(key, value)}")
            if hide_existing:
                note(f"Git will locally ignore the entire existing {path}")
            conflict = bool(set(current) & set(owned))
            if (conflict or hide_existing) and not confirm("Update the project's Copilot pin?", yes):
                note("copilot-here: kept existing settings")
                return 1
            if record is None:
                # Legacy pins have no known pre-pin values. Their off behavior
                # stays remove-owned-keys, rather than restoring another pin.
                legacy = (current.get("ANTHROPIC_AUTH_TOKEN") == "dummy"
                          and current.get("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") == "1"
                          and "ANTHROPIC_DEFAULT_SONNET_MODEL" in current
                          and "ANTHROPIC_DEFAULT_HAIKU_MODEL" in current)
                record = {"before": {}, "written": {}, "legacy": legacy}
            managed = dict(desired)
            if drop_compact:
                managed["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = None
            for key, value in managed.items():
                if key not in record["before"]:
                    record["before"][key] = {"present": key in current and not record["legacy"],
                                              "value": current.get(key) if not record["legacy"] else None}
                record["written"][key] = {"present": key in desired, "value": value}
            new["env"] = {**current, **desired}
            # Clearing an obsolete compact limit on model changes prevents a
            # previous larger model's budget surviving a metadata outage.
            if drop_compact:
                new["env"].pop("CLAUDE_CODE_AUTO_COMPACT_WINDOW", None)
        else:
            if before is None:
                note("copilot-here: already off (no local settings)")
                return 0
            restored = dict(current)
            if record:
                conflicts = []
                for key, written in record["written"].items():
                    if (key in current) != written["present"] or (key in current and current[key] != written["value"]):
                        conflicts.append(key)
                        continue
                    original = record["before"][key]
                    if original["present"]:
                        restored[key] = original["value"]
                    else:
                        restored.pop(key, None)
                if conflicts:
                    note("preserved settings changed since pinning: " + ", ".join(conflicts))
            else:
                restored = {key: value for key, value in current.items() if key not in owned}
            if restored:
                new["env"] = restored
            else:
                new.pop("env", None)
        # Re-read after an interactive prompt; never overwrite another writer.
        if (path.read_text() if path.exists() else None) != before:
            raise Error(f"{path} changed while confirming; retry")
        if git_info and action == "on":
            latest = pin_git_check(path)
            if not latest[2]:
                exclude, pattern, _ = latest
                exclude.parent.mkdir(parents=True, exist_ok=True)
                with exclude.open("a+") as out:
                    fcntl.flock(out, fcntl.LOCK_EX)
                    out.seek(0)
                    content = out.read()
                    if pattern not in content.splitlines():
                        out.write(("\n" if content and not content.endswith("\n") else "") + pattern + "\n")
                if git("check-ignore", "-q", "--", str(path)).returncode != 0:
                    raise Error(f"Git did not ignore {path}; no pin was written")
        if action == "on":
            write_json(journal, record)
        if new:
            write_json(path, new)
        else:
            path.unlink(missing_ok=True)
        if action == "off":
            journal.unlink(missing_ok=True)
        note(f"copilot-here: {action.upper()} — {path}")
        if action == "on":
            note(f"plain claude now uses {desired.get('ANTHROPIC_BASE_URL')} (model: {desired.get('ANTHROPIC_MODEL')}); off: copilot-here off")
        return 0


def main():
    command, *args = sys.argv[1:]
    if command == "exec-agent":
        argv = json.loads(os.environ.pop("COPILOT_SESSION_ARGV"))
        os.execvpe(argv[0], argv, os.environ)
    if command == "command":
        print(specstory_command(args[0]), end="")
        return 0
    if command == "clean-model":
        model_guard()()
        return 0
    if command == "inspect":
        provider, mode, *argv = args
        if argv[:1] == ["--"]:
            argv = argv[1:]
        result = inspect(provider, mode, argv)
        if mode == "exit":
            validate_exit(provider, result["argv"][result["head"]:])
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if command == "launch":
        provider, mode, prepared, injected = args
        return launch(provider, mode, json.loads(prepared), json.loads(injected))
    if command == "pin":
        parser = argparse.ArgumentParser()
        parser.add_argument("action", choices=("on", "off", "status"))
        parser.add_argument("desired")
        parser.add_argument("owned")
        parser.add_argument("--yes", action="store_true")
        parser.add_argument("--quiet", action="store_true")
        parsed = parser.parse_args(args)
        return pin(parsed.action, json.loads(parsed.desired), json.loads(parsed.owned), parsed.yes, parsed.quiet)
    raise Error(f"unknown private command: {command}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Error, OSError, ValueError) as exc:
        say(str(exc))
        sys.exit(2)
