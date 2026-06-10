#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "tyro>=0.9",
#   "rich>=13.9",
#   "tomlkit>=0.13",
#   # questionary is NOT used here, but importing scripts/init/dotfiles_init.py
#   # (the PROMPTS/BUNDLES SSOT we reuse to build the remote non-interactive
#   # `chezmoi init` flag set) executes its top-level `import questionary`.
#   "questionary>=2.0",
# ]
# ///
"""az-dev-vm — one command from nothing to a usable Azure dev VM.

    up      az vm create (idempotent) -> auto-shutdown guardrail -> wait for
            SSH -> remote non-interactive `chezmoi init --apply` with the
            cloud-vm bundle -> register host in ~/.config/fleet/machines.toml
    down    delete the VM + its resources (whole RG when this VM is the only
            one in it) + de-register from the fleet inventory
    status  power state / public IP / size of every VM in the resource group
    ssh     resolve the public IP and exec ssh into the VM

Design notes (see docs/this_repo/az-dev-vm.md and
backlog/cloud-vm-provision-combo.md):

  - Idempotency key = fixed resource group + VM name. Re-running `up` never
    creates a second VM; it re-checks shutdown schedule, SSH and bootstrap.
  - Teardown symmetry is mandatory: a forgotten B2s with a 32GB disk costs
    money. `up` also enables `az vm auto-shutdown` (default 19:00 UTC) so
    even a forgotten VM stops billing compute at night.
  - GPU is a SEAM, not a CUDA toolchain: `--gpu` switches the size to an
    NC-series SKU and installs Microsoft's NvidiaGpuDriverLinux extension.
    CUDA/cudnn stay project-level (conda/uv) by design — see TODO.md's
    `CUDA / ML toolchain ansible role` entry for why we don't maintain one.
  - The remote bootstrap flag set is COMPUTED from scripts/init/
    dotfiles_init.py's PROMPTS/BUNDLES (the SSOT) — never hand-copied.
  - The controlling box needs `az` on PATH and a live `az login` session.
    The fleet `iac_tools` ansible role installs the CLI itself.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated

import tomlkit
import tyro
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

console = Console()

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULT_RG = "dev-vm-rg"
DEFAULT_NAME = "devbox-1"
DEFAULT_LOCATION = "japaneast"
DEFAULT_SIZE = "Standard_B2s"            # 2 vCPU / 4 GB — cheap daily driver
DEFAULT_SPOT_SIZE = "Standard_D2as_v5"   # B-series can't be Spot
DEFAULT_GPU_SIZE = "Standard_NC4as_T4_v3"  # 4 vCPU / T4 16GB — cheapest NC
DEFAULT_IMAGE = "Ubuntu2404"             # alias -> Canonical 24.04 LTS Gen2
DEFAULT_DISK_GB = 32
DEFAULT_SHUTDOWN_TIME = "1900"           # UTC HHMM for az vm auto-shutdown
DEFAULT_BUNDLE = "cloud-vm"
FLEET_CONFIG = Path.home() / ".config" / "fleet" / "machines.toml"

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent


# ---------------------------------------------------------------------------
# az helpers
# ---------------------------------------------------------------------------

def az(*args: str, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
    """Run an az CLI command, capturing stdout (JSON unless -o overridden)."""
    cmd = ["az", *args]
    if not quiet:
        console.print(f"[dim]$ {shlex.join(cmd)}[/dim]")
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def az_json(*args: str) -> object:
    out = az(*args, quiet=True).stdout.strip()
    return json.loads(out) if out else None


def preflight_az() -> None:
    if not shutil.which("az"):
        console.print(
            "[red]az CLI not found on PATH.[/red]\n"
            "Install it via the iac_tools ansible role "
            "(`just reconfigure -- --set installIacTools=true --yes`) or "
            "https://learn.microsoft.com/cli/azure/install-azure-cli"
        )
        raise SystemExit(2)
    probe = az("account", "show", check=False, quiet=True)
    if probe.returncode != 0:
        console.print("[red]Not logged in to Azure — run `az login` first.[/red]")
        raise SystemExit(2)
    acct = json.loads(probe.stdout)
    console.print(f"[dim]Azure subscription: {acct.get('name')} ({acct.get('id')})[/dim]")


def vm_exists(rg: str, name: str) -> bool:
    return az("vm", "show", "-g", rg, "-n", name, check=False, quiet=True).returncode == 0


def vm_public_ip(rg: str, name: str) -> str:
    res = az("vm", "show", "-d", "-g", rg, "-n", name, "--query", "publicIps", "-o", "tsv", quiet=True)
    ip = res.stdout.strip()
    if not ip:
        console.print(f"[red]VM {name} has no public IP (deallocated?). Try `az vm start -g {rg} -n {name}`.[/red]")
        raise SystemExit(1)
    return ip


# ---------------------------------------------------------------------------
# Bootstrap flag set — reuse the dotfiles_init SSOT
# ---------------------------------------------------------------------------

def _load_dotfiles_init():
    """Import scripts/init/dotfiles_init.py as a module (PROMPTS/BUNDLES SSOT)."""
    path = _REPO_ROOT / "scripts" / "init" / "dotfiles_init.py"
    spec = importlib.util.spec_from_file_location("dotfiles_init", path)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    # Must register BEFORE exec: @dataclass resolves string annotations via
    # sys.modules[cls.__module__] and crashes on an unregistered module.
    sys.modules["dotfiles_init"] = mod
    spec.loader.exec_module(mod)
    return mod


def build_remote_bootstrap_script(bundle: str) -> str:
    """Render the bash script piped to the VM over SSH.

    Installs chezmoi if missing, then runs a fully non-interactive
    `chezmoi init --apply` whose --promptBool/--promptChoice flag set is
    computed from PROMPTS + BUNDLES[bundle] for a linux/ubuntu_server host.
    Re-runs are safe: with an existing source dir we re-init WITHOUT the repo
    arg — promptXOnce reads the stored answers and chezmoi just re-applies.
    """
    mod = _load_dotfiles_init()
    if bundle not in mod.BUNDLES:
        console.print(f"[red]Unknown bundle {bundle!r}. Valid: {', '.join(mod.BUNDLES)}[/red]")
        raise SystemExit(2)
    overrides = dict(mod.BUNDLES[bundle])
    profile = overrides.get("profile", "ubuntu_server")

    answers: dict[str, object] = {
        "profile": profile,
        "name": overrides.get("name", mod._default_for("name")),
        "email": overrides.get("email", mod._default_for("email")),
    }
    for p in mod.PROMPTS:
        if p.hidden:
            continue
        if mod._prompt_applies(p, "linux", profile, "amd64"):
            answers[p.key] = overrides.get(p.key, p.default)

    def _argv(repo: str | None) -> str:
        argv = mod.build_chezmoi_argv(
            answers, chezmoi_bin="chezmoi", repo=repo, use_ssh=False, apply=True,
        )
        return shlex.join(argv)

    return f"""set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
echo "[az-dev-vm] bootstrap starting on $(hostname) ($(id -un))"
if ! command -v chezmoi >/dev/null 2>&1; then
    echo "[az-dev-vm] installing chezmoi to ~/.local/bin"
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
fi
if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    echo "[az-dev-vm] chezmoi source exists — re-applying (bundle answers already stored)"
    {_argv(None)}
else
    echo "[az-dev-vm] first init — bundle={bundle}"
    {_argv(mod.DEFAULT_REPO)}
fi
echo "[az-dev-vm] bootstrap done"
"""


# ---------------------------------------------------------------------------
# Fleet inventory registration
# ---------------------------------------------------------------------------

def register_fleet_host(name: str, ip: str, user: str, identity_file: Path | None) -> None:
    """Append/update a [[hosts]] entry in ~/.config/fleet/machines.toml."""
    if FLEET_CONFIG.exists():
        doc = tomlkit.parse(FLEET_CONFIG.read_text())
    else:
        FLEET_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        doc = tomlkit.document()
    hosts = doc.get("hosts")
    if hosts is None:
        hosts = tomlkit.aot()
        doc["hosts"] = hosts

    for entry in hosts:
        if entry.get("name") == name:
            entry["hostname"] = ip
            entry["user"] = user
            if identity_file:
                entry["identity_file"] = str(identity_file)
            FLEET_CONFIG.write_text(tomlkit.dumps(doc))
            console.print(f"[green]fleet inventory: updated host {name!r} -> {ip}[/green]")
            return

    entry = tomlkit.table()
    entry.comment("added by scripts/azure/dev_vm.py (just az-dev-vm)")
    entry["name"] = name
    entry["hostname"] = ip
    entry["user"] = user
    if identity_file:
        entry["identity_file"] = str(identity_file)
    # Azure admin users get passwordless sudo (cloud-init NOPASSWD), so no
    # password_source is needed and the remote was init'd with noRoot=false.
    entry["no_root_machine"] = False
    hosts.append(entry)
    FLEET_CONFIG.write_text(tomlkit.dumps(doc))
    console.print(f"[green]fleet inventory: registered host {name!r} ({ip})[/green]")


def deregister_fleet_host(name: str) -> None:
    if not FLEET_CONFIG.exists():
        return
    doc = tomlkit.parse(FLEET_CONFIG.read_text())
    hosts = doc.get("hosts")
    if not hosts:
        return
    keep = [h for h in hosts if h.get("name") != name]
    if len(keep) == len(hosts):
        return
    new_hosts = tomlkit.aot()
    for h in keep:
        new_hosts.append(h)
    doc["hosts"] = new_hosts
    FLEET_CONFIG.write_text(tomlkit.dumps(doc))
    console.print(f"[green]fleet inventory: de-registered host {name!r}[/green]")


# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------

def detect_ssh_key() -> tuple[Path | None, Path | None]:
    """Return (private_key, public_key) for the default key, or (None, None)."""
    for stem in ("id_ed25519", "id_rsa"):
        priv = Path.home() / ".ssh" / stem
        pub = priv.with_suffix(".pub")
        if pub.exists():
            return (priv if priv.exists() else None), pub
    return None, None


def wait_for_ssh(ip: str, port: int = 22, timeout: int = 300) -> None:
    console.print(f"[blue]waiting for {ip}:{port} ...[/blue]")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((ip, port), timeout=5):
                console.print(f"[green]SSH port open on {ip}[/green]")
                return
        except OSError:
            time.sleep(5)
    console.print(f"[red]timed out after {timeout}s waiting for {ip}:{port}[/red]")
    raise SystemExit(1)


def ssh_run_script(ip: str, user: str, script: str, identity: Path | None = None,
                   retries: int = 3) -> int:
    """Run `script` on the VM over SSH, streaming output.

    rc 255 is OpenSSH's transport-error code (connection dropped, not the
    remote command failing). The bootstrap is idempotent, so transient drops
    (observed in the wild mid-ansible on an otherwise healthy VM) are retried
    up to `retries` times with a short backoff.
    """
    cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=15",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
        # Non-default key names (e.g. ~/.ssh/azure_vm1) are never offered
        # automatically — pass the private key explicitly when we know it.
        *(["-i", str(identity)] if identity else []),
        f"{user}@{ip}",
        "bash", "-s",
    ]
    for attempt in range(1, retries + 1):
        console.print(f"[dim]$ {shlex.join(cmd)}  <<bootstrap-script (attempt {attempt}/{retries})[/dim]")
        proc = subprocess.run(cmd, input=script, text=True)
        if proc.returncode != 255:
            return proc.returncode
        if attempt < retries:
            console.print("[yellow]SSH transport dropped (rc=255) — retrying the idempotent bootstrap in 15s...[/yellow]")
            time.sleep(15)
    return 255


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

@dataclass
class UpCmd:
    """Create (idempotent) + guardrail + bootstrap + register."""

    name: Annotated[str, tyro.conf.arg(help="VM name (idempotency key together with --resource-group)")] = DEFAULT_NAME
    resource_group: Annotated[str, tyro.conf.arg(help="Resource group (created if missing)")] = DEFAULT_RG
    location: Annotated[str, tyro.conf.arg(help="Azure region")] = DEFAULT_LOCATION
    size: Annotated[str | None, tyro.conf.arg(help=f"VM size; default {DEFAULT_SIZE} ({DEFAULT_SPOT_SIZE} with --spot, {DEFAULT_GPU_SIZE} with --gpu)")] = None
    image: Annotated[str, tyro.conf.arg(help="Image alias/URN")] = DEFAULT_IMAGE
    os_disk_gb: Annotated[int, tyro.conf.arg(help="OS disk size in GB")] = DEFAULT_DISK_GB
    admin_user: Annotated[str | None, tyro.conf.arg(help="Admin username (default: local $USER)")] = None
    ssh_pubkey: Annotated[Path | None, tyro.conf.arg(help="Public key to inject (default: ~/.ssh/id_ed25519.pub or id_rsa.pub)")] = None
    gpu: Annotated[bool, tyro.conf.arg(help="GPU seam: NC-series size + NvidiaGpuDriverLinux extension (CUDA toolchain stays project-level)")] = False
    spot: Annotated[bool, tyro.conf.arg(help="Spot instance (eviction policy Deallocate). Not compatible with B-series sizes")] = False
    auto_shutdown: Annotated[bool, tyro.conf.arg(help="Enable az vm auto-shutdown (cost guardrail)")] = True
    shutdown_time: Annotated[str, tyro.conf.arg(help="Auto-shutdown time, UTC HHMM")] = DEFAULT_SHUTDOWN_TIME
    bundle: Annotated[str, tyro.conf.arg(help="dotfiles_init bundle for the remote bootstrap")] = DEFAULT_BUNDLE
    skip_bootstrap: Annotated[bool, tyro.conf.arg(help="Provision only; skip the remote chezmoi bootstrap")] = False
    register: Annotated[bool, tyro.conf.arg(help="Register the host in ~/.config/fleet/machines.toml")] = True


@dataclass
class DownCmd:
    """Teardown: delete VM resources (whole RG when it only holds this VM) + de-register."""

    name: str = DEFAULT_NAME
    resource_group: str = DEFAULT_RG
    yes: Annotated[bool, tyro.conf.arg(help="Skip the confirmation prompt")] = False


@dataclass
class StatusCmd:
    """Show power state / IP / size of every VM in the resource group."""

    resource_group: str = DEFAULT_RG


@dataclass
class SshCmd:
    """Resolve the VM's public IP and exec ssh."""

    name: str = DEFAULT_NAME
    resource_group: str = DEFAULT_RG
    admin_user: str | None = None
    identity: Annotated[Path | None, tyro.conf.arg(help="Private key (default: the identity_file registered in ~/.config/fleet/machines.toml, else ssh defaults)")] = None


Command = (
    Annotated[UpCmd, tyro.conf.subcommand(name="up")]
    | Annotated[DownCmd, tyro.conf.subcommand(name="down")]
    | Annotated[StatusCmd, tyro.conf.subcommand(name="status")]
    | Annotated[SshCmd, tyro.conf.subcommand(name="ssh")]
)


def run_up(cmd: UpCmd) -> int:
    preflight_az()

    user = cmd.admin_user or os.environ.get("USER") or "azureuser"
    if cmd.ssh_pubkey:
        pub_key = cmd.ssh_pubkey.expanduser()
        maybe_priv = pub_key.with_suffix("")
        priv_key = maybe_priv if maybe_priv.exists() else None
    else:
        priv_key, pub_key = detect_ssh_key()
    if not pub_key or not pub_key.exists():
        console.print("[red]No SSH public key found (~/.ssh/id_ed25519.pub or id_rsa.pub). "
                      "Generate one: ssh-keygen -t ed25519[/red]")
        return 2

    if cmd.size:
        size = cmd.size
    elif cmd.gpu:
        size = DEFAULT_GPU_SIZE
    elif cmd.spot:
        size = DEFAULT_SPOT_SIZE
    else:
        size = DEFAULT_SIZE
    if cmd.spot and size.startswith("Standard_B"):
        console.print(f"[red]B-series ({size}) does not support Spot. Pass --size (e.g. {DEFAULT_SPOT_SIZE}).[/red]")
        return 2

    console.print(Panel(
        f"VM [bold]{cmd.name}[/bold] · rg={cmd.resource_group} · {cmd.location} · {size}"
        f"{' · spot' if cmd.spot else ''}{' · gpu' if cmd.gpu else ''}\n"
        f"user={user} · key={pub_key} · bundle={cmd.bundle}\n"
        f"auto-shutdown={'%s UTC' % cmd.shutdown_time if cmd.auto_shutdown else '[red]OFF[/red]'}",
        title="az-dev-vm up", border_style="blue",
    ))

    az("group", "create", "-n", cmd.resource_group, "-l", cmd.location)

    if vm_exists(cmd.resource_group, cmd.name):
        console.print(f"[yellow]VM {cmd.name} already exists — skipping create (idempotent re-run).[/yellow]")
    else:
        create_args = [
            "vm", "create",
            "-g", cmd.resource_group,
            "-n", cmd.name,
            "--image", cmd.image,
            "--size", size,
            "--os-disk-size-gb", str(cmd.os_disk_gb),
            "--admin-username", user,
            "--ssh-key-values", str(pub_key),
            "--public-ip-sku", "Standard",
            "--nsg-rule", "SSH",
        ]
        if cmd.spot:
            create_args += ["--priority", "Spot", "--eviction-policy", "Deallocate", "--max-price", "-1"]
        console.print("[blue]creating VM (1-3 min)...[/blue]")
        res = az(*create_args)
        info = json.loads(res.stdout)
        console.print(f"[green]VM created: {info.get('publicIpAddress', '?')}[/green]")

    if cmd.gpu:
        exts = az_json("vm", "extension", "list", "-g", cmd.resource_group, "--vm-name", cmd.name) or []
        if any(e.get("name") == "NvidiaGpuDriverLinux" for e in exts):
            console.print("[dim]NvidiaGpuDriverLinux extension already installed.[/dim]")
        else:
            console.print("[blue]installing NVIDIA GPU driver extension (several minutes)...[/blue]")
            az("vm", "extension", "set",
               "--resource-group", cmd.resource_group,
               "--vm-name", cmd.name,
               "--name", "NvidiaGpuDriverLinux",
               "--publisher", "Microsoft.HpcCompute")

    if cmd.auto_shutdown:
        az("vm", "auto-shutdown", "-g", cmd.resource_group, "-n", cmd.name, "--time", cmd.shutdown_time)
        console.print(f"[green]auto-shutdown scheduled daily at {cmd.shutdown_time} UTC "
                      f"(disable: az vm auto-shutdown -g {cmd.resource_group} -n {cmd.name} --off)[/green]")

    ip = vm_public_ip(cmd.resource_group, cmd.name)
    wait_for_ssh(ip)

    if cmd.skip_bootstrap:
        console.print("[yellow]--skip-bootstrap: VM is up, dotfiles not applied.[/yellow]")
    else:
        script = build_remote_bootstrap_script(cmd.bundle)
        console.print(Panel(f"remote bootstrap on {user}@{ip} (first run: ~10-30 min)",
                            border_style="blue"))
        rc = ssh_run_script(ip, user, script, identity=priv_key)
        if rc != 0:
            console.print(f"[red]bootstrap exited rc={rc}. Re-run `just az-dev-vm` (idempotent) or "
                          f"ssh in and run `chezmoi apply` manually.[/red]")
            return rc

    if cmd.register:
        register_fleet_host(cmd.name, ip, user, priv_key)

    console.print(Panel(
        f"[green]ready[/green] — ssh {user}@{ip}\n"
        f"next: `just az-dev-vm-ssh` · `fleet info --hosts {cmd.name}` · "
        f"teardown: `just az-dev-vm-down`",
        title="az-dev-vm up done", border_style="green",
    ))
    return 0


def run_down(cmd: DownCmd) -> int:
    preflight_az()

    if not vm_exists(cmd.resource_group, cmd.name):
        console.print(f"[yellow]VM {cmd.name} not found in {cmd.resource_group} — nothing to delete.[/yellow]")
        deregister_fleet_host(cmd.name)
        return 0

    vms = az_json("vm", "list", "-g", cmd.resource_group, "--query", "[].name") or []
    only_vm = vms == [cmd.name]

    if only_vm:
        target_desc = f"resource group {cmd.resource_group!r} (only VM in it — full group delete)"
    else:
        target_desc = f"VM {cmd.name!r} + its prefixed resources (RG has other VMs: {', '.join(n for n in vms if n != cmd.name)})"

    if not cmd.yes:
        console.print(f"[bold red]About to delete {target_desc}.[/bold red]")
        if input("Type the VM name to confirm: ").strip() != cmd.name:
            console.print("[yellow]Aborted.[/yellow]")
            return 130

    if only_vm:
        console.print(f"[blue]deleting resource group {cmd.resource_group} ...[/blue]")
        az("group", "delete", "-n", cmd.resource_group, "--yes")
    else:
        console.print(f"[blue]deleting VM {cmd.name} ...[/blue]")
        az("vm", "delete", "-g", cmd.resource_group, "-n", cmd.name, "--yes")
        # az vm delete leaves NIC / public IP / NSG / OS disk behind. They are
        # created with the VM-name prefix by `az vm create`, so sweep those.
        for list_args, del_args in (
            (("network", "nic", "list"), ("network", "nic", "delete")),
            (("network", "public-ip", "list"), ("network", "public-ip", "delete")),
            (("network", "nsg", "list"), ("network", "nsg", "delete")),
            (("disk", "list"), ("disk", "delete", "--yes")),
        ):
            names = az_json(*list_args, "-g", cmd.resource_group,
                            "--query", f"[?starts_with(name, '{cmd.name}')].name") or []
            for n in names:
                console.print(f"[blue]deleting leftover {list_args[-2] if len(list_args) > 2 else list_args[0]} {n} ...[/blue]")
                az(*del_args, "-g", cmd.resource_group, "-n", n, check=False)

    deregister_fleet_host(cmd.name)
    console.print("[green]teardown complete.[/green]")
    return 0


def run_status(cmd: StatusCmd) -> int:
    preflight_az()
    if az("group", "show", "-n", cmd.resource_group, check=False, quiet=True).returncode != 0:
        console.print(f"[yellow]Resource group {cmd.resource_group!r} does not exist — nothing provisioned.[/yellow]")
        return 0
    vms = az_json(
        "vm", "list", "-d", "-g", cmd.resource_group,
        "--query", "[].{name:name, power:powerState, ip:publicIps, size:hardwareProfile.vmSize, location:location}",
    ) or []
    if not vms:
        console.print(f"[yellow]No VMs in {cmd.resource_group!r}.[/yellow]")
        return 0
    t = Table(title=f"VMs in {cmd.resource_group}")
    for col in ("name", "power", "ip", "size", "location"):
        t.add_column(col)
    for vm in vms:
        power = vm.get("power") or "?"
        style = "green" if "running" in power else "yellow"
        t.add_row(vm.get("name"), f"[{style}]{power}[/{style}]", vm.get("ip") or "-",
                  vm.get("size"), vm.get("location"))
    console.print(t)
    console.print("[dim]cost hint: `azure-cost-cli accumulatedCost` (dotnet_tools role) or the Azure portal Cost analysis blade[/dim]")
    return 0


def _fleet_identity_for(name: str) -> Path | None:
    """Look up the registered identity_file for `name` in machines.toml."""
    if not FLEET_CONFIG.exists():
        return None
    doc = tomlkit.parse(FLEET_CONFIG.read_text())
    for entry in doc.get("hosts") or []:
        if entry.get("name") == name and entry.get("identity_file"):
            return Path(str(entry["identity_file"])).expanduser()
    return None


def run_ssh(cmd: SshCmd) -> int:
    preflight_az()
    if not vm_exists(cmd.resource_group, cmd.name):
        console.print(f"[red]VM {cmd.name} not found in {cmd.resource_group}.[/red]")
        return 1
    ip = vm_public_ip(cmd.resource_group, cmd.name)
    user = cmd.admin_user or os.environ.get("USER") or "azureuser"
    identity = cmd.identity or _fleet_identity_for(cmd.name)
    argv = ["ssh", "-o", "StrictHostKeyChecking=accept-new",
            *(["-i", str(identity)] if identity else []),
            f"{user}@{ip}"]
    console.print(f"[dim]$ {shlex.join(argv)}[/dim]")
    os.execvp("ssh", argv)
    return 0  # unreachable


def main() -> int:
    cmd = tyro.cli(Command)
    if isinstance(cmd, UpCmd):
        return run_up(cmd)
    if isinstance(cmd, DownCmd):
        return run_down(cmd)
    if isinstance(cmd, StatusCmd):
        return run_status(cmd)
    if isinstance(cmd, SshCmd):
        return run_ssh(cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
