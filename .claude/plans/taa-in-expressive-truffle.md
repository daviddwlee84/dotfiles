# Homelab hardware-tooling series (chezmoi + ansible + shell + docs)

## Context

While decommissioning a disk on the physical server `ta-stg`, we needed to read the
RAID card (LSI MegaRAID SAS-3 3108 / PRAID EP400i) and chassis sensors. We discovered
`storcli` was manually dropped at `/usr/local/sbin/storcli` (untracked, not reproducible)
and `ipmitool` / `lm-sensors` were missing until installed ad-hoc this session. None of
this hardware-monitoring tooling lives in the dotfiles repo today (greenfield — confirmed
no `storcli`/`ipmitool`/`smartctl`/`sensors` references except a stray `storcli.log`).

Goal: make hardware monitoring a **reproducible, first-class "homelab" capability** in the
dotfiles repo — installed by ansible (only when the matching hardware is actually present),
fronted by a `hw-*` shell helper family in the same idiom as the existing `audit-*` /
`disk-*` / `fw-*` helpers, and documented under `docs/sysadmin/` bilingually. Decommission
itself is already done (disk unmounted, fstab line commented, `findmnt --verify` clean).

Decisions locked with the user:
- **Tools**: lm-sensors, ipmitool, smartmontools, storcli, nvme-cli — **each gated on
  hardware detection** so a box without a MegaRAID controller / NVMe drive / BMC doesn't
  install unused packages.
- **Layout**: a single `homelab_tools` ansible role (matches `networking_tools` /
  `security_tools` grouped-by-theme style), one chezmoi prompt, one tag.
- **Shell**: full `hw-*` family + a `hw-status` aggregator.

## Integration points (all the surfaces a new role+prompt+helper must touch)

This repo enforces cross-file invariants (see `CLAUDE.md` "Cross-file maintenance rules").
The full set this change must keep in sync:

1. Ansible role — new `dot_ansible/roles/homelab_tools/`
2. Playbook wiring — `dot_ansible/playbooks/linux.yml`
3. Prompt→tag gating — `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`
4. Prompt SSOT — `scripts/init/dotfiles_init.py` + `just gen-prompts` (regens `.chezmoi.toml.tmpl` + `Dockerfile`)
5. Shell helpers — new `dot_config/shell/49_homelab.sh.tmpl`
6. Docs — `docs/sysadmin/hardware.md` (+ `.zh-TW.md`) + `mkdocs.yml` nav
7. Mirror tables — `docs/this_repo/tool-managers.md` (A–Z rows), `docs/shells/aliases.md`,
   `docs/sysadmin/helpers.md` (+ `.zh-TW.md`), `docs/sysadmin/README.md`, `README.md`

---

## 1. Ansible role: `dot_ansible/roles/homelab_tools/`

Model the task style on `dot_ansible/roles/auditd/tasks/main.yml` (OS gate via
`meta: end_play`) and `networking_tools` (per-OS apt/dnf + GitHub/vendor download fallback,
`target_architecture` arch mapping).

`tasks/main.yml` structure:

- **Gate 1 — non-Linux**: `when: ansible_facts["os_family"] not in ["Debian","RedHat"]` → `meta: end_play`.
- **Gate 2 — virtual machines**: `when: ansible_facts['virtualization_role'] == 'guest'` → `meta: end_play`
  (BMC/RAID/SMART tools are meaningless inside a VM).
- **Hardware detection** (register facts once, drive `when:` on each install):
  - RAID controller present: `lspci -d ::0104` (class "RAID bus controller") non-empty, or
    `lspci | grep -iE 'megaraid|lsi|raid bus'` → gates **storcli**.
  - NVMe present: `ls /dev/nvme*` or `lspci -d ::0108` → gates **nvme-cli**.
  - IPMI/BMC present: `/dev/ipmi0` exists or `dmidecode -t 38` (IPMI Device Info) non-empty
    → gates **ipmitool** (still safe to install broadly, but skip on boxes with no BMC).
  - **lm-sensors** + **smartmontools**: install on any physical Linux host (no extra gate
    beyond Gate 1/2) — sensors are near-universal and smartctl works on any SATA/SAS/NVMe disk.
- **Installs** (per-OS, `become: true`, `tags: [sudo]`):
  - apt/dnf: `lm-sensors`/`lm_sensors`, `smartmontools`, `ipmitool`, `nvme-cli`.
  - **storcli** is NOT in distro repos → 2-phase pattern like `networking_tools`:
    system path first if a packaged build exists, else **vendor/GitHub-release download**
    (Broadcom storcli tarball; there are mirrored releases) extracted to `~/.local/bin`
    (or `/usr/local/sbin` with become). Wrap in `block:`/`rescue:` + re-check, x86_64-only
    arch guard. Add a `pitfalls/` note if the download URL proves brittle.
- `defaults/main.yml`: toggles e.g. `homelab_install_storcli: true`, download URL/version
  pinning vars.
- `handlers/main.yml`: none required initially (no daemons enabled by default; smartd left
  disabled to honor the repo's install-only / no-new-services posture — note this explicitly).

Then add to `dot_ansible/playbooks/linux.yml` roles list:
```yaml
    - role: homelab_tools
      tags: [homelab_tools]
```

## 2. Prompt + tag gating

- **`scripts/init/dotfiles_init.py`**: add to the `PROMPTS` tuple (SSOT) a bool
  `installHomelabTools`, category "System & apps", `condition=When(os=frozenset({"linux"}))`,
  `else_value=False` — mirroring the `installAuditd` prompt (init.py ~line 255). Consider
  defaulting it into the server BUNDLE if appropriate. Then run `just gen-prompts` to
  regenerate `.chezmoi.toml.tmpl` + `Dockerfile` (never hand-edit generated regions). Add
  the key to the README option table.
- **`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`**: add the
  sha256sum include line for the new role near line 37, and a gating block mirroring the
  `installAuditd` block (~line 270):
  ```
  {{ $installHomelabTools := false }}{{ if hasKey . "installHomelabTools" }}{{ $installHomelabTools = .installHomelabTools }}{{ end -}}
  {{ if and $installHomelabTools (eq .chezmoi.os "linux") -}}
  TAGS="${TAGS},homelab_tools"
  {{ end -}}
  ```

## 3. Shell helpers: `dot_config/shell/49_homelab.sh.tmpl`

Tier-1 shared (POSIX, both shells source). Follow `45_audit.sh.tmpl` conventions exactly:
`--help` on every function, `command -v` guards, broken-pipe-safe, sudo-aware. Provide
small self-contained private helpers `_hw_have` / `_hw_run_root` (replicate the
`_audit_run_root` strategy rather than depend on 45's private function across files).

Public `hw-*` family:
- `hw-fans` — `ipmitool sdr type fan` (skips `ns`/No-Reading rows or flags them as empty slots).
- `hw-temps` — `ipmitool sdr type temperature` + `sensors` if present.
- `hw-sensors` — full `sensors` dump (lm-sensors), with hint to run `sudo sensors-detect` once.
- `hw-raid` — `storcli /c0 show` summary + `storcli /c0/eall show all` sensor section; notes
  ROC temp and that SGPIO backplanes report 0 fans/temps (the exact gotcha hit this session).
- `hw-smart [dev]` / `hw-disks` — `smartctl -H` health across disks (`lsblk` enumerate), plus
  `smartctl -a <dev>` detail; nvme via `nvme smart-log` when `nvme-cli` present.
- `hw-sel` — `ipmitool sel list` / `sel elist` (BMC event log) + `sel time get`.
- `hw-status` — aggregator (mirrors `health-check`): one screen = fans + temps + RAID summary
  + per-disk SMART verdict + recent SEL errors, color-coded, `--no-color` auto on non-TTY.

OS-template the file so non-Linux renders a clear "Linux/physical-server only" stub.

## 4. Docs (bilingual, like `docs/sysadmin/disk.md`)

- New `docs/sysadmin/hardware.md` + `docs/sysadmin/hardware.zh-TW.md`: "is the hardware
  healthy?" — covers the two sensor planes that confused us this session (**RAID-card ROC
  via storcli** vs **chassis BMC via ipmitool** vs **lm-sensors on-board chips**), the
  `hw-*` quick-CLI block, morning-sweep recipes, and caveats (SGPIO backplane = 0 fans/temps;
  `ns`/No-Reading = unpopulated slot not a fault; ROC ~79°C is warm-but-in-spec; storcli not
  in apt). Cross-link `disk.md` and `helpers.md`.
- Add nav entry in `mkdocs.yml`; build with `uv run mkdocs build --strict`.
- Add the `hw-*` reference rows to `docs/sysadmin/helpers.md` (+ `.zh-TW.md`) and a line in
  `docs/sysadmin/README.md`'s hierarchy.

## 5. Mirror tables (CLAUDE.md cross-file rules)

- `docs/this_repo/tool-managers.md` — A–Z rows for lm-sensors, ipmitool, smartmontools,
  storcli (note: vendor download), nvme-cli.
- `docs/shells/aliases.md` — one row per `hw-*` function (name, type, source, scope, one-line).
- `README.md` — "What You Get" / Supported features + new prompt in the option table.

## Verification

- `just gen-prompts -- --check` → no drift (also the `dotfiles-init-gen-check` pre-commit hook).
- Render + lint the shell helper: `chezmoi cat ~/.config/shell/49_homelab.sh` then
  `shellcheck` the rendered output; source it in **both** `bash -lc` and `zsh -lc` to confirm
  no parse errors (Tier-1 POSIX rule).
- Ansible: `cd ~/.ansible && ansible-playbook -i inventories/localhost.ini playbooks/linux.yml
  --tags homelab_tools --syntax-check`, then a real `--tags homelab_tools` run on `ta-stg`
  (physical host with MegaRAID + BMC, no NVMe — exercises both the install-this and
  skip-that detection branches). Optionally container smoke (`just docker-test-rocky9`) to
  confirm the VM/non-hardware gates `end_play` cleanly.
- Functional: run `hw-fans`, `hw-temps`, `hw-raid`, `hw-smart`, `hw-status` on `ta-stg` and
  confirm output matches the ad-hoc `ipmitool`/`storcli` results from this session.
- `uv run mkdocs build --strict` passes (nav + anchors).

## Out of scope / notes

- Disk decommission is already complete; no further action there.
- Install-only posture preserved: do **not** enable `smartd`/`ipmievd` services by default
  (honors the repo's "install vs upgrade is split" + no-new-daemons convention). A future
  P? backlog item could add an opt-in monitoring/alerting timer.
