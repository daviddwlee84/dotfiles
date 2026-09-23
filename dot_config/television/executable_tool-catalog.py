#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Reader for the repo's tool catalog, used by the `inventory` tv channel.

The catalog (``~/.config/docs/tools/tool-catalog.toml``, source
``dot_config/docs/tools/tool-catalog.toml``) is the SSOT for "what does this
repo install, what is it, which role installs it". This script joins it with
live host state:

  * chezmoi data (the init prompts) → is the tool's gate on for this host?
  * PATH / /Applications probes       → is it actually installed?

Subcommands:
    source                  TSV for tv: id, status, category, role, method, desc, display
    preview ID              human-readable detail (tv preview + Enter)
    cmd ID {install,upgrade,docs,bin}
                            print one derived value (tv actions)
    index-md [--write | --check] FILE...
                            render the tool-managers(.zh-TW).md Tool index table
                            (`just gen-tool-index`)

Status icons (single-width, and outside the Dingbats/emoji blocks — tv 0.15
renders ✓ ✗ ✅ as ␀): ● installed · × expected but missing · ○ gated off by an init prompt ·
– not for this OS · · nothing to probe (plugins, fonts, libraries). Non-OK rows
also carry a word (missing / gated / n/a) in the display so they can be typed.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

HOME = Path.home()
DEFAULT_CATALOG = HOME / ".config/docs/tools/tool-catalog.toml"
BEGIN = "<!-- BEGIN generated: tool-catalog (just gen-tool-index) -->"
END = "<!-- END generated: tool-catalog -->"
INDEX_HEADER = ["| Tool | macOS | Linux | Role |", "|---|---|---|---|"]

ICON = {"ok": "●", "missing": "×", "gated": "○", "na": "–", "unknown": "·"}
# Typeable filter word appended to the display (installed rows stay quiet).
WORD = {"ok": "", "missing": "missing", "gated": "gated", "na": "n/a", "unknown": ""}
LABEL = {
    "ok": "installed",
    "missing": "expected but missing",
    "gated": "not enabled on this host",
    "na": "not for this OS",
    "unknown": "nothing to probe",
}
# Tools whose `--version` is slow, launches a GUI, or isn't a thing.
NO_VERSION_CATEGORIES = {"GUI Apps", "Fonts & Input", "System Libraries"}


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------


def load_catalog(path: Path | None = None) -> dict:
    path = path or Path(os.environ.get("TOOL_CATALOG", DEFAULT_CATALOG))
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def load_chezmoi_data() -> dict:
    """Prompt answers. Read chezmoi.toml directly (fast); fall back to the CLI."""
    cfg = HOME / ".config/chezmoi/chezmoi.toml"
    try:
        with open(cfg, "rb") as fh:
            data = tomllib.load(fh).get("data", {})
        if data:
            return data
    except (OSError, tomllib.TOMLDecodeError):
        pass
    try:
        out = subprocess.run(
            ["chezmoi", "data", "--format", "json"],
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout
        return json.loads(out)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return {}


def host_os() -> str:
    return "darwin" if platform.system() == "Darwin" else "linux"


# --------------------------------------------------------------------------
# Derivations (pure — unit-tested)
# --------------------------------------------------------------------------


def is_na(cell: str) -> bool:
    c = cell.strip().lower()
    return c.startswith("n/a") or c.startswith("—") or c in {"", "-"}


def method_for(tool: dict, os_name: str) -> str:
    if os_name == "darwin":
        return tool.get("mac", "")
    linux = tool.get("linux", "")
    return tool.get("mac", "") if linux.strip().lower().startswith("same") else linux


def role_for(tool: dict, os_name: str) -> str:
    if os_name == "linux" and tool.get("role_linux"):
        return tool["role_linux"]
    return tool["role"]


def gate_for(tool: dict, roles: dict, os_name: str) -> str:
    if os_name == "linux" and "gate_linux" in tool:
        return tool["gate_linux"]
    if "gate" in tool:
        return tool["gate"]
    return roles.get(role_for(tool, os_name), {}).get("gate", "")


def eval_gate(expr: str, data: dict, defaults: dict) -> bool:
    if not expr:
        return True
    for term in expr.split("&"):
        term = term.strip()
        neg = term.startswith("!")
        term = term.lstrip("!")
        if "=" in term:
            key, want = term.split("=", 1)
            val = data.get(key, defaults.get(key))
            ok = str(val) == want
        else:
            val = data.get(term, defaults.get(term, False))
            ok = bool(val)
        if ok == neg:
            return False
    return True


def applies_to_os(tool: dict, roles: dict, os_name: str) -> bool:
    role = roles.get(role_for(tool, os_name), {})
    if "os" in role and os_name not in role["os"]:
        return False
    return not is_na(method_for(tool, os_name))


def bins_of(tool: dict) -> list[str]:
    return tool["bins"] if "bins" in tool else [tool["id"]]


def install_cmd(tool: dict, roles: dict, os_name: str) -> str:
    role_name = role_for(tool, os_name)
    role = roles.get(role_name, {})
    if "install" in role:
        return role["install"]
    tag = tool.get("tag") or role.get("tag") or role_name
    return f"just ansible-tags {tag}"


_UPGRADE_RULES = [
    ("ya pkg", "just upgrade-yazi-plugins"),
    ("uv tool", "just upgrade-uv"),
    ("dotnet", "just upgrade-dotnet"),
    ("gem", "just upgrade-gem"),
    ("npm", "just upgrade-npm"),
    ("cargo", "just upgrade-cargo"),
    ("go install", "just upgrade-go"),
    ("mise", "just upgrade-mise"),
    ("flatpak", "just upgrade-flatpak"),
    ("brew", "just upgrade-brew"),
]


def upgrade_cmd(tool: dict, os_name: str) -> str:
    if tool.get("upgrade"):
        return tool["upgrade"]
    role = role_for(tool, os_name)
    if role == "personal_tools":
        return "just upgrade-personal"
    if role == "coding_agents":
        return "just upgrade-agents"
    method = method_for(tool, os_name).lower()
    for needle, cmd in _UPGRADE_RULES:
        if needle in method:
            return cmd
    if any(w in method for w in ("apt", "yum", "dnf", "snap", "system")):
        return "system package manager (apt/dnf upgrade) — not covered by just upgrade-*"
    return "re-run the installer — see docs/this_repo/tool-managers.md"


# --------------------------------------------------------------------------
# Probing
# --------------------------------------------------------------------------


def find_app(app: str) -> Path | None:
    for base in (Path("/Applications"), HOME / "Applications", Path("/System/Applications")):
        p = base / f"{app}.app"
        if p.exists():
            return p
    return None


def probe(tool: dict, os_name: str) -> list[str]:
    """Paths found for this tool (empty = not found)."""
    found: list[str] = []
    if os_name == "darwin" and tool.get("app"):
        p = find_app(tool["app"])
        if p:
            found.append(str(p))
    for b in bins_of(tool):
        w = shutil.which(b)
        if w:
            found.append(w)
    return found


def status_of(tool: dict, cat: dict, data: dict, os_name: str) -> tuple[str, list[str]]:
    roles = cat.get("roles", {})
    if not applies_to_os(tool, roles, os_name):
        return "na", []
    found = probe(tool, os_name)
    if found:
        return "ok", found
    if not eval_gate(gate_for(tool, roles, os_name), data, cat.get("gate_defaults", {})):
        return "gated", []
    has_probe = bool(bins_of(tool)) or (os_name == "darwin" and tool.get("app"))
    return ("missing" if has_probe else "unknown"), []


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def find_tool(cat: dict, tool_id: str) -> dict:
    for t in cat["tool"]:
        if t["id"] == tool_id:
            return t
    sys.exit(f"tool-catalog: unknown id {tool_id!r}")


def cmd_source(cat: dict) -> None:
    os_name = host_os()
    data = load_chezmoi_data()
    order = {c: i for i, c in enumerate(cat.get("categories", []))}
    tools = sorted(cat["tool"], key=lambda t: (order.get(t["category"], 99), t["id"]))
    width = max(len(t["id"]) for t in tools)
    out = sys.stdout
    for t in tools:
        st, _ = status_of(t, cat, data, os_name)
        icon = ICON[st]
        role = role_for(t, os_name)
        method = " ".join(method_for(t, os_name).replace("`", "").split())
        tail = f"{role} · {WORD[st]}" if WORD[st] else role
        display = f"{icon} {t['id']:<{width}}  [{t['category']}]  {t['desc']}  ({tail})"
        row = [t["id"], icon, t["category"], role, method, t["desc"], display]
        out.write("\t".join(c.replace("\t", " ") for c in row) + "\n")


def _version(tool: dict, found: list[str]) -> str:
    if tool["category"] in NO_VERSION_CATEGORIES:
        return ""
    exe = next((f for f in found if not f.endswith(".app")), None)
    if not exe:
        return ""
    try:
        r = subprocess.run(
            [exe, "--version"], capture_output=True, text=True, timeout=2,
            stdin=subprocess.DEVNULL,
        )
        line = (r.stdout or r.stderr).strip().splitlines()
        return line[0][:100] if line else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def cmd_preview(cat: dict, tool_id: str) -> None:
    t = find_tool(cat, tool_id)
    os_name = host_os()
    roles = cat.get("roles", {})
    data = load_chezmoi_data()
    st, found = status_of(t, cat, data, os_name)
    gate = gate_for(t, roles, os_name)
    B, D, R = "\033[1m", "\033[2m", "\033[0m"

    def row(k: str, v: str) -> None:
        if v:
            print(f"{D}{k:<10}{R}{v}")

    print(f"{B}{t['id']}{R}  —  {t['desc']}")
    print(f"{D}{'─' * 60}{R}")
    reason = LABEL[st]
    if st == "gated":
        reason += f"  (prompt gate `{gate}` is off — enable via `chezmoi init` / chezmoi.toml)"
    elif st == "ok" and gate and not eval_gate(gate, data, cat.get("gate_defaults", {})):
        reason += f"  (gate `{gate}` is off — installed by something else?)"
    row("status", f"{ICON[st]} {reason}")
    for f in found:
        row("path", f)
    row("version", _version(t, found) if found else "")
    row("category", t["category"])
    row("role", role_for(t, os_name) + (f"   gate: {gate}" if gate else ""))
    row("macOS", t.get("mac", ""))
    row("Linux", t.get("linux", ""))
    row("install", install_cmd(t, roles, os_name))
    row("upgrade", upgrade_cmd(t, os_name))
    row("docs", t.get("docs", ""))
    bins = bins_of(t)
    if bins:
        row("bins", "  ".join(f"{b} {'●' if shutil.which(b) else '×'}" for b in bins))
    if t.get("app"):
        row("app", f"{t['app']}.app")
    if t.get("role_md"):
        print(f"\n{D}notes{R}\n{t['role_md']}")


def cmd_value(cat: dict, tool_id: str, what: str) -> None:
    t = find_tool(cat, tool_id)
    os_name = host_os()
    roles = cat.get("roles", {})
    if what == "install":
        print(install_cmd(t, roles, os_name))
    elif what == "upgrade":
        print(upgrade_cmd(t, os_name))
    elif what == "docs":
        print(t.get("docs", ""))
    elif what == "bin":
        bins = bins_of(t)
        print(next((b for b in bins if shutil.which(b)), bins[0] if bins else t["id"]))
    else:
        sys.exit(f"tool-catalog: unknown field {what!r}")


# --------------------------------------------------------------------------
# Tool index generation
# --------------------------------------------------------------------------


def index_rows(cat: dict) -> list[str]:
    def key(t: dict) -> str:
        return (t.get("label") or t["id"]).replace("*", "").lower()

    lines = list(INDEX_HEADER)
    for t in sorted(cat["tool"], key=key):
        label = t.get("label") or f"**{t['id']}**"
        role = t.get("role_md") or (
            f"{t['role']} / {t['role_linux']}" if t.get("role_linux") else t["role"]
        )
        lines.append(f"| {label} | {t.get('mac', '')} | {t.get('linux', '')} | {role} |")
    return lines


def render_region(cat: dict) -> str:
    return "\n".join([BEGIN, *index_rows(cat), END])


def splice(text: str, region: str) -> str:
    try:
        start = text.index(BEGIN)
        end = text.index(END, start) + len(END)
    except ValueError:
        sys.exit(f"tool-catalog: marker region not found ({BEGIN!r} … {END!r})")
    return text[:start] + region + text[end:]


def cmd_index(cat: dict, argv: list[str]) -> int:
    region = render_region(cat)
    if not argv:
        print(region)
        return 0
    mode, targets = argv[0], [Path(a) for a in argv[1:]]
    if mode not in ("--check", "--write") or not targets:
        sys.exit(f"tool-catalog: usage: index-md [--check|--write] FILE...")
    stale = 0
    for target in targets:
        text = target.read_text()
        new = splice(text, region)
        if new == text:
            continue
        if mode == "--check":
            print(f"{target}: Tool index is stale — run `just gen-tool-index`", file=sys.stderr)
            stale = 1
        else:
            target.write_text(new)
            print(f"updated {target}")
    return stale


def main(argv: list[str]) -> int:
    catalog_path = None
    if len(argv) >= 2 and argv[0] == "--catalog":
        catalog_path, argv = Path(argv[1]), argv[2:]
    if not argv:
        print(__doc__)
        return 2
    cat = load_catalog(catalog_path)
    sub, rest = argv[0], argv[1:]
    if sub == "source":
        cmd_source(cat)
    elif sub == "preview" and rest:
        cmd_preview(cat, rest[0])
    elif sub == "cmd" and len(rest) == 2:
        cmd_value(cat, rest[0], rest[1])
    elif sub == "index-md":
        return cmd_index(cat, rest)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
