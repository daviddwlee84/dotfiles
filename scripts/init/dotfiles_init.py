#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "questionary>=2.0",
#   "rich>=13.9",
#   "tyro>=0.9",
# ]
# ///
"""
dotfiles_init.py — Interactive wrapper around `chezmoi init` inspired by
Vercel Labs' `skills` CLI (https://github.com/vercel-labs/skills).

The existing `.chezmoi.toml.tmpl` defines ~19 prompts (profile, email, name,
16 feature flags). `chezmoi init` asks them sequentially, which works but
hides the feature flags from each other and makes "set up a new machine
the way I always do" a manual checklist. This wrapper:

  1. Pre-flights chezmoi / git / SSH key and offers to fix gaps.
  2. Lets you pick a pre-configured BUNDLE (personal-mac, work-mac,
     server-linux, minimal) that ticks typical feature flags for you.
  3. Presents feature flags grouped, as a questionary multi-select you can
     fly through with Space + Enter.
  4. Shells out to `chezmoi init <repo> --apply [--ssh] --promptString ... `
     so chezmoi remains the source of truth — we just pre-answer its prompts.
  5. Streams chezmoi's output live and prints a recap at the end.

The wrapper also has a `doctor` subcommand that greps `.chezmoi.toml.tmpl`
and `Dockerfile` and fails loudly if any prompt key in those files is
missing from this script's PROMPTS list (or vice versa). Run it in CI / a
pre-commit hook to catch drift — per CLAUDE.md's "Dockerfile" cross-file
rule, adding a chezmoi prompt means updating three files in one commit.

Invocation:
    # Fresh machine (via bootstrap.sh which installs uv first):
    curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash

    # Existing chezmoi source dir — re-apply with new answers:
    uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py

    # Schema parity check:
    uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py doctor
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Literal

import questionary
import tyro
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_REPO = "daviddwlee84"  # chezmoi expands to github.com/daviddwlee84/dotfiles
CHEZMOI_SOURCE_DIR = Path.home() / ".local" / "share" / "chezmoi"
CHEZMOI_CONFIG = Path.home() / ".config" / "chezmoi" / "chezmoi.toml"
SSH_DIR = Path.home() / ".ssh"
SSH_CONFIG = SSH_DIR / "config"
# Canonical names OpenSSH tries by default if no IdentityFile is set.
SSH_DEFAULT_KEYS = [
    SSH_DIR / "id_ed25519",
    SSH_DIR / "id_rsa",
    SSH_DIR / "id_ecdsa",
]

console = Console()


# ---------------------------------------------------------------------------
# Prompt schema — mirrors .chezmoi.toml.tmpl (the source of truth)
#
# When you add/remove/rename a prompt here, also update:
#   1. .chezmoi.toml.tmpl          (the chezmoi template itself)
#   2. Dockerfile                   (ARG CHEZMOI_* + --promptBool/String flag)
# The `doctor` subcommand checks this parity automatically.
# ---------------------------------------------------------------------------

PromptType = Literal["string", "bool", "choice"]


@dataclass(frozen=True)
class Prompt:
    key: str                          # chezmoi prompt name (2nd arg to promptXOnce)
    kind: PromptType
    group: str                        # UI grouping
    label: str                        # short, shown in checkbox
    desc: str                         # longer tooltip-style hint (shown under label)
    default: object                   # python bool / str
    # The exact PROMPT TEXT from .chezmoi.toml.tmpl (3rd arg to promptXOnce).
    # This is what `chezmoi init --promptBool/--promptString/--promptChoice`
    # matches against when populating `promptXOnce` values — NOT the key name.
    # Verified empirically against chezmoi 2.68.0 / 2.69.4 / 2.70.2 on linux
    # and darwin: only the prompt text form `--promptBool "<text>=true"` works;
    # the key-name form silently fails over to interactive prompt. `doctor`
    # re-parses the template and asserts these texts still match.
    prompt_text: str = ""
    choices: tuple[str, ...] = ()     # for kind=choice
    darwin_only: bool = False         # skip on non-macOS
    hidden: bool = False              # basics (name/email/profile) handled specially


# Order matters — reflects the UI order.
# prompt_text MUST match the 3rd argument to promptXOnce in .chezmoi.toml.tmpl
# exactly — this is what chezmoi init's `--promptBool "<text>=..."` matches on.
PROMPTS: tuple[Prompt, ...] = (
    # --- Basics (special-cased in ask_basics) ----------------------------
    Prompt("profile", "choice", "Basics", "Profile",
           "Which profile this machine should use.",
           default="", prompt_text="Which profile",
           choices=("macos", "ubuntu_desktop", "ubuntu_server", "centos_server"),
           hidden=True),
    Prompt("email", "string", "Basics", "Git email",
           "Your email address, used by Git and chezmoi templates.",
           default="daviddwlee84@gmail.com",
           prompt_text="What is your email address",
           hidden=True),
    Prompt("name", "string", "Basics", "Git name",
           "Your full name, used by Git and chezmoi templates.",
           default="Da-Wei Lee",
           prompt_text="What is your full name",
           hidden=True),

    # --- Coding agents & AI ----------------------------------------------
    Prompt("installCodingAgents", "bool", "Coding agents & AI",
           "Coding agents",
           "Claude Code, OpenCode, Cursor, Copilot, Gemini, etc.",
           default=True,
           prompt_text="Install coding agents (Claude Code, OpenCode, Cursor, Copilot, Gemini, etc.)"),
    Prompt("installLlmTools", "bool", "Coding agents & AI",
           "Local LLM tools",
           "Ollama, LiteLLM, llmfit and matching local models.",
           default=False,
           prompt_text="Install local LLM tools (Ollama, LiteLLM, llmfit, models)"),
    Prompt("installAiDesktopApps", "bool", "Coding agents & AI",
           "AI desktop apps (macOS)",
           "Claude, ChatGPT, OpenCode, Antigravity, Codex, Ollama app via Brewfile.",
           default=False, darwin_only=True,
           prompt_text="Install AI desktop apps via macOS Homebrew Brewfile (Claude, ChatGPT, OpenCode, Antigravity, Codex, Ollama app)"),

    # --- Dev tooling -----------------------------------------------------
    Prompt("installPythonUvTools", "bool", "Dev tooling",
           "Python CLI tools (via uv)",
           "mlflow, sqlit-tui, tmuxp and other Python CLIs.",
           default=True,
           prompt_text="Install Python CLI tools via uv (mlflow, sqlit-tui, tmuxp, etc.)"),
    Prompt("installJsCliTools", "bool", "Dev tooling",
           "JS / npm CLI tools",
           "Standalone node CLIs like readability-cli.",
           default=True,
           prompt_text="Install standalone JS/npm CLI utilities (readability-cli for terminal web reader, etc.)"),
    Prompt("installDotnetTools", "bool", "Dev tooling",
           ".NET SDK + dotnet tools",
           ".NET SDK via mise plus global tools (azure-cost-cli, etc.).",
           default=False,
           prompt_text="Install .NET SDK via mise and dotnet global tools (azure-cost-cli, etc.)"),
    Prompt("installIacTools", "bool", "Dev tooling",
           "Infrastructure-as-Code tools",
           "Azure CLI, Terraform, OpenTofu.",
           default=False,
           prompt_text="Install Infrastructure-as-Code tools (Azure CLI, Terraform, OpenTofu)"),
    Prompt("installMediaTools", "bool", "Dev tooling",
           "Media / AV CLI tools",
           "ffmpeg, ImageMagick, exiftool, libvips. ffmpeg is also vhs's runtime dep.",
           default=False,
           prompt_text="Install media/AV CLI tools (ffmpeg, ImageMagick, exiftool, libvips)"),

    # --- System & apps ---------------------------------------------------
    Prompt("installBitwarden", "bool", "System & apps",
           "Bitwarden CLI + Desktop",
           "@bitwarden/cli with SSH Agent integration and Zsh completion. On ubuntu_desktop / macOS profiles, also installs Bitwarden Desktop (snap or .deb fallback on Linux, Homebrew Cask on macOS).",
           default=False,
           prompt_text="Install Bitwarden CLI (and Desktop on ubuntu_desktop/macOS — snap or .deb on Linux, Cask on macOS) with SSH Agent integration"),
    Prompt("installBrewApps", "bool", "System & apps",
           "Homebrew GUI apps",
           "Terminals, browsers, utilities via Brewfile (excl. AI desktop).",
           default=False,
           prompt_text="Install general GUI apps via Homebrew Brewfile (terminals, browsers, utilities, etc.; excludes AI desktop apps)"),
    Prompt("installInputMethod", "bool", "System & apps",
           "Traditional Chinese IME",
           "McBopomofo + RIME for zh-TW input.",
           default=False,
           prompt_text="Install Traditional Chinese input methods (McBopomofo, RIME)"),
    Prompt("discordChannel", "choice", "System & apps",
           "Discord install channel",
           "ubuntu_desktop only (macOS → Brewfile cask, ubuntu_server → skipped). flatpak (recommended): Flathub auto-updates via `flatpak update`. deb: official .deb, manual re-deploy each release. none: skip.",
           default="flatpak",
           prompt_text="Discord install channel (flatpak|deb|none)",
           choices=("flatpak", "deb", "none")),
    Prompt("installNetworkingTools", "bool", "System & apps",
           "Networking CLI tools",
           "nmap, mtr, httpie, gping, trippy.",
           default=False,
           prompt_text="Install networking CLI tools (nmap, mtr, httpie, gping, trippy, etc.)"),
    # --- Preferences -----------------------------------------------------
    Prompt("useChineseMirror", "bool", "Preferences",
           "Use China (GFW) mirrors",
           "Switch Homebrew / pip / npm / etc. to China-hosted mirrors.",
           default=False,
           prompt_text="Are you in China (behind GFW) and need to use mirrors"),
    Prompt("gitleaksAllRepos", "bool", "Preferences",
           "Gitleaks on all repos",
           "Scan secrets even for repos without .pre-commit-config.yaml.",
           default=False,
           prompt_text="Enable gitleaks for ALL git repos (not just those with .pre-commit-config.yaml)"),
    Prompt("backupMode", "choice", "Preferences",
           "Backup mode for existing dotfiles",
           "smart = only files chezmoi will overwrite (uses `chezmoi status`); full = hardcoded allowlist (onboarding mode); off = skip.",
           default="smart",
           prompt_text="Backup mode for existing dotfiles (smart|full|off)",
           choices=("smart", "full", "off")),
    Prompt("allowPartialFailure", "bool", "Preferences",
           "Allow partial Ansible failures",
           "Continue other roles if one role fails.",
           default=False,
           prompt_text="Allow partial Ansible failures (continue installing other tools if one role fails)"),
    Prompt("noRoot", "bool", "Preferences",
           "No sudo / root access",
           "Skip all system package installations (user-level tools only).",
           default=False,
           prompt_text="No sudo/root access - skip all system package installations"),
    Prompt("motdStyle", "choice", "Preferences",
           "SSH login banner style",
           "figlet (~6 lines, ~5ms) | fastfetch-slim (figlet + fastfetch slim, ~10 lines, ~80ms) | fastfetch-full (full distro logo + everything, ~22 lines, ~150ms). Runtime override: MOTD_STYLE in ~/.zshrc.adhoc.",
           default="figlet",
           prompt_text="SSH login banner style (figlet|fastfetch-slim|fastfetch-full)",
           choices=("figlet", "fastfetch-slim", "fastfetch-full")),
)


# ---------------------------------------------------------------------------
# Bundles — named override dicts. Anything not listed keeps the prompt's
# own default. A bundle CAN override basics (name/email/profile) but usually
# leaves those as defaults so the per-machine input still works.
# ---------------------------------------------------------------------------

BUNDLES: dict[str, dict[str, object]] = {
    "personal-mac": {
        "installCodingAgents": True,
        "installLlmTools": True,
        "installAiDesktopApps": True,
        "installPythonUvTools": True,
        "installJsCliTools": True,
        "installBitwarden": True,
        "installBrewApps": True,
        "installNetworkingTools": True,
        "installMediaTools": True,
        "backupMode": "smart",
    },
    "work-mac": {
        "installCodingAgents": True,
        "installPythonUvTools": True,
        "installJsCliTools": True,
        "installBrewApps": True,
        "backupMode": "smart",
        # deliberately off: installLlmTools, installAiDesktopApps, installBitwarden
    },
    "server-linux": {
        "installCodingAgents": True,
        "installPythonUvTools": True,
        "installJsCliTools": True,
        "installNetworkingTools": True,
        "backupMode": "smart",
        # GUI / desktop flags stay off; noRoot stays false (needs sudo to apt-get).
    },
    "minimal": {
        # Dotfiles only — every installX forced off so `chezmoi apply` in CI /
        # Docker does the minimum work possible. Note this overrides the
        # prompt-level defaults (which have coding-agents / python-uv /
        # js-cli turned ON for fresh personal machines, and backupMode=smart).
        "installCodingAgents": False,
        "installLlmTools": False,
        "installAiDesktopApps": False,
        "installPythonUvTools": False,
        "installJsCliTools": False,
        "installDotnetTools": False,
        "installIacTools": False,
        "installBitwarden": False,
        "installBrewApps": False,
        "installInputMethod": False,
        "installNetworkingTools": False,
        "installMediaTools": False,
        "useChineseMirror": False,
        "gitleaksAllRepos": False,
        "backupMode": "off",
        "allowPartialFailure": False,
        "noRoot": False,
    },
    "custom": {
        # Alias for "no overrides applied" — user ticks everything themselves.
    },
}


# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

@dataclass
class Preflight:
    chezmoi: str | None
    git: str | None
    ssh_hint: str | None                # how we detected SSH is ready (or None)
    source_exists: bool
    os_name: str
    is_tty: bool


def _detect_ssh() -> str | None:
    """Return a short hint describing why we think SSH-to-github is configured,
    or None if we can't tell. We accept several signals because the user may
    keep keys under non-canonical names and route them via ~/.ssh/config or
    its Include'd fragments."""
    # (1) Canonical default keys.
    for k in SSH_DEFAULT_KEYS:
        if k.exists():
            return f"default key at {k}"
    # (2) ~/.ssh/config (or an Include'd file under ~/.ssh/config.d/) with a
    # `Host github…` stanza → user is routing a custom key.
    config_texts: list[str] = []
    for root in (SSH_CONFIG, *((SSH_DIR / "config.d").glob("*") if (SSH_DIR / "config.d").is_dir() else ())):
        if root.is_file():
            try:
                config_texts.append(root.read_text(errors="replace"))
            except OSError:
                pass
    joined = "\n".join(config_texts)
    if re.search(r"(?mi)^\s*Host\s+[\w.\-\* ]*github", joined):
        return "~/.ssh/config routes github.com"
    # (3) Any loaded key in the agent (default or via IdentityAgent socket).
    try:
        r = subprocess.run(["ssh-add", "-l"], capture_output=True, text=True, timeout=3)
        if r.returncode == 0 and r.stdout.strip():
            return "ssh-agent has keys loaded"
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def detect() -> Preflight:
    import platform
    return Preflight(
        chezmoi=shutil.which("chezmoi"),
        git=shutil.which("git"),
        ssh_hint=_detect_ssh(),
        source_exists=(CHEZMOI_SOURCE_DIR / ".git").is_dir(),
        os_name={"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), platform.system().lower()),
        is_tty=sys.stdin.isatty() and sys.stdout.isatty(),
    )


def print_preflight(pf: Preflight) -> None:
    t = Table(title="Preflight", show_header=False, box=None, padding=(0, 2))
    t.add_column(); t.add_column()
    t.add_row("chezmoi", "✓ " + pf.chezmoi if pf.chezmoi else "✗ [red]not found[/red]")
    t.add_row("git", "✓ " + pf.git if pf.git else "✗ [red]not found[/red]")
    t.add_row("SSH", f"✓ {pf.ssh_hint}" if pf.ssh_hint else "✗ [yellow]no signal found[/yellow]")
    t.add_row("chezmoi source", "✓ present (re-init mode)" if pf.source_exists else "– fresh init")
    console.print(t)
    console.print()


def install_chezmoi_interactive(os_name: str) -> str:
    """Offer to install chezmoi via the canonical one-liner; return new path."""
    if not questionary.confirm("chezmoi not found. Install via get.chezmoi.io/lb?", default=True).ask():
        console.print("[red]chezmoi is required; aborting.[/red]")
        sys.exit(1)
    target = Path.home() / ".local" / "bin"
    target.mkdir(parents=True, exist_ok=True)
    subprocess.check_call(
        "curl -fsLS --retry 3 --retry-delay 5 get.chezmoi.io/lb | sh",
        shell=True,
        env={**os.environ, "BINDIR": str(target)},
    )
    path = shutil.which("chezmoi") or str(target / "chezmoi")
    console.print(f"[green]chezmoi installed at {path}[/green]\n")
    return path


def ensure_ssh_key_interactive() -> Path | None:
    """Offer to generate an ed25519 key; return path or None if user declined."""
    if not questionary.confirm(
        "No SSH key found. Generate ~/.ssh/id_ed25519 for GitHub (SSH clone)?",
        default=True,
    ).ask():
        return None
    key_path = Path.home() / ".ssh" / "id_ed25519"
    key_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    email = questionary.text(
        "Email to tag the SSH key with:",
        default="daviddwlee84@gmail.com",
    ).ask() or "daviddwlee84@gmail.com"
    subprocess.check_call(["ssh-keygen", "-t", "ed25519", "-C", email, "-f", str(key_path), "-N", ""])
    pub = key_path.with_suffix(".pub").read_text().strip()
    console.print(Panel(
        f"[bold]Add this public key to GitHub → Settings → SSH keys:[/bold]\n\n{pub}\n\n"
        f"Open: https://github.com/settings/ssh/new",
        title="SSH key generated",
        border_style="green",
    ))
    questionary.press_any_key_to_continue("Press any key once you've added the key to GitHub...").ask()
    return key_path


# ---------------------------------------------------------------------------
# Prompting flow
# ---------------------------------------------------------------------------

def ask_bundle() -> str:
    choices = [
        questionary.Choice(
            title=f"{name:<14} — {summary}",
            value=name,
        )
        for name, summary in [
            ("personal-mac", "full personal setup (AI desktop apps, LLM tools, Brewfile)"),
            ("work-mac",     "safer: coding agents + dev tooling, no personal AI apps"),
            ("server-linux", "headless linux — coding agents, networking, dev tooling"),
            ("minimal",      "dotfiles only, no installX flags"),
            ("custom",       "no overrides — tick every feature yourself"),
        ]
    ]
    return questionary.select(
        "Pick a bundle:",
        choices=choices,
        default=choices[0],
    ).ask() or "custom"


def ask_basics(pf: Preflight, overrides: dict[str, object]) -> dict[str, object]:
    # profile: auto-detect on Darwin; ask ubuntu_desktop vs ubuntu_server on Linux
    default_profile = "macos" if pf.os_name == "darwin" else "ubuntu_server"
    if pf.os_name == "darwin":
        profile = "macos"
        console.print(f"[dim]profile → {profile} (auto-detected)[/dim]")
    else:
        profile = questionary.select(
            "Which profile?",
            choices=["ubuntu_server", "ubuntu_desktop"],
            default=overrides.get("profile", default_profile),
        ).ask() or default_profile

    name = questionary.text(
        "Your full name:",
        default=str(overrides.get("name", _default_for("name"))),
    ).ask() or _default_for("name")

    email = questionary.text(
        "Your git email:",
        default=str(overrides.get("email", _default_for("email"))),
    ).ask() or _default_for("email")

    return {"profile": profile, "name": name, "email": email}


def resolve_basics_non_interactive(
    pf: Preflight,
    overrides: dict[str, object],
    *,
    name_flag: str | None,
    email_flag: str | None,
    profile_flag: str | None,
) -> dict[str, object]:
    """Non-interactive basics: flag → bundle override → embedded default → OS auto-detect."""
    if profile_flag:
        profile = profile_flag
    elif "profile" in overrides:
        profile = overrides["profile"]
    else:
        profile = "macos" if pf.os_name == "darwin" else "ubuntu_server"
    name = name_flag or overrides.get("name") or _default_for("name")
    email = email_flag or overrides.get("email") or _default_for("email")
    return {"profile": profile, "name": name, "email": email}


def resolve_features_non_interactive(pf: Preflight, overrides: dict[str, object]) -> dict[str, bool]:
    """Non-interactive features: bundle override → embedded default, skipping darwin-only on Linux."""
    result: dict[str, bool] = {}
    for p in PROMPTS:
        if p.kind != "bool" or p.hidden:
            continue
        if p.darwin_only and pf.os_name != "darwin":
            continue
        result[p.key] = bool(overrides.get(p.key, p.default))
    return result


def ask_features(pf: Preflight, overrides: dict[str, object]) -> dict[str, bool]:
    """Grouped multi-select. Returns {key: bool} for every non-basics bool prompt."""
    feature_prompts = [p for p in PROMPTS if p.kind == "bool" and not p.hidden
                       and (pf.os_name == "darwin" or not p.darwin_only)]

    groups: dict[str, list[Prompt]] = {}
    for p in feature_prompts:
        groups.setdefault(p.group, []).append(p)

    # Build one flat checkbox preserving group order, with group headers as
    # disabled separator rows (purely visual).
    choices: list[questionary.Choice] = []
    for group, prompts in groups.items():
        choices.append(questionary.Separator(f"── {group} ──"))
        for p in prompts:
            initial = overrides.get(p.key, p.default)
            choices.append(questionary.Choice(
                title=f"{p.label}  — {p.desc}",
                value=p.key,
                checked=bool(initial),
            ))

    console.print()
    console.print("[bold]Feature flags[/bold] — Space to toggle, ↑/↓ to move, Enter to confirm.")
    selected_keys = questionary.checkbox(
        "Which features?",
        choices=choices,
    ).ask() or []

    result: dict[str, bool] = {}
    for p in feature_prompts:
        result[p.key] = p.key in selected_keys
    return result


def confirm_plan(answers: dict[str, object], argv: list[str]) -> bool:
    t = Table(title="Answers", show_header=False, box=None, padding=(0, 2))
    t.add_column("Key", style="cyan"); t.add_column("Value")
    for p in PROMPTS:
        if p.darwin_only and p.key not in answers:
            continue
        val = answers.get(p.key)
        style = "green" if val is True else ("dim" if val is False else "")
        t.add_row(p.key, f"[{style}]{val}[/{style}]" if style else str(val))
    console.print(t)
    console.print()
    console.print(Panel(
        " ".join(argv),
        title="Command about to run",
        border_style="blue",
    ))
    return questionary.confirm("Proceed?", default=True).ask() or False


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def build_chezmoi_argv(
    answers: dict[str, object],
    *,
    chezmoi_bin: str,
    repo: str | None,
    use_ssh: bool,
    apply: bool,
    darwin: bool,
) -> list[str]:
    """Build the chezmoi init argv. The critical detail is that `chezmoi init`
    matches --promptBool / --promptString / --promptChoice flags by the PROMPT
    TEXT (3rd arg to promptXOnce in the template), NOT the key name. That's
    why every Prompt carries a prompt_text field and we use it here as the
    flag key."""
    argv: list[str] = [chezmoi_bin, "init"]
    if repo:
        argv.append(repo)
    if use_ssh:
        argv.append("--ssh")
    if apply:
        argv.append("--apply")
    by_key = {p.key: p for p in PROMPTS}
    # String + choice prompts (basics).
    for key in ("email", "name"):
        if key in answers:
            argv += ["--promptString", f"{by_key[key].prompt_text}={answers[key]}"]
    if "profile" in answers:
        argv += ["--promptChoice", f"{by_key['profile'].prompt_text}={answers['profile']}"]
    # Non-basics choice prompts (e.g. discordChannel).
    for p in PROMPTS:
        if p.kind != "choice" or p.hidden:
            continue
        if p.darwin_only and not darwin:
            continue
        if p.key not in answers:
            continue
        argv += ["--promptChoice", f"{p.prompt_text}={answers[p.key]}"]
    # Bool prompts — skip darwin-only on linux (chezmoi never evaluates them there).
    for p in PROMPTS:
        if p.kind != "bool" or p.hidden:
            continue
        if p.darwin_only and not darwin:
            continue
        if p.key not in answers:
            continue
        val_str = "true" if answers[p.key] else "false"
        argv += ["--promptBool", f"{p.prompt_text}={val_str}"]
    return argv


def run_chezmoi(argv: list[str]) -> int:
    console.print(f"[dim]$ {' '.join(argv)}[/dim]")
    console.rule("[bold]chezmoi output[/bold]")
    rc = subprocess.call(argv)
    console.rule()
    return rc


def print_recap(answers: dict[str, object], rc: int) -> None:
    enabled = [p.label for p in PROMPTS if p.kind == "bool" and not p.hidden and answers.get(p.key)]
    panel_body = (
        f"{'✓' if rc == 0 else '✗'} chezmoi init exit={rc}\n"
        f"✓ {len(enabled)} of {sum(1 for p in PROMPTS if p.kind == 'bool' and not p.hidden)} feature groups enabled\n"
        f"\nEnabled:\n  " + ("\n  ".join(enabled) if enabled else "(none)")
        + "\n\nNext:\n  • Review with: chezmoi diff\n"
          "  • Upgrade later with: just upgrade-all\n"
          "  • Fleet-apply to other hosts with: just fleet-apply"
    )
    console.print(Panel(
        panel_body,
        title="Summary",
        border_style="green" if rc == 0 else "red",
    ))


# ---------------------------------------------------------------------------
# Doctor: schema parity check
# ---------------------------------------------------------------------------

def doctor_scan(source_dir: Path) -> tuple[dict[str, str], set[str], dict[str, str]]:
    """Return (tmpl: {key: prompt_text}, dockerfile_keys, script: {key: prompt_text})."""
    tmpl = (source_dir / ".chezmoi.toml.tmpl").read_text()
    tmpl_pairs: dict[str, str] = {}
    for k, txt in re.findall(
        r'prompt(?:String|Bool|Choice)Once\s+\.\s+"(\w+)"\s+"([^"]+)"', tmpl):
        tmpl_pairs[k] = txt

    dockerfile = (source_dir / "Dockerfile").read_text()
    def _arg_to_camel(s: str) -> str:
        parts = s.lower().split("_")
        return parts[0] + "".join(p.title() for p in parts[1:])
    docker_args = re.findall(r"ARG\s+CHEZMOI_(\w+)\s*=", dockerfile)
    docker_keys = {_arg_to_camel(a) for a in docker_args if a.lower() != "repo"}

    script_pairs = {p.key: p.prompt_text for p in PROMPTS}
    return tmpl_pairs, docker_keys, script_pairs


def doctor_report(source_dir: Path) -> int:
    tmpl, docker, script = doctor_scan(source_dir)
    all_keys = set(tmpl) | docker | set(script)

    rows = []
    drift = False
    for k in sorted(all_keys):
        in_t = "✓" if k in tmpl else "[red]✗[/red]"
        in_d = "✓" if k in docker else "[yellow]✗[/yellow]"
        in_s = "✓" if k in script else "[red]✗[/red]"
        if not (k in tmpl and k in docker and k in script):
            drift = True
        text_note = ""
        # Prompt-text mismatches are critical — chezmoi init matches on the text.
        if k in tmpl and k in script and tmpl[k] != script[k]:
            drift = True
            text_note = f"[red]text mismatch[/red]"
        rows.append((k, in_t, in_d, in_s, text_note))

    t = Table(title="Prompt schema parity")
    t.add_column("key"); t.add_column(".chezmoi.toml.tmpl")
    t.add_column("Dockerfile"); t.add_column("dotfiles_init.py")
    t.add_column("notes")
    for row in rows:
        t.add_row(*row)
    console.print(t)

    if drift:
        console.print("[red]Drift detected — update the missing files so all three agree.[/red]")
        console.print("[dim]Prompt-text mismatches are especially important — chezmoi init\n"
                      "matches --promptBool flags by the full prompt text, not the key.[/dim]")
        return 1
    console.print("[green]All three surfaces agree (keys + prompt texts).[/green]")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _default_for(key: str) -> object:
    for p in PROMPTS:
        if p.key == key:
            return p.default
    raise KeyError(key)


@dataclass
class InitCmd:
    """Interactive wrapper around `chezmoi init`.

    With --yes (and optionally --bundle / --name / --email / --profile) the
    flow becomes fully non-interactive: no TTY required, no prompts shown.
    Suitable for Docker / CI. Missing basics fall back to bundle overrides,
    then embedded defaults, then OS auto-detection for profile."""

    repo: Annotated[str, tyro.conf.arg(help="Chezmoi repo arg (omit on re-init)")] = DEFAULT_REPO
    bundle: Annotated[str | None, tyro.conf.arg(help="Skip the picker; use this bundle")] = None
    name: Annotated[str | None, tyro.conf.arg(help="Git full name (non-interactive override)")] = None
    email: Annotated[str | None, tyro.conf.arg(help="Git email (non-interactive override)")] = None
    profile: Annotated[str | None, tyro.conf.arg(help="Profile: macos|ubuntu_desktop|ubuntu_server (auto-detected if omitted)")] = None
    ssh: Annotated[bool, tyro.conf.arg(help="Force --ssh even if no key is present")] = False
    yes: Annotated[bool, tyro.conf.arg(help="Fully non-interactive: no prompts, no confirmation, assume defaults")] = False
    dry_run: Annotated[bool, tyro.conf.arg(help="Print the chezmoi command instead of running it")] = False
    no_apply: Annotated[bool, tyro.conf.arg(help="Render chezmoi.toml but skip `chezmoi apply` (for CI / Docker smoke tests)")] = False


@dataclass
class DoctorCmd:
    """Check that .chezmoi.toml.tmpl, Dockerfile, and this script agree on prompt keys."""

    source: Annotated[Path, tyro.conf.arg(help="Path to chezmoi source dir")] = CHEZMOI_SOURCE_DIR


@dataclass
class ListBundlesCmd:
    """List available bundles and their overrides."""


Command = (
    Annotated[InitCmd, tyro.conf.subcommand(name="init")]
    | Annotated[DoctorCmd, tyro.conf.subcommand(name="doctor")]
    | Annotated[ListBundlesCmd, tyro.conf.subcommand(name="list-bundles")]
)


def run_init(cmd: InitCmd) -> int:
    pf = detect()
    print_preflight(pf)

    # TTY is only required for interactive mode. --yes / --dry-run don't need one.
    if not cmd.yes and not cmd.dry_run and not pf.is_tty:
        console.print("[red]No TTY detected — cannot run interactive prompts.\n"
                      "If you piped this from curl, re-exec with `</dev/tty`.\n"
                      "For non-interactive use, pass --yes (and optionally --bundle / --name / --email / --profile).[/red]")
        return 2

    # Ensure chezmoi
    if pf.chezmoi:
        chezmoi_bin = pf.chezmoi
    elif cmd.yes:
        console.print("[yellow]chezmoi not found; installing silently...[/yellow]")
        chezmoi_bin = _install_chezmoi_silent()
    else:
        chezmoi_bin = install_chezmoi_interactive(pf.os_name)

    # Ensure ssh key (only matters for fresh init with --ssh clone)
    use_ssh = cmd.ssh or bool(pf.ssh_hint)
    if not pf.source_exists and use_ssh and not pf.ssh_hint:
        if cmd.yes:
            use_ssh = False  # silent HTTPS fallback in non-interactive mode
            console.print("[yellow]No SSH key; using HTTPS clone (non-interactive).[/yellow]")
        else:
            key = ensure_ssh_key_interactive()
            if key is None:
                use_ssh = False
                console.print("[yellow]Falling back to HTTPS clone (no SSH key).[/yellow]")

    # Bundle: flag → picker → default "minimal" under --yes (Docker/CI)
    if cmd.bundle:
        bundle_name = cmd.bundle
    elif cmd.yes:
        bundle_name = "minimal"
    else:
        bundle_name = ask_bundle()
    if bundle_name not in BUNDLES:
        console.print(f"[red]Unknown bundle: {bundle_name}[/red]")
        return 2
    overrides = dict(BUNDLES[bundle_name])
    console.print(f"[dim]Bundle: {bundle_name}[/dim]\n")

    # Basics & features — interactive prompts vs pure resolution.
    if cmd.yes:
        basics = resolve_basics_non_interactive(
            pf, overrides,
            name_flag=cmd.name, email_flag=cmd.email, profile_flag=cmd.profile,
        )
        features = resolve_features_non_interactive(pf, overrides)
    else:
        basics = ask_basics(pf, overrides)
        features = ask_features(pf, overrides)

    answers: dict[str, object] = {**basics, **features}

    argv = build_chezmoi_argv(
        answers,
        chezmoi_bin=chezmoi_bin,
        repo=None if pf.source_exists else cmd.repo,
        use_ssh=use_ssh,
        apply=not cmd.no_apply,
        darwin=(pf.os_name == "darwin"),
    )

    if not cmd.yes and not confirm_plan(answers, argv):
        console.print("[yellow]Aborted.[/yellow]")
        return 130

    if cmd.dry_run:
        console.print(Panel(" ".join(argv), title="dry-run", border_style="yellow"))
        return 0

    rc = run_chezmoi(argv)
    print_recap(answers, rc)
    return rc


def _install_chezmoi_silent() -> str:
    """Non-interactive chezmoi install; same one-liner as install_chezmoi_interactive."""
    target = Path.home() / ".local" / "bin"
    target.mkdir(parents=True, exist_ok=True)
    subprocess.check_call(
        "curl -fsLS --retry 3 --retry-delay 5 get.chezmoi.io/lb | sh",
        shell=True,
        env={**os.environ, "BINDIR": str(target)},
    )
    return shutil.which("chezmoi") or str(target / "chezmoi")


def run_doctor(cmd: DoctorCmd) -> int:
    if not cmd.source.exists():
        console.print(f"[red]Source dir not found: {cmd.source}[/red]")
        return 2
    return doctor_report(cmd.source)


def run_list_bundles(cmd: ListBundlesCmd) -> int:  # noqa: ARG001
    for name, overrides in BUNDLES.items():
        t = Table(title=name, show_header=False, box=None, padding=(0, 2))
        t.add_column(style="cyan"); t.add_column()
        for p in PROMPTS:
            if p.hidden or p.kind != "bool":
                continue
            v = overrides.get(p.key, p.default)
            origin = "(bundle)" if p.key in overrides else "(default)"
            t.add_row(p.key, f"{v} [dim]{origin}[/dim]")
        console.print(t); console.print()
    return 0


def main() -> int:
    cmd = tyro.cli(Command, default=InitCmd())
    if isinstance(cmd, InitCmd):
        return run_init(cmd)
    if isinstance(cmd, DoctorCmd):
        return run_doctor(cmd)
    if isinstance(cmd, ListBundlesCmd):
        return run_list_bundles(cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
