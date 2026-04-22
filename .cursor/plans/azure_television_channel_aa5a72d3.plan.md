---
name: Azure Television channel
overview: Add an `azure` Television (`tv`) channel that fuzzy-searches Azure resources over `az` CLI, with source-cycling across resource types (Resource Groups / VMs / Public IPs / NICs+NSGs / all resources), per-resource actions (restart, deallocate, rotate public IP, SSH, open-in-portal, copy-id), and graceful prompting when the user isn't logged in.
todos:
  - id: channel-toml
    content: Write dot_config/television/cable/azure.toml with 5-source cycling, Alt-key actions, preview cycling
    status: completed
  - id: source-script
    content: Write executable_azure-source.sh emitting TSV rows per source, with az-account-show login gate
    status: completed
  - id: preview-script
    content: Write executable_azure-preview.sh (main + alt cycles) routed on kind
    status: completed
  - id: rotate-ip-script
    content: Port executable_azure-rotate-ip.sh from V2Ray repo, stateless (live NIC+PIP resolve), keep VPS-safety guard + DNS verification
    status: completed
  - id: docs-tv
    content: Append azure channel section to docs/tools/tv.md (source cycling, keybinding table, login UX, rotate-ip note)
    status: completed
  - id: todo-1776824728209-krn15u7v8
    content: "git commit "
    status: completed
isProject: false
---

## Files

**New**
- `dot_config/television/cable/azure.toml` — channel definition (follows `pueue.toml` / `ansible.toml` layout).
- `dot_config/television/executable_azure-source.sh` — emits rows per source (one of: `rgs`, `vms`, `pips`, `nics`, `all`). Also handles the "not-logged-in gate": if `az account show` fails, emits a single synthetic row `login\tnot-logged-in\t-\t-\tPress Enter to run 'az login'`.
- `dot_config/television/executable_azure-preview.sh` — preview dispatcher (`main` and `alt` cycles), routes on the row's `kind` field. Uses `bat -l yaml` if present, raw `az ... show` otherwise.
- `dot_config/television/executable_azure-rotate-ip.sh` — ported from [`DockerCompose-V2Ray/scripts/az_rotate_ip.sh`](../../Documents/Program/Personal/DockerCompose-V2Ray/scripts/az_rotate_ip.sh), rewritten to resolve `VM → NIC → PIP → DNS-label` live via `az` (no `.secrets/azure/vms/<rg>.json`). Keeps the 5-step detach→delete→recreate→reattach→verify flow, the VPS-safety `SSH_CONNECTION` guard, and the `--dns-name` preservation trick.

**Updated**
- `docs/tools/tv.md` — new `### azure channel` section after the `pueue` section (source cycling table, keybindings table, login UX, multi-sub switching, link to ported rotate-ip).

## Row schema (TSV)

Every source emits rows with identical column layout so one set of actions can switch on `kind`:

```
kind \t name \t resource_group \t location \t extra
```

- `kind ∈ {rg, vm, pip, nic, nsg, res, login}`
- `extra` varies: VM→power-state, PIP→ipAddress, NIC→ipConfig, NSG→ruleCount, res→type/kind string, rg→"-".

Display template: `{split:\t:0}  {split:\t:1}  [{split:\t:2}]  {split:\t:3}  {split:\t:4}`.
Output: `{split:\t:0}\t{split:\t:1}\t{split:\t:2}` (enough for every action).

## Source cycling (`Ctrl+S`)

Implemented as 5 entries in `[source].command`, each calls `azure-source.sh <kind>`:

1. **Resource Groups** — `az group list -o tsv --query '[].{n:name,l:location}'`
2. **VMs** — `az vm list -d -o tsv` with power-state (`-d` adds it; one API call).
3. **Public IPs** — `az network public-ip list -o tsv` with `ipAddress` + `dnsSettings.fqdn`.
4. **NICs + NSGs** — union via two `az` calls, distinguished by `kind`.
5. **All resources (generic fallback)** — `az resource list -o tsv --query '[].{n:name,t:type,g:resourceGroup,l:location}'`.

All sources short-circuit to the `login` synthetic row if `az account show` fails. `watch` is **not** set by default (az calls are slow); the user reloads manually with `Ctrl+R`.

## Keybindings (`Alt+*` namespace to avoid tmux / TV built-ins)

| Key | Action | Works on |
|---|---|---|
| `Enter` | `az <kind> show` in execute mode (press-Enter-to-exit). If `kind=login` → run `az login` + `reload_source`. | all |
| `Alt+R` | Restart | vm |
| `Alt+S` | Start | vm |
| `Alt+P` | Power-off (billed) | vm |
| `Alt+D` | Deallocate (not billed) | vm |
| `Alt+I` | **Rotate public IP** — calls `azure-rotate-ip.sh <rg> <vm>` | vm |
| `Alt+H` | SSH via `az ssh vm` (if extension present) else hint | vm |
| `Alt+O` | Open in Azure Portal (`open` / `xdg-open` on `https://portal.azure.com/#@/resource<id>`) | all |
| `Alt+X` | Delete (confirm prompt) | rg, vm, pip, nic, nsg, res |
| `Alt+U` | Switch subscription (`az account list` piped to `fzf` → `az account set --subscription`) + reload | all |
| `Alt+Y` / `Ctrl+Y` | Copy resource id to clipboard (pbcopy / wl-copy / xclip / OSC-52 — same helper as in [pueue.toml](dot_config/television/cable/pueue.toml)) | all |

Each action runs `case "$kind" in ...` inside its shell command, so wrong-kind keys become no-ops with a 1-second toast (same pattern as `ansible.toml`'s `[actions.yazi]` that only fires on `role`).

## `azure-rotate-ip.sh` (ported, state-less)

Signature: `azure-rotate-ip.sh <resource-group> <vm-name>` (or prompt for both if omitted). Keeps:

- `az account show` preflight → hint to `az login`.
- `SSH_CONNECTION` VPS-safety guard (refuses to run over SSH).
- 5-step: `nic ip-config update --remove publicIPAddress` → `public-ip delete` → `public-ip create --dns-name <preserved>` → `nic ip-config update --public-ip-address` → `dig +short <fqdn>` verification.
- `AZ_YES=1` skip-prompt env.

Dropped vs the V2Ray version:

- No `.secrets/azure/vms/<rg>.json` read/write (live resolution only).
- No legacy `last-vm.json` mirror.
- No multi-host selection — `<rg>` + `<vm>` come from the TV row.

## Login / subscription UX

- **Not logged in**: synthetic row drives the user to `Enter → az login`.
- **Logged in**: `[ui].input_header = "Azure · $(az account show --query name -o tsv)"` so the subscription is always on-screen.
- `Alt+U` opens a one-line fzf picker of `az account list` and `az account set`s + `reload_source`.

## Preview cycling (`Ctrl+F`)

1. `az <kind> show -o yaml` piped through `bat -l yaml --style=plain --color=always` (falls back to plain).
2. `az <kind> show -o json` for copy-paste convenience.

`[ui.preview_panel].size = 55`, matching `pueue.toml` / `ansible.toml`.

## Requirements

`[metadata].requirements = ["az", "jq"]` — same idiom as `ansible.toml`. TV will skip the channel on hosts without `az` (e.g. `ubuntu_server` profile that excludes the `iac_tools` ansible tag).

## Non-goals (v1)

- Provisioning (`az vm create`, `az-up.sh` equivalent) — stays in the V2Ray repo.
- Teardown beyond the generic `Alt+X` delete-with-confirm.
- Auto-refresh (`watch = N`) — the cost of `az` calls is too high; users hit `Ctrl+R`.
- Windows resource types (focus is Linux VMs, parity with V2Ray use-case).
