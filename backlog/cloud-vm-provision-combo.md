# Combo command: `az` (or any cloud) VM spin-up + dotfiles bootstrap — fit into `fleet`?

**Status**: P? / surfaced 2026-05-21 — idea stage, depends on the lean bundle existing first
**Effort**: L (provision + SSH-wait + inventory register + remote non-interactive `chezmoi init --apply` + teardown; az-only first cut)
**Related**: [`TODO.md`](../TODO.md) → `[?/L] Cloud-VM provision + dotfiles bootstrap combo` · prerequisite [`lean-bundle-init-ux.md`](lean-bundle-init-ux.md) · `scripts/fleet/` (apply.py / exec.py / hosts.py) · `dot_dotfiles/bin/executable_fleet` · `dot_config/television/cable/fleet-hosts.toml` · `iac_tools` role (installs azure-cli) · `docs/this_repo/fleet-apply.md`

## Context

2026-05-21, "dotfile on a lightweight dev machine" thread:
*"可能也可以加上某個搭配 az CLI 啟動機器 + setup dotfile 的 combo command 等等（快速加到 fleet？）。"*

Goal: one command → a running Azure VM with the lean dev environment (ergonomic shell + tmux + nvim + claude/opencode/specstory) already applied.

## Investigation / design sketch

Phases (provider-agnostic shape, az as first impl):

1. **Provision** — `az vm create` with: Ubuntu 24.04 LTS Gen2 image, cheap size (e.g. `Standard_B2s` 2vCPU/4GB), `--os-disk-size-gb 32`, `--ssh-key-values <pubkey>`, NSG open :22, a resource-group + region. (`iac_tools` role already brings `azure-cli`; the controlling box needs `az login` done.)
2. **Wait for SSH** — `az vm wait` / poll `:22`.
3. **Register in fleet inventory** — append host to the fleet hosts source so `fleet exec` / `fleet-apply` see it (`fleet hosts --list` is the read side; `dot_config/television/cable/fleet-hosts.toml` / user-local hosts file the write side).
4. **Bootstrap** — over SSH: curl-install chezmoi, then non-interactive `chezmoi init --apply git@github.com:daviddwlee84/dotfiles --promptBool ... --bundle cloud-vm`. This is exactly the path `fleet-apply` + the Dockerfile ARG flow already exercise.

Phase 4 reuses existing plumbing; phases 1–2 (creating infra) are genuinely new to this repo.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. `fleet up azure …` verb (new `scripts/fleet/provision.py`) | Best UX — provisioned host lands straight in the fleet; reuses fleet SSH/inventory/apply for phases 3–4 | Couples `fleet` (today: operate *existing* hosts) to a cloud provider; needs a provider-abstraction seam to not be az-locked |
| B. Standalone `just az-dev-vm` / `scripts/azure/spin_up_dev_vm.py`; only bootstrap reuses `fleet-apply` | Keeps fleet's "operate existing hosts" contract clean; lower blast radius | Two entry points; provisioning lives outside the fleet mental model |

Leaning B for the first cut (keep fleet's contract), promote to A if it gets used enough to justify the coupling + provider abstraction.

## Current blocker / open questions

- **Teardown symmetry is mandatory** — a left-running B2s with a 32GB disk costs money. Need `fleet down` / `az vm delete` + de-register, ideally an auto-shutdown schedule. Don't ship spin-up without spin-down.
- **Idempotency** — fixed RG + VM name as the key so re-runs don't create a second VM.
- **Auth/state on the controlling box** — requires `az login` session + `az` on PATH; decide how the combo checks/surfaces that.
- Depends on [`lean-bundle-init-ux.md`](lean-bundle-init-ux.md): the `--bundle cloud-vm` it would pass must exist first.
- Provider abstraction: az-only now, but name the seam so GCP/AWS/Hetzner can slot in without rewriting fleet.

## Decision (if any)

2026-05-21 — captured. Sequence after the lean bundle ships: prototype as standalone (option B), measure usage, then decide on `fleet up` promotion.

2026-06-10 — **SHIPPED as option B**: `scripts/azure/dev_vm.py` (uv script: tyro + rich + tomlkit) + `just az-dev-vm` / `az-dev-vm-down` / `az-dev-vm-status` / `az-dev-vm-ssh`. All four phases landed:

1. Provision — `az vm create` Ubuntu2404 Gen2 / `Standard_B2s` / 32GB / ssh-key inject / `--nsg-rule SSH`; `--spot` (auto-switches default size to `Standard_D2as_v5` — B-series can't Spot) and `--gpu` (NC4as_T4_v3 + `NvidiaGpuDriverLinux` extension) seams.
2. Wait for SSH — socket poll on :22, 5 min budget.
3. Fleet register — tomlkit append/update of `[[hosts]]` in `~/.config/fleet/machines.toml`; `down` de-registers symmetrically.
4. Bootstrap — remote bash over SSH: curl-install chezmoi + non-interactive `chezmoi init --apply --bundle cloud-vm`. The flag set is COMPUTED by importing `dotfiles_init.py`'s PROMPTS/BUNDLES + `build_chezmoi_argv` (no fourth hand-copied flag list). Re-runs re-apply without the repo arg (promptXOnce reads stored answers).

Blockers from above all addressed: teardown symmetry (`down` deletes the whole RG when this VM is its only VM, else VM + name-prefixed NIC/PIP/NSG/disk sweep), idempotency (fixed RG+name key), auth/state surfaced (`az account show` preflight prints the active subscription), plus a cost guardrail that wasn't in the original sketch: `az vm auto-shutdown --time 1900` enabled by default.

Provider abstraction deliberately NOT built — az-only, promote to `fleet up <provider>` only when a second provider is actually wanted. Docs: [docs/this_repo/az-dev-vm.md](../docs/this_repo/az-dev-vm.md).

## References

- Footprint audit + scenario: `.specstory/history/2026-05-21_05-19-56Z-dotfile-dev-machine-heavy.md`
- `docs/this_repo/fleet-apply.md` (non-interactive remote apply, `CHEZMOI_SUDO_PASSWORD_FILE` model)
- `docs/tools/fleet-hosts.md` (inventory)
