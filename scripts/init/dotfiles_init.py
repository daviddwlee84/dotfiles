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

The existing `.chezmoi.toml.tmpl` defines the prompt set (profile, email,
name, feature flags, and preferences). `chezmoi init` asks them sequentially, which works but
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

PROMPTS (below) is the SINGLE SOURCE OF TRUTH. The `gen` subcommand renders
the prompt block in `.chezmoi.toml.tmpl` and the ARG + flag blocks in
`Dockerfile` from it (between marker comments). `gen --check` (wired into
pre-commit) fails loudly if the on-disk files drift, so adding a prompt is
"edit PROMPTS, run `just gen-prompts`" rather than a manual three-file edit.

Invocation:
    # Fresh machine (via bootstrap.sh which installs uv + chezmoi first):
    curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash

    # Existing chezmoi source dir — re-apply with new answers:
    uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py

    # Regenerate template + Dockerfile from PROMPTS (or --check for drift):
    uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py gen
    uv run --script ~/.local/share/chezmoi/scripts/init/dotfiles_init.py gen --check
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tomllib
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
# Prompt schema — THE single source of truth.
#
# `.chezmoi.toml.tmpl` (prompt block) and `Dockerfile` (ARG + flag block) are
# GENERATED from PROMPTS by the `gen` subcommand. To add / change a prompt:
#   1. Edit PROMPTS below (key, kind, prompt_text, default, condition, comment).
#   2. Run `just gen-prompts` (or `dotfiles_init.py gen`) to regenerate the
#      template + Dockerfile between their marker regions.
# `gen --check` (wired into pre-commit) fails if the on-disk files drift.
# ---------------------------------------------------------------------------

PromptType = Literal["string", "bool", "choice"]


@dataclass(frozen=True)
class When:
    """Declarative gate for a prompt — the decision-tree primitive.

    Each dimension is a set of allowed values; an empty set means
    "unconstrained". Values WITHIN a dimension are OR'd, dimensions are
    AND'd together. The dimensions map onto chezmoi template facts:

      - ``os``      -> ``.chezmoi.os``   ("darwin" / "linux")
      - ``arch``    -> ``.chezmoi.arch`` ("amd64" / "arm64")
      - ``profile`` -> the init-time ``$profile`` local (NOT ``.profile``,
                       which doesn't exist yet while .chezmoi.toml.tmpl renders)

    A single ``When`` drives all three consumers (template conditional, TUI
    gating, Dockerfile is unconditional) so they can never disagree.
    """
    os: frozenset[str] = frozenset()
    profile: frozenset[str] = frozenset()
    arch: frozenset[str] = frozenset()

    def matches(self, os_name: str, profile: object, arch: str) -> bool:
        if self.os and os_name not in self.os:
            return False
        if self.profile and profile not in self.profile:
            return False
        if self.arch and arch not in self.arch:
            return False
        return True

    def to_go(self) -> str:
        """Render the Go-template boolean expression WITHOUT the surrounding
        ``{{ if }}`` — e.g. ``eq .chezmoi.os "darwin"`` or
        ``or (eq $profile "macos") (eq $profile "ubuntu_desktop")``."""
        dim_exprs: list[str] = []
        for var, values in (
            (".chezmoi.os", self.os),
            (".chezmoi.arch", self.arch),
            ("$profile", self.profile),
        ):
            if not values:
                continue
            eqs = ['eq %s "%s"' % (var, v) for v in sorted(values)]
            if len(eqs) == 1:
                dim_exprs.append(eqs[0])
            else:
                dim_exprs.append("or " + " ".join("(%s)" % e for e in eqs))
        if not dim_exprs:
            return ""
        if len(dim_exprs) == 1:
            return dim_exprs[0]
        return "and " + " ".join("(%s)" % e for e in dim_exprs)


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
    # the key-name form silently fails over to interactive prompt.
    #
    # Since `gen` now RENDERS the template + Dockerfile from this field, the
    # prompt text is authored here exactly once.
    prompt_text: str = ""
    choices: tuple[str, ...] = ()     # for kind=choice
    # Conditionality: when `condition` is set, the prompt is only asked on
    # hosts matching it; on non-matching hosts the template bakes `else_value`
    # directly (no prompt) and the TUI hides the option.
    condition: When | None = None
    else_value: object = None
    # The bilingual doc block emitted as `#` comments above the prompt in the
    # generated .chezmoi.toml.tmpl. Lines are stored WITHOUT the leading "# ".
    comment: str = ""
    hidden: bool = False              # basics (name/email/profile) handled specially


# Order matters — reflects both the UI order AND the order prompts are
# rendered into the generated .chezmoi.toml.tmpl block.
# prompt_text is the 3rd argument to promptXOnce; chezmoi init's
# `--promptBool "<text>=..."` matches on it.
#
# Profile -> (os, form-factor):
#   macos=darwin/GUI · ubuntu_desktop=linux/GUI · ubuntu_server,centos_server=linux/headless
_DESKTOP_PROFILES = frozenset({"macos", "ubuntu_desktop"})

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
           "Claude Code, Pi/OMP with pia presets, OpenCode, Cursor, Copilot, Gemini, etc.",
           default=True,
           prompt_text="Install coding agents (Claude Code, Pi, Oh My Pi, pia presets, OpenCode, Cursor, Copilot, Gemini, etc.)",
           comment="是否安裝 coding agents (Claude Code, Pi/OMP + pia presets, OpenCode, Cursor, Copilot, Gemini, etc.)"),
    Prompt("installLlmTools", "bool", "Coding agents & AI",
           "Local LLM tools",
           "Ollama, LiteLLM, llmfit and matching local models.",
           default=False,
           prompt_text="Install local LLM tools (Ollama, LiteLLM, llmfit, models)",
           comment="是否安裝本地 LLM tools (Ollama, LiteLLM, llmfit, models)"),
    Prompt("installSummarize", "bool", "Coding agents & AI",
           "summarize CLI",
           "steipete/summarize — YouTube / podcast / web / PDF → LLM summary, "
           "defaulting to 繁體中文 output. Reuses an already-authenticated coding "
           "CLI (--cli claude/codex/gemini), so no extra API key is needed.",
           default=False,
           prompt_text="Install summarize (YouTube/web/PDF summarizer CLI)",
           comment="是否安裝 summarize (YouTube/網頁/PDF 摘要 CLI，預設輸出繁體中文)"),
    Prompt("installAiDesktopApps", "bool", "Coding agents & AI",
           "AI desktop apps (macOS)",
           "Claude, ChatGPT, OpenCode, Antigravity, Codex, Ollama app via Brewfile.",
           default=False,
           condition=When(os=frozenset({"darwin"})), else_value=False,
           prompt_text="Install AI desktop apps via macOS Homebrew Brewfile (Claude, ChatGPT, OpenCode, Antigravity, Codex, Ollama app)",
           comment="是否安裝 macOS AI desktop apps via Homebrew Brewfile (Claude, ChatGPT, OpenCode, Antigravity, Codex, Ollama app)"),
    Prompt("agentSounds", "choice", "Coding agents & AI",
           "Agent completion feedback",
           "none = silent; notify = desktop banner (apprise); "
           "peon = game voice lines + peon's own overlay (peon-ping); both = banner + voice.",
           default="notify",
           prompt_text="Agent completion feedback (none|notify|peon|both)",
           choices=("none", "notify", "peon", "both"),
           condition=When(profile=_DESKTOP_PROFILES), else_value="none",
           comment=("Agent 完成任務時的提示方式。只控制「掛不掛 hook」——\n"
                    "peon CLI 只要裝了 coding agents 就會裝，隨時可以手動玩。\n"
                    "none   = 安靜，不掛任何 hook\n"
                    "notify = 現況：notify.sh -> apprise -> 桌面通知橫幅\n"
                    "peon   = peon-ping 遊戲語音 + 它自己的 overlay 橫幅（預設 sc2_scv：Job's finished!）\n"
                    "both   = 兩者都掛（apprise 橫幅 + 語音 + peon overlay，會有兩個橫幅）\n"
                    "headless（server）一律 none：沒有音效裝置也沒有通知 daemon。\n"
                    "peon 的音量/音效包/通知樣式由 `peon` CLI 自己管，chezmoi 不碰，\n"
                    "所以隨便調都不會產生 chezmoi diff。見 docs/tools/agent-sounds.md")),

    # --- Dev tooling -----------------------------------------------------
    Prompt("installPythonUvTools", "bool", "Dev tooling",
           "Python CLI tools (via uv)",
           "mlflow, sqlit-tui, tmuxp and other Python CLIs.",
           default=True,
           prompt_text="Install Python CLI tools via uv (mlflow, sqlit-tui, tmuxp, etc.)",
           comment="是否安裝 Python CLI tools via uv (mlflow, sqlit-tui, tmuxp, etc.)"),
    Prompt("installJsCliTools", "bool", "Dev tooling",
           "JS / npm CLI tools",
           "Standalone node CLIs like readability-cli.",
           default=True,
           prompt_text="Install standalone JS/npm CLI utilities (readability-cli for terminal web reader, etc.)",
           comment="是否安裝 standalone JS/npm CLI utilities (readability-cli for `readnode`, etc.)"),
    Prompt("installDotnetTools", "bool", "Dev tooling",
           ".NET SDK + dotnet tools",
           ".NET SDK via mise plus global tools (azure-cost-cli, etc.).",
           default=False,
           prompt_text="Install .NET SDK via mise and dotnet global tools (azure-cost-cli, etc.)",
           comment="是否安裝 .NET SDK (via mise) 與 .NET global tools (azure-cost-cli, 等)"),
    Prompt("installExtraRuntimes", "bool", "Dev tooling",
           "Extra mise runtimes (rust, bun, ruby)",
           "Rust toolchain + cargo tools, bun, ruby + gem tools via mise (~1.8GB). Node is always installed regardless (nvim LSP / npm agents need it).",
           default=True,
           prompt_text="Install extra mise runtimes (rust, bun, ruby) and their cargo/gem tools",
           comment=("是否安裝額外的 mise runtimes (rust, bun, ruby) 與對應的 cargo/gem 工具（~1.8GB）。\n"
                    "Node 永遠會裝（nvim LSP / npm-based coding agents 硬依賴），不受此 flag 影響。\n"
                    "false 時 mise [tools] 只留 node，且 ansible TAGS 會剔除 rust_cargo_tools /\n"
                    "ruby_gem_tools（沒有 toolchain 跑了也只會失敗）。lean cloud VM / CI 建議 false。")),
    Prompt("installAuditd", "bool", "System & apps",
           "Linux audit framework (auditd)",
           "Installs auditd + a baseline rule set (identity / sudoers / sshd_config / privileged-exec watches). Linux only — no-op on macOS. See docs/sysadmin/auditd.md.",
           default=False,
           condition=When(os=frozenset({"linux"})), else_value=False,
           prompt_text="Install Linux audit framework (auditd) + baseline rules (identity / sudoers / sshd_config / privileged-exec watches)",
           comment=("是否安裝 Linux Audit framework (auditd) + 基準規則集（identity / sudoers /\n"
                    "sshd_config / privileged-exec watch）。Linux only — macOS 自動跳過（macOS 用\n"
                    "OpenBSM，不是 auditd），所以在 darwin 上不問也直接 false。\n"
                    "詳見 docs/sysadmin/auditd.md 與 docs/playbooks/auditd.md。")),
    Prompt("installHomelabTools", "bool", "System & apps",
           "Homelab hardware-monitoring tools",
           "Installs physical-server hardware CLIs (lm-sensors, smartmontools, ipmitool, nvme-cli, storcli), each gated on the matching hardware being present. Linux only; no-op on macOS and inside VMs. See docs/sysadmin/hardware.md.",
           default=False,
           condition=When(os=frozenset({"linux"})), else_value=False,
           prompt_text="Install homelab hardware-monitoring tools (lm-sensors / smartmontools / ipmitool / nvme-cli / storcli), gated on detected hardware",
           comment=("是否安裝 homelab 硬體監控 CLI（lm-sensors / smartmontools / ipmitool /\n"
                    "nvme-cli / storcli）。每個工具還會依實際偵測到的硬體決定要不要裝（沒有\n"
                    "MegaRAID 控制器就不裝 storcli、沒有 NVMe 就不裝 nvme-cli…），避免裝一堆\n"
                    "用不到的東西。Linux only — macOS 與 VM 內自動跳過。\n"
                    "詳見 docs/sysadmin/hardware.md。")),
    Prompt("installResilioSync", "bool", "System & apps",
           "Resilio Sync (P2P file sync)",
           "Installs Resilio Sync for AirDrop-style cross-system transfer and phone→NAS photo backup. macOS: GUI app via Homebrew cask. Linux (desktop + server): headless daemon (no GUI) run as a per-user systemd service, configured via WebUI at 127.0.0.1:8888. See docs/tools/resilio-sync.md.",
           default=False,
           prompt_text="Install Resilio Sync (P2P file sync — GUI cask on macOS, headless WebUI daemon on Linux/servers)",
           comment=("是否安裝 Resilio Sync（P2P 檔案同步，類似 AirDrop 的跨機傳輸、手機照片備份到\n"
                    "NAS）。macOS 走 Homebrew cask 的 GUI app；Linux（桌機與 server 皆同）沒有 GUI，\n"
                    "以 per-user systemd service 跑成背景 daemon，透過 127.0.0.1:8888 的 WebUI 設定\n"
                    "（headless server 用 SSH tunnel）。詳見 docs/tools/resilio-sync.md。")),
    Prompt("installWakeOnLan", "bool", "System & apps",
           "Wake-on-LAN (power this box on remotely)",
           "Arms this machine's wired NIC(s) to wake from a magic packet and persists it across reboots via a wol@<iface> systemd unit (installs ethtool). Linux only; no-op on macOS and inside VMs. Wake-from-full-shutdown (S5) also needs BIOS 'Power On By PCI-E' on + 'ErP Ready' off. The sender side is the `wake` CLI / wakeonlan. See docs/sysadmin/wake-on-lan.md.",
           default=False,
           condition=When(os=frozenset({"linux"})), else_value=False,
           prompt_text="Arm Wake-on-LAN on wired NIC(s) so this box can be powered on remotely by a magic packet (persisted via a systemd unit)",
           comment=("是否啟用 Wake-on-LAN（被動端）：把有線網卡 arm 成可被 magic packet 喚醒，\n"
                    "並用 wol@<iface> 的 systemd unit 讓設定在重開機後自動套用（會裝 ethtool）。\n"
                    "Linux only — macOS 與 VM 內自動跳過。從「完全關機 (S5)」喚醒還需要 BIOS\n"
                    "開 'Power On By PCI-E'、關 'ErP Ready'（韌體設定 Ansible 無法代勞）。\n"
                    "主動端（發封包）用 `wake` CLI 或 wakeonlan。詳見 docs/sysadmin/wake-on-lan.md。")),
    Prompt("installIacTools", "bool", "Dev tooling",
           "Infrastructure-as-Code tools",
           "Azure CLI, Terraform, OpenTofu.",
           default=False,
           prompt_text="Install Infrastructure-as-Code tools (Azure CLI, Terraform, OpenTofu)",
           comment="是否安裝 Infrastructure-as-Code 工具 (Azure CLI, Terraform, OpenTofu)"),
    Prompt("installMediaTools", "bool", "Dev tooling",
           "Media / AV CLI tools",
           "ffmpeg, ImageMagick, exiftool, libvips. ffmpeg is also vhs's runtime dep.",
           default=False,
           prompt_text="Install media/AV CLI tools (ffmpeg, ImageMagick, exiftool, libvips)",
           comment=("是否安裝影音/媒體 CLI 工具 (ffmpeg, ImageMagick, exiftool, libvips)\n"
                    "ffmpeg 也是 vhs 的 runtime 依賴；裝了影音包之後 vhs 才能真正錄製。詳見 docs/tools/ffmpeg.md")),

    # --- System & apps ---------------------------------------------------
    Prompt("installBitwarden", "bool", "System & apps",
           "Bitwarden CLI + Desktop",
           "@bitwarden/cli with SSH Agent integration and Zsh completion. On ubuntu_desktop / macOS profiles, also installs Bitwarden Desktop (snap or .deb fallback on Linux, Homebrew Cask on macOS).",
           default=False,
           prompt_text="Install Bitwarden CLI (and Desktop on ubuntu_desktop/macOS — snap or .deb on Linux, Cask on macOS) with SSH Agent integration",
           comment=("是否安裝 Bitwarden CLI（+ SSH Agent 自動偵測 + Zsh completion）；在\n"
                    "ubuntu_desktop / macOS profile 上同時也會裝 Bitwarden Desktop（snap 優先、\n"
                    ".deb fallback / Homebrew Cask）。詳細邏輯見 docs/playbooks/linux-gui-apps.md\n"
                    "和 dot_ansible/roles/bitwarden/。")),
    Prompt("installMediaControl", "bool", "System & apps",
           "System media-control CLIs",
           "nowplaying-cli + switchaudio-osx (macOS), playerctl (Linux). Unlocks full sysplay/sysnow + output-device switching; built-in sysvol/sysmute work without it.",
           default=False,
           prompt_text="Install system media-control CLIs (nowplaying-cli/switchaudio-osx on macOS, playerctl on Linux) for the sys* shell helpers",
           comment=("是否安裝系統媒體控制 CLI（macOS: nowplaying-cli, switchaudio-osx；Linux: playerctl）。\n"
                    "搭配 sys* shell helpers（sysvol/sysmute/sysplay/sysnow）。不裝也能用 built-in\n"
                    "的 sysvol/sysmute（音量/靜音）；裝了才有完整 sysplay/sysnow（播放控制/查正在播放）。\n"
                    "詳見 docs/tools/media-control.md。")),
    Prompt("installCalibre", "bool", "System & apps",
           "calibre (e-book toolkit)",
           "calibre + its CLIs (ebook-meta/ebook-convert). Powers Kindle .mobi/.azw/.azw3 metadata previews in yazi via view-ebook. Heavy GUI app (~hundreds of MB); the preview is best-effort and also works if calibre is already installed by hand.",
           default=False,
           prompt_text="Install calibre (e-book manager; enables .mobi/.azw/.azw3 metadata previews in yazi)",
           comment=("是否安裝 calibre（電子書管理 + ebook-meta/ebook-convert CLI）。\n"
                    "yazi 透過 view-ebook 用 ebook-meta 預覽 Kindle .mobi/.azw/.azw3 的中繼資料\n"
                    "（書名/作者/簡介）。calibre 是較肥的 GUI app（數百 MB）；不裝也能用其他格式的\n"
                    "預覽，且若你已手動裝過 calibre，預覽會自動生效。詳見 docs/tools/yazi-previews.md。")),
    Prompt("installMole", "bool", "System & apps",
           "mole (macOS cleanup / analyze / purge)",
           "brew formula `mole` (`mo`). `mo purge` reclaims dev build artifacts "
           "(node_modules, target, .venv), `mo analyze` is a disk explorer, "
           "`mo clean` clears caches. macOS-only upstream. See docs/tools/mole.md.",
           default=False,
           condition=When(os=frozenset({"darwin"})), else_value=False,
           prompt_text="Install mole (macOS cleanup, disk analyze, dev build-artifact purge)",
           comment=("是否安裝 mole（macOS 系統清理 / 磁碟分析 / 清除 dev build artifacts）。\n"
                    "`mo purge` 掃 node_modules/target/.venv 這類建置產物，`mo analyze` 是磁碟\n"
                    "瀏覽器，`mo clean` 清快取（務必先 --dry-run）。上游只支援 macOS：install.sh\n"
                    "拒絕非 darwin，cmd/analyze 是 //go:build darwin，所以 Linux 直接 false。\n"
                    "受管的 ~/.config/mole/whitelist 會「取代」上游預設白名單，別直接刪。\n"
                    "詳見 docs/tools/mole.md。")),
    Prompt("installBrewApps", "bool", "System & apps",
           "Homebrew GUI apps",
           "Terminals, browsers, utilities via Brewfile (excl. AI desktop). Desktop-class profiles only (macos / ubuntu_desktop).",
           default=False,
           condition=When(profile=_DESKTOP_PROFILES), else_value=False,
           prompt_text="Install general GUI apps via Homebrew Brewfile (terminals, browsers, utilities, etc.; excludes AI desktop apps)",
           comment=("是否安裝一般 GUI apps via Homebrew Brewfile (terminals, browsers, utilities, etc.; excludes AI desktop apps)\n"
                    "Desktop-class only（macos / ubuntu_desktop）；headless server 沒有 GUI，直接 false。")),
    Prompt("installGamingApps", "bool", "System & apps",
           "Gaming apps",
           "Steam for desktop profiles: Homebrew cask on macOS, Valve apt repo on Ubuntu Desktop.",
           default=False,
           condition=When(profile=_DESKTOP_PROFILES), else_value=False,
           prompt_text="Install gaming apps (Steam)",
           comment=("是否安裝遊戲相關桌面應用（目前先裝 Steam）。Desktop-class only（macos /\n"
                    "ubuntu_desktop）；macOS 走 Homebrew Cask，Ubuntu Desktop 走 Valve 官方 apt repo /\n"
                    "steam-launcher。headless server 直接 false。")),
    Prompt("installInputMethod", "bool", "System & apps",
           "Traditional Chinese IME",
           "McBopomofo + RIME for zh-TW input. Desktop-class profiles only (macos / ubuntu_desktop).",
           default=False,
           condition=When(profile=_DESKTOP_PROFILES), else_value=False,
           prompt_text="Install Traditional Chinese input methods (McBopomofo, RIME)",
           comment=("是否安裝繁體中文輸入法 (McBopomofo + RIME)\n"
                    "Desktop-class only（macos / ubuntu_desktop）；headless server 沒有 GUI，直接 false。")),
    Prompt("discordChannel", "choice", "System & apps",
           "Discord install channel",
           "ubuntu_desktop only (macOS → Brewfile cask, ubuntu_server → skipped). flatpak (recommended): Flathub auto-updates via `flatpak update`. deb: official .deb, manual re-deploy each release. none: skip.",
           default="flatpak",
           condition=When(profile=frozenset({"ubuntu_desktop"})), else_value="none",
           prompt_text="Discord install channel (flatpak|deb|none)",
           choices=("flatpak", "deb", "none"),
           comment=("Discord channel: 哪一條安裝路徑（ubuntu_desktop only — macOS 走 Brewfile cask，\n"
                    "ubuntu_server 沒有 GUI 不需要）\n"
                    "  - flatpak: 推薦，Flathub 走 com.discordapp.Discord，自動更新\n"
                    "  - deb:     官方 .deb，每次版本更新需手動跑 `chezmoi apply` 重抓\n"
                    "  - none:    完全不裝，留給使用者自行處理\n"
                    "詳細決策 + sandbox 副作用見 docs/playbooks/linux-gui-apps.md\n"
                    "注意: 這裡引用前面定義的 $profile local variable（不是 .profile，因為\n"
                    ".chezmoi.toml.tmpl 正在產生 .profile，init 階段 .profile 還不存在）")),
    Prompt("installNiri", "bool", "System & apps",
           "niri Wayland compositor",
           "Scrollable-tiling Wayland compositor, built from source (cargo). ubuntu_desktop only — not in Ubuntu 24.04 apt. Installs binary + GDM session/systemd files; NVIDIA gets a VRAM application-profile automatically. See docs/playbooks/niri.md.",
           default=False,
           condition=When(profile=frozenset({"ubuntu_desktop"})), else_value=False,
           prompt_text="Install niri (scrollable-tiling Wayland compositor, built from source)",
           comment=("是否安裝 niri (scrollable-tiling Wayland 合成器)，從源碼 cargo build。ubuntu_desktop\n"
                    "only — macOS 無 Wayland、ubuntu_server 無 GUI，皆直接 false。NVIDIA 在現代驅動上開箱\n"
                    "即用，niri role 會自動寫入 VRAM application-profile（GLVidHeapReuseRatio=0）。\n"
                    "詳見 dot_ansible/roles/niri/ 與 docs/playbooks/niri.md")),
    Prompt("installNetworkingTools", "bool", "System & apps",
           "Networking CLI tools",
           "nmap, mtr, httpie, gping, trippy.",
           default=False,
           prompt_text="Install networking CLI tools (nmap, mtr, httpie, gping, trippy, etc.)",
           comment="是否安裝網路診斷工具 (nmap, mtr, httpie, gping, trippy, etc.)"),
    Prompt("installTunnelTools", "bool", "System & apps",
           "Tunnel tools (ngrok, cloudflared)",
           "Expose localhost / SSH reverse tunnels via ngrok and cloudflared.",
           default=False,
           prompt_text="Install tunnel tools (ngrok, cloudflared — expose localhost, SSH tunnels)",
           comment="是否安裝 tunnel 工具 (ngrok, cloudflared) — expose localhost / SSH reverse tunnel"),
    Prompt("installTailscale", "bool", "System & apps",
           "Tailscale mesh VPN",
           "WireGuard mesh VPN. Deliberately separate from installTunnelTools "
           "(ngrok/cloudflared expose localhost to the PUBLIC internet; "
           "`tailscale serve` is the opposite — tailnet-only) and from "
           "installNetworkingTools (a read-only diagnostics bundle; joining a "
           "mesh and reconfiguring DNS should not be a side effect of wanting "
           "nmap). Linux only: official apt/yum repo. macOS gets it from the "
           "`tailscale-app` cask under installBrewApps, so this is a no-op there. "
           "Install-only — `tailscale up` stays manual. Pairs with the `tsnet` "
           "CLI and the `tv tailnet` channel.",
           default=False,
           prompt_text="Install Tailscale (mesh VPN; Linux apt/yum repo — macOS uses the cask)",
           comment=("是否安裝 Tailscale (WireGuard mesh VPN)。\n"
                    "  Linux: 走官方 apt/yum repo (pkgs.tailscale.com)，install-only，\n"
                    "         不會自動 `tailscale up`（需要互動登入）。\n"
                    "  macOS: 由 installBrewApps 的 `tailscale-app` cask 提供，這裡是 no-op。\n"
                    "  搭配 in-house CLI `tsnet`（ssh-config / serve）與 `tv tailnet` channel。\n"
                    "詳見 docs/tools/Tailscale.md 與 docs/tools/tsnet.md"),
           ),
    # --- Preferences -----------------------------------------------------
    Prompt("useChineseMirror", "bool", "Preferences",
           "Use China (GFW) mirrors",
           "Switch Homebrew / pip / npm / etc. to China-hosted mirrors.",
           default=False,
           prompt_text="Are you in China (behind GFW) and need to use mirrors",
           comment="是否在中國大陸 GFW 內，需要使用鏡像源"),
    Prompt("gitleaksAllRepos", "bool", "Preferences",
           "Gitleaks on all repos",
           "Scan secrets even for repos without .pre-commit-config.yaml.",
           default=False,
           prompt_text="Enable gitleaks for ALL git repos (not just those with .pre-commit-config.yaml)",
           comment="是否對所有 repo 啟用 gitleaks 掃描（包含沒有 .pre-commit-config.yaml 的 repo）"),
    Prompt("backupMode", "choice", "Preferences",
           "Backup mode for existing dotfiles",
           "smart = only files chezmoi will overwrite (uses `chezmoi status`); full = hardcoded allowlist (onboarding mode); off = skip.",
           default="smart",
           prompt_text="Backup mode for existing dotfiles (smart|full|off)",
           choices=("smart", "full", "off"),
           comment=("在 chezmoi apply 之前備份現有的 dotfiles。\n"
                    "smart = 只備份 chezmoi 將要覆蓋/刪除的檔案（用 `chezmoi status` 偵測）\n"
                    "full  = 備份固定 allowlist（onboard 第一次最保險）\n"
                    "off   = 完全跳過（CI / Docker / 一次性環境用）")),
    Prompt("allowPartialFailure", "bool", "Preferences",
           "Allow partial Ansible failures",
           "Continue other roles if one role fails.",
           default=False,
           prompt_text="Allow partial Ansible failures (continue installing other tools if one role fails)",
           comment="允許 Ansible 部分失敗（逐 tag 執行，單一 role 失敗不影響其餘）"),
    Prompt("noRoot", "bool", "Preferences",
           "No sudo / root access",
           "Skip all system package installations (user-level tools only). Linux only — macOS users are always admins.",
           default=False,
           condition=When(os=frozenset({"linux"})), else_value=False,
           prompt_text="No sudo/root access - skip all system package installations",
           comment=("沒有 sudo/root 權限，只安裝 user-level 工具 (mise, cargo, gem, uv, npm)\n"
                    "Linux only — macOS 上一律有 admin 權限，darwin 直接 false 不問。")),
    Prompt("motdStyle", "choice", "Preferences",
           "SSH login banner style",
           "figlet (~6 lines, ~5ms) | fastfetch-slim (figlet + fastfetch slim, ~10 lines, ~80ms) | fastfetch-full (full distro logo + everything, ~22 lines, ~150ms). Runtime override: MOTD_STYLE in ~/.zshrc.adhoc.",
           default="figlet",
           prompt_text="SSH login banner style (figlet|fastfetch-slim|fastfetch-full)",
           choices=("figlet", "fastfetch-slim", "fastfetch-full"),
           comment=("SSH login banner (~/.zlogin) 樣式 — 詳見 docs/zsh/motd.md\n"
                    "  - figlet:         單行 figlet hostname + metadata（~6 行，~5ms，預設）\n"
                    "  - fastfetch-slim: figlet hostname + fastfetch 精簡版（~10 行，~80ms）\n"
                    "  - fastfetch-full: fastfetch 完整輸出含 distro logo（~22 行，~150ms）\n"
                    "Runtime override: 在 ~/.zshrc.adhoc 設 MOTD_STYLE=... 可即時切換無需 chezmoi init --force")),
    Prompt("primaryShell", "choice", "Preferences",
           "Primary interactive shell",
           "Decides which shell `chsh` switches to. Both ~/.zshrc and ~/.bashrc are deployed regardless (so the other shell still works ad-hoc). Bash side ships with oh-my-bash + ble.sh for UX close to zsh; on macOS the bash role brew-installs bash 5.x when bash is selected. See docs/shells/bash.md.",
           default="zsh",
           prompt_text="Primary interactive shell (zsh|bash)",
           choices=("zsh", "bash"),
           comment=("Primary interactive shell — decides which shell `chsh` switches to as the\n"
                    "login shell. Both ~/.zshrc and ~/.bashrc are deployed regardless (so the\n"
                    "other shell still works ad-hoc); only the login-shell switch is gated.\n"
                    "Bash side ships with oh-my-bash + ble.sh for a UX close to zsh; on macOS\n"
                    "the bash role also brew-installs bash 5.x (system bash 3.2 is too old for\n"
                    "OMB plugins) when bash is selected. See docs/shells/bash.md.")),
    Prompt("enableVimMode", "bool", "Preferences",
           "Vim mode in shells & tmux",
           "zsh-vi-mode plugin, bash `set -o vi`, ble.sh vi_imap/vi_nmap, tmux mode-keys vi, vim-tmux-navigator C-h/j/k/l. Does NOT touch Neovim or editor configs (VSCode/Cursor/Codex/OpenCode). Full catalog: docs/this_repo/vim-mode.md.",
           default=True,
           prompt_text="Enable vim-style modal editing in shells (zsh-vi-mode, set -o vi, ble.sh vi-mode) and tmux vim navigation (vim-tmux-navigator C-h/j/k/l, mode-keys vi); does NOT affect Neovim",
           comment=("Enable vim-style modal editing in shells (zsh-vi-mode plugin, bash `set -o vi`,\n"
                    "ble.sh vi_imap/vi_nmap keymap) and tmux vim navigation (mode-keys vi,\n"
                    "copy-mode-vi table, vim-tmux-navigator C-h/j/k/l). Default true (this repo's\n"
                    "historical behavior). Set false for non-vim users / CI / Docker.\n"
                    "Does NOT touch Neovim (~/.config/nvim/) — Neovim is always vim-flavored.\n"
                    "Editor configs (VSCode/Cursor/Antigravity/Codex/OpenCode) are also not gated.\n"
                    "Full catalog of what changes: docs/this_repo/vim-mode.md")),
)


# ---------------------------------------------------------------------------
# Bundles — named override dicts. Anything not listed keeps the prompt's
# own default. A bundle CAN override basics (name/email/profile) but usually
# leaves those as defaults so the per-machine input still works.
# ---------------------------------------------------------------------------

BUNDLES: dict[str, dict[str, object]] = {
    "personal-mac": {
        "installCodingAgents": True,
        "installMole": True,
        "installLlmTools": True,
        "installSummarize": True,
        "installAiDesktopApps": True,
        "installPythonUvTools": True,
        "installJsCliTools": True,
        "installExtraRuntimes": True,
        "installBitwarden": True,
        "installBrewApps": True,
        "installNetworkingTools": True,
        "installMediaTools": True,
        "backupMode": "smart",
    },
    "work-mac": {
        "installCodingAgents": True,
        "installMole": True,
        "installSummarize": True,
        "installPythonUvTools": True,
        "installJsCliTools": True,
        "installExtraRuntimes": True,
        "installBrewApps": True,
        "installGamingApps": False,
        "backupMode": "smart",
        # deliberately off: installLlmTools, installAiDesktopApps, installBitwarden, installGamingApps
    },
    "server-linux": {
        "installCodingAgents": True,
        "installPythonUvTools": True,
        "installJsCliTools": True,
        "installExtraRuntimes": True,
        "installNetworkingTools": True,
        "installAuditd": True,
        "installHomelabTools": True,
        "installWakeOnLan": True,
        "installGamingApps": False,
        "backupMode": "smart",
        # GUI / desktop flags stay off; noRoot stays false (needs sudo to apt-get).
    },
    "cloud-vm": {
        # Lean throwaway / cloud dev VM: ergonomic shell + tmux + nvim +
        # coding agents, nothing heavier. Pairs with `just az-dev-vm`
        # (scripts/azure/dev_vm.py) which passes --bundle cloud-vm during the
        # remote non-interactive bootstrap. Compared to server-linux this
        # drops uv/js/networking/auditd extras AND the ~1.8GB of extra mise
        # runtimes (rust/bun/ruby + dotnet) — node stays (nvim/agents).
        "installCodingAgents": True,
        "installLlmTools": False,
        "installSummarize": False,
        "installPythonUvTools": False,
        "installJsCliTools": False,
        "installExtraRuntimes": False,
        "installDotnetTools": False,
        "installIacTools": False,
        "installBitwarden": False,
        "installNetworkingTools": False,
        "installMediaTools": False,
        "installGamingApps": False,
        "installAuditd": False,
        "installHomelabTools": False,
        "installWakeOnLan": False,
        "backupMode": "off",  # fresh VM — nothing worth backing up
    },
    "minimal": {
        # Dotfiles only — every installX forced off so `chezmoi apply` in CI /
        # Docker does the minimum work possible. Note this overrides the
        # prompt-level defaults (which have coding-agents / python-uv /
        # js-cli turned ON for fresh personal machines, and backupMode=smart).
        "installCodingAgents": False,
        "installLlmTools": False,
        "installSummarize": False,
        "installAiDesktopApps": False,
        "installPythonUvTools": False,
        "installJsCliTools": False,
        "installExtraRuntimes": False,
        "installDotnetTools": False,
        "installIacTools": False,
        "installBitwarden": False,
        "installBrewApps": False,
        "installGamingApps": False,
        "installInputMethod": False,
        "installNiri": False,
        "installNetworkingTools": False,
        "installMediaTools": False,
        "installCalibre": False,
        "installAuditd": False,
        "installHomelabTools": False,
        "installWakeOnLan": False,
        "useChineseMirror": False,
        "gitleaksAllRepos": False,
        "backupMode": "off",
        "allowPartialFailure": False,
        "noRoot": False,
        # No audio device and no notification daemon in CI / Docker, and the
        # peon-ping hook would fire on every turn for nothing.
        "agentSounds": "none",
        # Vim mode off: CI / Docker shells don't benefit from modal editing,
        # and emacs keymap matches what most non-interactive automation
        # expects (Ctrl+L = clear, Ctrl+H = backspace, no mode flicker).
        "enableVimMode": False,
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
    arch: str                           # normalized to chezmoi's .chezmoi.arch (amd64/arm64)
    is_tty: bool
    chezmoi_is_snap: bool = False       # resolved chezmoi lives under /snap (see _resolve_chezmoi)


def _normalize_arch(machine: str) -> str:
    """Map platform.machine() onto chezmoi's GOARCH-style .chezmoi.arch."""
    return {
        "x86_64": "amd64", "amd64": "amd64",
        "aarch64": "arm64", "arm64": "arm64",
    }.get(machine.lower(), machine.lower())


def _prompt_applies(p: Prompt, os_name: str, profile: object, arch: str) -> bool:
    """True if `p` should be asked on this host (no condition = always)."""
    return p.condition is None or p.condition.matches(os_name, profile, arch)


def read_current_config() -> dict[str, object]:
    """Return the `[data]` table of ~/.config/chezmoi/chezmoi.toml as a dict
    of {prompt_key: current_value}, or {} if the config doesn't exist / can't
    be parsed. This is what `reconfigure` seeds the TUI with so you toggle
    deltas from the live state instead of from prompt defaults."""
    if not CHEZMOI_CONFIG.exists():
        return {}
    try:
        return tomllib.loads(CHEZMOI_CONFIG.read_text()).get("data", {}) or {}
    except (OSError, tomllib.TOMLDecodeError):
        return {}


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
    chezmoi_bin, is_snap = _resolve_chezmoi()
    return Preflight(
        chezmoi=chezmoi_bin,
        git=shutil.which("git"),
        ssh_hint=_detect_ssh(),
        source_exists=(CHEZMOI_SOURCE_DIR / ".git").is_dir(),
        os_name={"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), platform.system().lower()),
        arch=_normalize_arch(platform.machine()),
        is_tty=sys.stdin.isatty() and sys.stdout.isatty(),
        chezmoi_is_snap=is_snap,
    )


def print_preflight(pf: Preflight) -> None:
    t = Table(title="Preflight", show_header=False, box=None, padding=(0, 2))
    t.add_column(); t.add_column()
    if pf.chezmoi and pf.chezmoi_is_snap:
        chezmoi_cell = f"⚠ [yellow]{pf.chezmoi} (snap — stdin/stdout bug; will install ~/.local/bin/chezmoi)[/yellow]"
    elif pf.chezmoi:
        chezmoi_cell = "✓ " + pf.chezmoi
    else:
        chezmoi_cell = "✗ [red]not found[/red]"
    t.add_row("chezmoi", chezmoi_cell)
    t.add_row("git", "✓ " + pf.git if pf.git else "✗ [red]not found[/red]")
    t.add_row("SSH", f"✓ {pf.ssh_hint}" if pf.ssh_hint else "✗ [yellow]no signal found[/yellow]")
    t.add_row("chezmoi source", "✓ present (re-init mode)" if pf.source_exists else "– fresh init")
    console.print(t)
    console.print()


def _resolve_chezmoi() -> tuple[str | None, bool]:
    """Resolve the chezmoi binary, preferring ~/.local/bin over a snap install.

    The snap build of chezmoi has a long-standing stdin/stdout
    `permission denied` bug (chezmoi.io troubleshooting FAQ) that breaks this
    repo's modify_ / run_ scripts, and chezmoi upstream recommends installing
    via get.chezmoi.io instead. So we prefer ~/.local/bin/chezmoi, and when the
    only binary on PATH lives under /snap we flag it for replacement.

    Returns (path or None, is_snap)."""
    local = Path.home() / ".local" / "bin" / "chezmoi"
    if local.exists():
        return str(local), False
    found = shutil.which("chezmoi")
    if not found:
        return None, False
    return found, found.startswith("/snap/") or "/snap/" in found


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
    # Prefer the freshly-installed ~/.local/bin binary over any snap/brew one
    # that PATH might resolve first.
    local = target / "chezmoi"
    path = str(local) if local.exists() else (shutil.which("chezmoi") or str(local))
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
            ("cloud-vm",     "lean throwaway VM — shell + tmux + nvim + coding agents only"),
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
        # All non-macOS profile choices (keep server first as the common default).
        linux_choices = ["ubuntu_server", "ubuntu_desktop", "centos_server"]
        profile = questionary.select(
            "Which profile?",
            choices=linux_choices,
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


def resolve_features_non_interactive(
    pf: Preflight, overrides: dict[str, object], profile: object
) -> dict[str, bool]:
    """Non-interactive features: bundle override → embedded default, skipping
    prompts whose `condition` doesn't match this host."""
    result: dict[str, bool] = {}
    for p in PROMPTS:
        if p.kind != "bool" or p.hidden:
            continue
        if not _prompt_applies(p, pf.os_name, profile, pf.arch):
            continue
        result[p.key] = bool(overrides.get(p.key, p.default))
    return result


def _applicable_choice_prompts(pf: Preflight, profile: object):
    """Yield the non-hidden choice prompts chezmoi will actually prompt for on
    this host. Gated prompts (e.g. discordChannel on ubuntu_desktop) are baked
    to their else_value by the template elsewhere, so we must NOT pre-answer
    them off-host."""
    for p in PROMPTS:
        if p.kind != "choice" or p.hidden:
            continue
        if not _prompt_applies(p, pf.os_name, profile, pf.arch):
            continue
        yield p


def resolve_choices_non_interactive(
    pf: Preflight, overrides: dict[str, object], profile: object
) -> dict[str, object]:
    """Non-interactive choice prompts: bundle override → embedded default."""
    result: dict[str, object] = {}
    for p in _applicable_choice_prompts(pf, profile):
        result[p.key] = overrides.get(p.key, p.default)
    return result


def ask_choices(
    pf: Preflight, overrides: dict[str, object], profile: object
) -> dict[str, object]:
    """Interactive single-select for each applicable non-basics choice prompt
    (backupMode, motdStyle, primaryShell, and discordChannel on ubuntu_desktop).
    Without this, chezmoi falls back to prompting them itself mid-apply."""
    result: dict[str, object] = {}
    prompts = list(_applicable_choice_prompts(pf, profile))
    if not prompts:
        return result
    console.print()
    console.print("[bold]Other choices[/bold]")
    for p in prompts:
        default = overrides.get(p.key, p.default)
        answer = questionary.select(
            f"{p.label}?",
            choices=list(p.choices),
            default=default if default in p.choices else None,
        ).ask()
        result[p.key] = answer if answer is not None else default
    return result


def ask_features(pf: Preflight, overrides: dict[str, object], profile: object) -> dict[str, bool]:
    """Grouped multi-select. Returns {key: bool} for every applicable bool prompt."""
    feature_prompts = [p for p in PROMPTS if p.kind == "bool" and not p.hidden
                       and _prompt_applies(p, pf.os_name, profile, pf.arch)]

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
        if p.key not in answers:
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
    prompt: bool = False,
) -> list[str]:
    """Build the chezmoi init argv. The critical detail is that `chezmoi init`
    matches --promptBool / --promptString / --promptChoice flags by the PROMPT
    TEXT (3rd arg to promptXOnce in the template), NOT the key name. That's
    why every Prompt carries a prompt_text field and we use it here as the
    flag key. We only emit flags for prompts present in `answers` (i.e. the
    ones applicable to this host); chezmoi harmlessly ignores extras anyway.

    `prompt=True` adds `--prompt`, which FORCES the `prompt*Once` template
    functions to prompt again. This is mandatory when re-initializing an
    already-configured machine: without it, chezmoi reads the existing value
    from ~/.config/chezmoi/chezmoi.toml's [data] and our --promptX flags are
    silently ignored (so the answers never actually change). With --prompt,
    every Once call re-fires and our flags satisfy them non-interactively."""
    argv: list[str] = [chezmoi_bin, "init"]
    if repo:
        argv.append(repo)
    if use_ssh:
        argv.append("--ssh")
    if apply:
        argv.append("--apply")
    if prompt:
        argv.append("--prompt")
    by_key = {p.key: p for p in PROMPTS}
    # String + choice prompts (basics).
    for key in ("email", "name"):
        if key in answers:
            argv += ["--promptString", f"{by_key[key].prompt_text}={answers[key]}"]
    if "profile" in answers:
        argv += ["--promptChoice", f"{by_key['profile'].prompt_text}={answers['profile']}"]

    # Emit a flag for EVERY non-hidden prompt — not just the host-applicable
    # ones. Host-gated prompts whose `condition` doesn't match this machine are
    # absent from `answers`; we still pass their `else_value` so the flag set is
    # COMPLETE. This matters under --prompt (re-init / reconfigure), which
    # re-fires *all* promptXOnce: if the template's `$profile` ever differs from
    # the profile we resolved (e.g. a desktop→server migration mid-reconfigure),
    # a gated promptBoolOnce can still execute, and without a matching flag it
    # falls through to an interactive prompt mid-apply (the very leak this fixes:
    # `Install general GUI apps…?` / `Install Traditional Chinese IME?`). chezmoi
    # silently ignores any flag whose prompt the template never calls, so the
    # extra flags are harmless on hosts where the else-branch is baked instead.
    def _flag_value(p: Prompt) -> object | None:
        if p.key in answers:
            return answers[p.key]
        if p.condition is not None:        # gated-off here → bake else_value
            return p.else_value
        return None                        # applicable but unanswered → skip

    # Non-basics choice prompts (e.g. discordChannel, backupMode, motdStyle).
    for p in PROMPTS:
        if p.kind != "choice" or p.hidden:
            continue
        val = _flag_value(p)
        if val is None:
            continue
        argv += ["--promptChoice", f"{p.prompt_text}={val}"]
    # Bool prompts.
    for p in PROMPTS:
        if p.kind != "bool" or p.hidden:
            continue
        val = _flag_value(p)
        if val is None:
            continue
        val_str = "true" if val else "false"
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
# Generator — PROMPTS is the single source of truth; render the prompt blocks
# in .chezmoi.toml.tmpl + Dockerfile from it. `gen --check` (pre-commit/CI)
# fails if the on-disk files drift.
# ---------------------------------------------------------------------------

# Marker pairs delimiting the regions `gen` owns. Everything outside them is
# hand-authored (umask, $profile setup, [diff]/[status], the RUN prefix, etc.).
TMPL_BEGIN = "# >>> dotfiles-init:prompts (generated by scripts/init/dotfiles_init.py gen) — DO NOT EDIT BY HAND >>>"
TMPL_END = "# <<< dotfiles-init:prompts <<<"
DOCKER_ARGS_BEGIN = "# >>> dotfiles-init:args (generated by scripts/init/dotfiles_init.py gen) — DO NOT EDIT BY HAND >>>"
DOCKER_ARGS_END = "# <<< dotfiles-init:args <<<"
DOCKER_RUN_BEGIN = "# >>> dotfiles-init:init-run (generated by scripts/init/dotfiles_init.py gen) — DO NOT EDIT BY HAND >>>"
DOCKER_RUN_END = "# <<< dotfiles-init:init-run <<<"
README_BEGIN = "<!-- dotfiles-init:prompts (coverage-checked by scripts/init/dotfiles_init.py gen --check) -->"
README_END = "<!-- /dotfiles-init:prompts -->"

# Docker devbox build defaults — deliberately leaner than the prompt defaults
# so the CI image builds fast (skip the heavy coding-agent / uv / js installs,
# no backup). Anything not listed uses the prompt's own default.
DOCKER_ARG_DEFAULTS: dict[str, object] = {
    "installCodingAgents": False,
    "installPythonUvTools": False,
    "installJsCliTools": False,
    "installExtraRuntimes": False,  # skip ~1.8GB of mise runtimes in CI images
    "backupMode": "off",
    "discordChannel": "none",
}
# Basics get Docker-specific placeholder identities.
DOCKER_BASICS: dict[str, str] = {
    "profile": "ubuntu_server",
    "email": "docker@example.com",
    "name": "Docker User",
}


def _key_to_arg(key: str) -> str:
    """camelCase chezmoi key -> CHEZMOI_UPPER_SNAKE Docker ARG name."""
    return "CHEZMOI_" + re.sub(r"(?<!^)(?=[A-Z])", "_", key).upper()


def _prompt_once_call(p: Prompt) -> str:
    """The `{{ promptXOnce ... }}` assignment value for a prompt."""
    if p.kind == "bool":
        return "{{ promptBoolOnce . \"%s\" \"%s\" %s }}" % (
            p.key, p.prompt_text, "true" if p.default else "false")
    if p.kind == "choice":
        choices = " ".join('"%s"' % c for c in p.choices)
        return "{{ promptChoiceOnce . \"%s\" \"%s\" (list %s) \"%s\" | quote }}" % (
            p.key, p.prompt_text, choices, p.default)
    return "{{ promptStringOnce . \"%s\" \"%s\" \"%s\" | quote }}" % (
        p.key, p.prompt_text, p.default)


def _go_literal(kind: PromptType, value: object) -> str:
    """Render an else_value as a TOML literal baked into the template."""
    if kind == "bool":
        return "true" if value else "false"
    return '"%s"' % value


def render_tmpl_body() -> str:
    """Render the generated .chezmoi.toml.tmpl prompt block (non-hidden prompts)."""
    lines: list[str] = []
    for p in PROMPTS:
        if p.hidden:
            continue
        for cl in p.comment.split("\n") if p.comment else []:
            lines.append(("# " + cl).rstrip())
        assign = "%s = %s" % (p.key, _prompt_once_call(p))
        if p.condition is None:
            lines.append(assign)
        else:
            lines.append("{{ if %s -}}" % p.condition.to_go())
            lines.append(assign)
            lines.append("{{ else -}}")
            lines.append("%s = %s" % (p.key, _go_literal(p.kind, p.else_value)))
            lines.append("{{ end -}}")
    return "\n".join(lines)


def render_docker_args_body() -> str:
    """Render the Dockerfile ARG block (basics + every non-hidden prompt + repo)."""
    lines: list[str] = []
    for key in ("profile", "email", "name"):
        v = DOCKER_BASICS[key]
        quoted = '"%s"' % v if " " in v else v
        lines.append("ARG %s=%s" % (_key_to_arg(key), quoted))
    for p in PROMPTS:
        if p.hidden:
            continue
        v = DOCKER_ARG_DEFAULTS.get(p.key, p.default)
        v_str = ("true" if v else "false") if p.kind == "bool" else str(v)
        lines.append("ARG %s=%s" % (_key_to_arg(p.key), v_str))
    lines.append("ARG CHEZMOI_REPO=%s" % DEFAULT_REPO)
    return "\n".join(lines)


def render_docker_run_body() -> str:
    """Render the full `chezmoi init` RUN instruction with all prompt flags."""
    flags: list[str] = [
        '--promptChoice "%s=${CHEZMOI_PROFILE}"' % _by_key("profile").prompt_text,
        '--promptString "%s=${CHEZMOI_EMAIL}"' % _by_key("email").prompt_text,
        '--promptString "%s=${CHEZMOI_NAME}"' % _by_key("name").prompt_text,
    ]
    for p in PROMPTS:
        if p.hidden:
            continue
        flag = "--promptChoice" if p.kind == "choice" else "--promptBool"
        flags.append('%s "%s=${%s}"' % (flag, p.prompt_text, _key_to_arg(p.key)))
    head = (
        'RUN export PATH="$HOME/.local/bin:$PATH" && \\\n'
        "    ~/.local/bin/chezmoi init --apply --source=/tmp/dotfiles-source \\"
    )
    body = " \\\n".join("    " + f for f in flags)
    return head + "\n" + body


def _by_key(key: str) -> Prompt:
    for p in PROMPTS:
        if p.key == key:
            return p
    raise KeyError(key)


def _replace_region(text: str, begin: str, end: str, body: str) -> str:
    pattern = re.compile(re.escape(begin) + r"\n.*?\n" + re.escape(end), re.DOTALL)
    replacement = begin + "\n" + body + "\n" + end
    new_text, n = pattern.subn(lambda _m: replacement, text)
    if n != 1:
        raise SystemExit(
            f"gen: expected exactly one region {begin!r}…{end!r}, found {n}. "
            "Add the marker pair to the file first."
        )
    return new_text


def _rendered_files(source_dir: Path) -> dict[Path, str]:
    """Return {path: desired_full_contents} for every generated file."""
    tmpl_path = source_dir / ".chezmoi.toml.tmpl"
    docker_path = source_dir / "Dockerfile"
    tmpl = _replace_region(tmpl_path.read_text(), TMPL_BEGIN, TMPL_END, render_tmpl_body())
    docker = docker_path.read_text()
    docker = _replace_region(docker, DOCKER_ARGS_BEGIN, DOCKER_ARGS_END, render_docker_args_body())
    docker = _replace_region(docker, DOCKER_RUN_BEGIN, DOCKER_RUN_END, render_docker_run_body())
    return {tmpl_path: tmpl, docker_path: docker}


def _readme_coverage(source_dir: Path) -> list[str]:
    """Return prompt keys missing from the README marker region (empty = ok)."""
    readme = (source_dir / "README.md").read_text()
    m = re.search(re.escape(README_BEGIN) + r"(.*?)" + re.escape(README_END), readme, re.DOTALL)
    if not m:
        return ["<README marker region not found>"]
    region = m.group(1)
    return [p.key for p in PROMPTS if not p.hidden and p.key not in region]


def gen_report(source_dir: Path, *, check: bool) -> int:
    if not source_dir.exists():
        console.print(f"[red]Source dir not found: {source_dir}[/red]")
        return 2
    rendered = _rendered_files(source_dir)
    missing = _readme_coverage(source_dir)

    if not check:
        for path, contents in rendered.items():
            path.write_text(contents)
            console.print(f"[green]wrote[/green] {path}")
        if missing:
            console.print(f"[yellow]README is missing prompt keys: {', '.join(missing)} "
                          "(coverage-only; add them to the marked table).[/yellow]")
        else:
            console.print("[green]README prompt-table coverage OK.[/green]")
        return 0

    drift = False
    for path, contents in rendered.items():
        if path.read_text() != contents:
            drift = True
            console.print(f"[red]drift:[/red] {path} differs from PROMPTS — run "
                          "`just gen-prompts` and commit.")
    if missing:
        drift = True
        console.print(f"[red]README missing prompt keys:[/red] {', '.join(missing)}")
    if drift:
        return 1
    console.print("[green]All generated surfaces are in sync with PROMPTS.[/green]")
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
class GenCmd:
    """Regenerate the prompt blocks in .chezmoi.toml.tmpl + Dockerfile from PROMPTS.

    PROMPTS is the single source of truth; this renders the marker-delimited
    regions in the template and Dockerfile. Use --check (no writes) in
    pre-commit / CI to fail on drift."""

    source: Annotated[Path, tyro.conf.arg(help="Path to chezmoi source dir")] = CHEZMOI_SOURCE_DIR
    check: Annotated[bool, tyro.conf.arg(help="Verify on-disk matches PROMPTS; non-zero exit on drift (no writes)")] = False


@dataclass
class DoctorCmd:
    """Alias for `gen --check` — verify generated surfaces are in sync with PROMPTS."""

    source: Annotated[Path, tyro.conf.arg(help="Path to chezmoi source dir")] = CHEZMOI_SOURCE_DIR


@dataclass
class ReconfigureCmd:
    """Change settings on an ALREADY-initialized machine.

    Seeds the same grouped TUI from your CURRENT ~/.config/chezmoi/chezmoi.toml
    values (so you toggle deltas, not start from prompt defaults), then runs
    `chezmoi init --apply --prompt` so the new answers actually take effect.
    (`--prompt` is required: without it chezmoi keeps the existing [data]
    values and the override flags are silently ignored.)

    Non-interactive single-key changes for scripts / fleet (space-separated):
        reconfigure --set installLlmTools=true motdStyle=figlet --yes"""

    set: Annotated[
        tuple[str, ...],
        tyro.conf.arg(help="space-separated key=value override(s). Non-interactive when combined with --yes"),
    ] = ()
    yes: Annotated[bool, tyro.conf.arg(help="Non-interactive: skip the TUI, apply current+--set values directly")] = False
    dry_run: Annotated[bool, tyro.conf.arg(help="Print the chezmoi command instead of running it")] = False
    no_apply: Annotated[bool, tyro.conf.arg(help="Render chezmoi.toml but skip `chezmoi apply`")] = False


@dataclass
class ListBundlesCmd:
    """List available bundles and their overrides."""


Command = (
    Annotated[InitCmd, tyro.conf.subcommand(name="init")]
    | Annotated[ReconfigureCmd, tyro.conf.subcommand(name="reconfigure")]
    | Annotated[GenCmd, tyro.conf.subcommand(name="gen")]
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

    # Ensure chezmoi — prefer a non-snap binary (the snap build has a
    # stdin/stdout permission bug that breaks this repo's modify_/run_ scripts).
    if pf.chezmoi and not pf.chezmoi_is_snap:
        chezmoi_bin = pf.chezmoi
    elif pf.chezmoi_is_snap:
        console.print(f"[yellow]Found snap chezmoi at {pf.chezmoi}; the snap build has a "
                      "stdin/stdout permission bug that can break modify_/run_ scripts.[/yellow]")
        if cmd.yes or questionary.confirm(
            "Install the canonical chezmoi to ~/.local/bin (recommended)?", default=True
        ).ask():
            chezmoi_bin = _install_chezmoi_silent()
            console.print(f"[green]Using {chezmoi_bin}[/green]\n")
        else:
            chezmoi_bin = pf.chezmoi
            console.print("[yellow]Continuing with snap chezmoi.[/yellow]")
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

    # Re-init on an already-configured machine: seed from the LIVE config so
    # the TUI shows current values and untouched options aren't silently reset
    # to bundle/prompt defaults. Explicit --bundle still layers on top.
    if pf.source_exists:
        current = read_current_config()
        if current:
            overrides = {**current, **overrides}
            console.print("[dim]Seeded answers from current chezmoi.toml (re-init).[/dim]\n")

    # Basics & features — interactive prompts vs pure resolution.
    if cmd.yes:
        basics = resolve_basics_non_interactive(
            pf, overrides,
            name_flag=cmd.name, email_flag=cmd.email, profile_flag=cmd.profile,
        )
        features = resolve_features_non_interactive(pf, overrides, basics["profile"])
        choices = resolve_choices_non_interactive(pf, overrides, basics["profile"])
    else:
        basics = ask_basics(pf, overrides)
        features = ask_features(pf, overrides, basics["profile"])
        choices = ask_choices(pf, overrides, basics["profile"])

    answers: dict[str, object] = {**basics, **features, **choices}

    argv = build_chezmoi_argv(
        answers,
        chezmoi_bin=chezmoi_bin,
        repo=None if pf.source_exists else cmd.repo,
        use_ssh=use_ssh,
        apply=not cmd.no_apply,
        # On re-init the values already exist in [data]; --prompt forces the
        # promptXOnce calls to re-fire so our flags actually take effect.
        prompt=pf.source_exists,
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
    local = target / "chezmoi"
    return str(local) if local.exists() else (shutil.which("chezmoi") or str(local))


_TRUE_TOKENS = {"true", "1", "yes", "y", "on"}
_FALSE_TOKENS = {"false", "0", "no", "n", "off"}


def _coerce_set_value(p: Prompt, raw: str) -> object:
    """Coerce a --set string value to the prompt's type, raising ValueError on
    a bad bool token or an out-of-range choice."""
    if p.kind == "bool":
        low = raw.strip().lower()
        if low in _TRUE_TOKENS:
            return True
        if low in _FALSE_TOKENS:
            return False
        raise ValueError(f"{p.key}: expected a bool (true/false), got {raw!r}")
    if p.kind == "choice":
        if raw not in p.choices:
            raise ValueError(f"{p.key}: {raw!r} not in {list(p.choices)}")
        return raw
    return raw


def parse_set_overrides(pairs: tuple[str, ...]) -> dict[str, object]:
    """Parse `--set key=value` pairs into a typed override dict, validating
    each key against PROMPTS. Raises SystemExit with a friendly message on any
    unknown key or bad value."""
    by_key = {p.key: p for p in PROMPTS}
    out: dict[str, object] = {}
    for pair in pairs:
        if "=" not in pair:
            raise SystemExit(f"--set expects key=value, got {pair!r}")
        key, raw = pair.split("=", 1)
        key = key.strip()
        if key not in by_key:
            raise SystemExit(
                f"--set: unknown key {key!r}. Valid keys: "
                + ", ".join(p.key for p in PROMPTS)
            )
        try:
            out[key] = _coerce_set_value(by_key[key], raw)
        except ValueError as e:
            raise SystemExit(f"--set: {e}")
    return out


def _valid_profile(profile: object) -> bool:
    return profile in _by_key("profile").choices


def run_reconfigure(cmd: ReconfigureCmd) -> int:
    pf = detect()
    print_preflight(pf)

    if not pf.source_exists:
        console.print(
            "[red]No chezmoi source found — this machine isn't initialized yet.\n"
            "Run the init flow first (curl bootstrap or `just bootstrap-local`).[/red]"
        )
        return 2

    if pf.chezmoi and not pf.chezmoi_is_snap:
        chezmoi_bin = pf.chezmoi
    elif pf.chezmoi_is_snap:
        console.print(f"[yellow]Found snap chezmoi at {pf.chezmoi}; the snap build has a "
                      "stdin/stdout permission bug that can break modify_/run_ scripts.[/yellow]")
        if cmd.yes or questionary.confirm(
            "Install the canonical chezmoi to ~/.local/bin (recommended)?", default=True
        ).ask():
            chezmoi_bin = _install_chezmoi_silent()
            console.print(f"[green]Using {chezmoi_bin}[/green]\n")
        else:
            chezmoi_bin = pf.chezmoi
    else:
        console.print("[red]chezmoi not found on PATH; cannot reconfigure.[/red]")
        return 2

    # Seed from the live config, then layer --set overrides on top.
    current = read_current_config()
    set_overrides = parse_set_overrides(cmd.set)
    overrides: dict[str, object] = {**current, **set_overrides}

    # A stale/removed profile value (e.g. the retired "macos_intel") can't drive
    # the picker or be a valid --promptChoice; drop it so basics fall back to
    # OS auto-detect / re-pick.
    if "profile" in overrides and not _valid_profile(overrides["profile"]):
        console.print(
            f"[yellow]Current profile {overrides['profile']!r} is not a valid choice anymore; "
            "falling back to auto-detect.[/yellow]"
        )
        overrides.pop("profile")

    non_interactive = cmd.yes or not pf.is_tty
    if non_interactive and not cmd.yes:
        console.print("[yellow]No TTY detected — running non-interactively from current + --set values.[/yellow]")

    if non_interactive:
        basics = resolve_basics_non_interactive(
            pf, overrides, name_flag=None, email_flag=None, profile_flag=None,
        )
        features = resolve_features_non_interactive(pf, overrides, basics["profile"])
        choices = resolve_choices_non_interactive(pf, overrides, basics["profile"])
    else:
        basics = ask_basics(pf, overrides)
        features = ask_features(pf, overrides, basics["profile"])
        choices = ask_choices(pf, overrides, basics["profile"])

    answers: dict[str, object] = {**basics, **features, **choices}

    argv = build_chezmoi_argv(
        answers,
        chezmoi_bin=chezmoi_bin,
        repo=None,            # re-init: never re-clone, just re-render + apply
        use_ssh=False,
        apply=not cmd.no_apply,
        prompt=True,          # mandatory so the new values override [data]
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


def run_gen(cmd: GenCmd) -> int:
    return gen_report(cmd.source, check=cmd.check)


def run_doctor(cmd: DoctorCmd) -> int:
    return gen_report(cmd.source, check=True)


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
    if isinstance(cmd, ReconfigureCmd):
        return run_reconfigure(cmd)
    if isinstance(cmd, GenCmd):
        return run_gen(cmd)
    if isinstance(cmd, DoctorCmd):
        return run_doctor(cmd)
    if isinstance(cmd, ListBundlesCmd):
        return run_list_bundles(cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
