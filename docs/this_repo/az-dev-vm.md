# az-dev-vm — one command to a usable Azure dev VM

> **TL;DR** — `just az-dev-vm` runs `az vm create` (idempotent, Ubuntu 24.04
> / `Standard_B2s` / 32 GB), schedules a daily `az vm auto-shutdown` cost
> guardrail, waits for SSH, bootstraps the lean **`cloud-vm` bundle** via a
> fully non-interactive `chezmoi init --apply`, and registers the host in
> `~/.config/fleet/machines.toml`. Teardown is symmetric: `just az-dev-vm-down`.

Implementation: [`scripts/azure/dev_vm.py`](../../scripts/azure/dev_vm.py)
(uv inline-script: `tyro` + `rich` + `tomlkit`). Design history:
`backlog/cloud-vm-provision-combo.md` + `backlog/lean-bundle-init-ux.md`
(repo-root, not in this site's nav).

## Prerequisites (controlling box)

- `az` CLI on PATH — installed by the `iac_tools` ansible role
  (`just reconfigure --set installIacTools=true --yes`) or the
  [official installer](https://learn.microsoft.com/cli/azure/install-azure-cli).
- A live `az login` session (the script checks `az account show` and exits
  with a hint otherwise).
- An SSH keypair (`~/.ssh/id_ed25519` preferred, `id_rsa` fallback) — the
  public key is injected at create time.

## Commands

```bash
just az-dev-vm                          # up: create + guardrail + bootstrap + register
just az-dev-vm --gpu                    # NC-series + NVIDIA driver extension (see GPU seam)
just az-dev-vm --spot                   # Spot instance (D2as_v5 default; B-series can't Spot)
just az-dev-vm --size Standard_D4s_v5   # explicit size
just az-dev-vm --bundle server-linux    # heavier bundle instead of cloud-vm
just az-dev-vm --skip-bootstrap         # provision only, no dotfiles
just az-dev-vm --no-auto-shutdown       # opt out of the guardrail (not recommended)

just az-dev-vm-status                   # power state / public IP / size per VM
just az-dev-vm-ssh                      # resolve IP + ssh in
just az-dev-vm-down                     # teardown + fleet de-register (asks for VM name)
just az-dev-vm-down --yes               # non-interactive teardown
```

All recipes forward `*ARGS` to `scripts/azure/dev_vm.py <subcommand>`; run
`./scripts/azure/dev_vm.py up --help` for the full flag list
(`--name`, `--resource-group`, `--location`, `--admin-user`, …).

## What `up` does, step by step

1. **Preflight** — `az` on PATH + `az account show` (prints the active
   subscription so you notice a wrong-tenant login).
2. **Idempotent provision** — fixed resource group (`dev-vm-rg`) + VM name
   (`devbox-1`) form the idempotency key: re-runs never create a second VM,
   they skip straight to the later steps. `az group create` is a no-op when
   the RG exists.
3. **Cost guardrail** — `az vm auto-shutdown --time 1900` (UTC) by default,
   so a forgotten VM stops billing compute at night. Disable per-run with
   `--no-auto-shutdown`, or permanently:
   `az vm auto-shutdown -g dev-vm-rg -n devbox-1 --off`.
4. **Wait for SSH** — polls `:22` (5 min budget).
5. **Bootstrap** — pipes a bash script over SSH that curl-installs chezmoi
   (if missing) and runs a fully non-interactive
   `chezmoi init --apply` with the **complete** `--promptBool/--promptChoice`
   flag set for the chosen bundle (default `cloud-vm`). The flag set is
   **computed from `scripts/init/dotfiles_init.py`'s `PROMPTS`/`BUNDLES`**
   (the SSOT) at run time — there is no fourth hand-copied flag list to
   drift. Azure admin users have passwordless sudo (cloud-init `NOPASSWD`),
   so the run-scripts' shared sudo session short-circuits cleanly without a
   TTY.
6. **Fleet registration** — appends/updates a `[[hosts]]` entry in
   `~/.config/fleet/machines.toml` (name, public IP, user, identity file,
   `no_root_machine = false`), so `fleet info` / `just fleet-apply` see the
   new box immediately. Skip with `--no-register`.

Re-running `up` against an already-bootstrapped VM re-applies idempotently:
the remote script detects the existing chezmoi source and runs
`chezmoi init --apply` *without* the repo argument — `promptXOnce` reads the
stored answers and chezmoi just re-renders + re-applies.

### The `cloud-vm` bundle

Lean preset for throwaway/cloud dev VMs (see `scripts/init/README.md`
→ Bundles): ergonomic shell + tmux + nvim + coding agents, with
`installExtraRuntimes=false` (drops the ~1.8 GB rust/bun/ruby mise runtimes;
node always installs because nvim LSP and npm-based agents need it),
`installDotnetTools=false`, all other `installX` flags off, and
`backupMode=off` (fresh VM, nothing to back up). Want more? Pass
`--bundle server-linux` or reconfigure later on the VM itself.

## Teardown semantics (`down`)

A left-running B2s with a 32 GB disk costs money — **never ship spin-up
without spin-down** (the design rule from the original backlog note):

- When the VM is the **only** VM in the resource group (the default
  single-VM workflow): `az group delete --yes` removes everything —
  VM, NIC, public IP, NSG, disk.
- When the RG hosts other VMs: `az vm delete --yes`, then a sweep of
  leftover NIC / public IP / NSG / disks whose names start with the VM name
  (the naming pattern `az vm create` uses for auto-created resources).
- Either way the host is de-registered from `~/.config/fleet/machines.toml`.

Confirmation requires typing the VM name; `--yes` skips it for scripts.

## GPU seam (`--gpu`)

`--gpu` switches the default size to `Standard_NC4as_T4_v3` (T4 16 GB — the
cheapest NC SKU; override with `--size Standard_NC...`) and installs
Microsoft's **NvidiaGpuDriverLinux** VM extension after create, so
`nvidia-smi` works without hand-rolling a driver install.

Deliberately **not** included: a CUDA/cudnn/nccl ansible role. The version
matrix is huge, host-specific, and project environments (conda / `uv` with
`pytorch-cuda` wheels) already pin their own CUDA userspace against the
driver. See `TODO.md` → "CUDA / ML toolchain ansible role" (repo root) for
the standing decision.

## Costs & monitoring

- The auto-shutdown guardrail is the primary cost control; `--spot` cuts
  compute ~60-90 % for interruptible work (eviction policy `Deallocate`,
  so `az vm start` resumes it).
- `just az-dev-vm-status` shows power state at a glance;
  [`fleet info`](fleet-apply.md) gives CPU/RAM/disk/GPU across the fleet
  once the host is registered.
- For spend numbers: `azure-cost-cli` (installed by the `dotnet_tools`
  role when `installDotnetTools=true`) or the portal's Cost analysis blade.

## Troubleshooting

- **`Not logged in to Azure`** — `az login` (and check `az account show`
  picks the right subscription; `az account set -s <name>`).
- **Quota / SKU not available in region** — pass `--location` and/or
  `--size`; NC-series quota usually needs a one-time increase request.
- **SSH wait times out** — check the NSG allows your source IP
  (`az vm create` opens 22 to the world by default via `--nsg-rule SSH`);
  corporate networks sometimes block outbound 22.
- **Host key mismatch after recreate** — a recreated VM gets a new host key
  (and possibly a recycled IP). Remove the stale entry:
  `ssh-keygen -R <ip>`.
- **Bootstrap failed mid-way** — re-run `just az-dev-vm` (idempotent), or
  `just az-dev-vm-ssh` and run `chezmoi apply` manually; the per-step logs
  stream to your terminal during the run.
- **`fleet-status` shows `toml-mismatch` for older hosts** — adding the
  `installExtraRuntimes` prompt means hosts initialized before it need a
  one-time interactive `chezmoi init` (answer the new prompt) before
  `fleet-apply` works non-interactively again. See
  [fleet-apply.md → toml-mismatch](fleet-apply.md#state-matrix).

## Related

- [fleet-apply.md](fleet-apply.md) — operating the VM after provisioning
  (this tool hands off to fleet for day-2 operations).
- `dot_config/television/cable/azure.toml` — `tv azure` channel for ad-hoc
  start/stop/SSH/rotate-IP on any Azure VM.
- [tool-managers.md](tool-managers.md) — who installs what on the VM once
  the bundle applies.
