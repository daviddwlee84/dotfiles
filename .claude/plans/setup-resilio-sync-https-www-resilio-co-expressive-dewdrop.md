# Setup Resilio Sync across supported platforms

## Context

The user uses **Resilio Sync** for cross-system file transfer (AirDrop-style) and phone-photo → NAS backup, and wants it installed across the repo's supported platforms. Core question answered during research:

- **Linux (`ubuntu_desktop` AND `ubuntu_server`) is headless by design.** Resilio's Linux `resilio-sync` package ships **no GUI** — it runs as a daemon (binary `rslsync`) and is configured through a WebUI on `127.0.0.1:8888`. So `ubuntu_server` works purely CLI/headless (SSH-tunnel the WebUI to configure). Install is identical on desktop and server.
- **macOS has a native GUI app** via Homebrew `cask "resilio-sync"`.

Confirmed design decisions:
1. **Linux daemon runs as a per-user service** (`systemctl --user` + `enable-linger`), so it can read/write the user's own home files directly — best for photo/NAS sync. Mirrors the existing **Docker-rootless** precedent (`dot_ansible/roles/docker/tasks/main.yml:104-140`).
2. **One new chezmoi prompt `installResilioSync`** gates *both* the Linux ansible role and the macOS cask. Off by default, opt-in per machine — consistent with `installHomelabTools` / `installNiri`.

Config is **not** chezmoi-managed (Resilio's `config.json` holds per-device identity/secrets; leave it WebUI-configured, matching the repo's secrets convention).

## Changes

### 1. New ansible role `dot_ansible/roles/resilio_sync/`

**`tasks/main.yml`** — self-gate on `ansible_facts["os_family"] == "Debian"`. Follow the VSCode deb822 pattern (`dot_ansible/roles/gui_apps_linux/tasks/main.yml` ~364-420) wrapped in `block:`/`rescue:`:

- `file:` ensure `/etc/apt/keyrings` (mode 0755) — `tags: [sudo]`
- `shell:` `wget -qO- http://linux-packages.resilio.com/resilio-sync/key.asc | gpg --dearmor -o /etc/apt/keyrings/resilio-sync.gpg` with `args.creates:` — `tags: [sudo]`
- `deb822_repository:` name `resilio-sync`, `uris: http://linux-packages.resilio.com/resilio-sync/deb`, `suites: resilio-sync`, `components: non-free`, `signed_by: /etc/apt/keyrings/resilio-sync.gpg` — `tags: [sudo]`
- `apt: { update_cache: true }` then `apt: { name: resilio-sync, state: present }` — `tags: [sudo]`
- `rescue:` removes the source via `deb822_repository: { name: resilio-sync, state: absent }` so a failed install never breaks later `apt update`

Then per-user service (gated on `resilio_sync_enable_service`, mirroring Docker rootless — the package ships `/usr/lib/systemd/user/resilio-sync.service`, so no hand-written unit needed):
- Disable/stop the rootful system unit: `systemd_service: { name: resilio-sync, enabled: false, state: stopped }`, `become: true`, `tags: [sudo]`, `failed_when: false`
- `loginctl enable-linger {{ ansible_facts['env']['USER'] }}` with `args.creates: /var/lib/systemd/linger/<user>` — `become: true`, `tags: [sudo]`
- `systemd_service: { name: resilio-sync, scope: user, enabled: true, state: started }` with `environment: { XDG_RUNTIME_DIR: "/run/user/{{ ansible_facts['user_uid'] }}" }`
- A `debug:` reminder that the WebUI is at `127.0.0.1:8888` (SSH-tunnel on a headless server: `ssh -L 8888:127.0.0.1:8888 host`)

**`defaults/main.yml`** — `resilio_sync_enable_service: true` (mirrors `homelab_tools` defaults style).

*(CentOS/RedHat `yum` branch is out of scope for now — the user's Linux profiles are `ubuntu_*`; the role self-gates on Debian and a yum branch can be added later.)*

### 2. Register + gate the role

- **`dot_ansible/playbooks/linux.yml`** — add the role with `tags: [resilio_sync]` (all roles listed unconditionally; tags do the gating).
- **`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`**:
  - Add two hash lines in the header block (~line 46-47) for `resilio_sync` tasks + defaults so edits re-trigger.
  - Add a tag-append block after the `homelab_tools` block (~line 287), mirroring it exactly:
    ```
    {{ $installResilioSync := false }}{{ if hasKey . "installResilioSync" }}{{ $installResilioSync = .installResilioSync }}{{ end -}}
    {{ if and $installResilioSync (eq .chezmoi.os "linux") -}}
    TAGS="${TAGS},resilio_sync"
    {{ end -}}
    ```

### 3. New chezmoi prompt `installResilioSync`

- **`scripts/init/dotfiles_init.py`** — add a `Prompt("installResilioSync", "bool", "System & apps", ...)` entry (SSOT). **No** `condition=When(os=...)` gate — the flag must be available on macOS *and* Linux (unlike Linux-only `installHomelabTools`), `default=False`. Include `prompt_text` + zh-TW `comment` per the existing entries.
- Run **`just gen-prompts`** to regenerate the marked regions of `.chezmoi.toml.tmpl` + `Dockerfile` (never hand-edit those regions).
- Add the key to the README prompt/option table (see §5).

### 4. macOS cask

- **`dot_config/homebrew/Brewfile.darwin.tmpl`** — add a standalone section gated **only** by `installResilioSync`, placed *after* the `installBrewApps` `{{ end -}}` (currently ~line 161) so the one flag governs it independently of the broader GUI-apps flag:
  ```
  {{ if .installResilioSync -}}
  # === Casks - File Sync ===
  cask "resilio-sync"   # P2P file sync (AirDrop-style transfer, phone→NAS photo backup)
  {{ end -}}
  ```
  Installed automatically by `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` on next apply. It's a plain `.app` drag-install cask (no pkg/sudo dance, unlike `google-drive`).

### 5. Docs (CLAUDE.md cross-file obligations)

- **`docs/this_repo/tool-managers.md`** — add a `**resilio-sync**` row to § Tool index (A–Z) (`| macOS: brew cask | Linux: Resilio apt repo | Role: resilio_sync |`), and a row to the "Vendor apt repos managed" table (~line 796). Reuses existing mechanisms → no § Per-manager catalog / § Decision-tree edits needed.
- **`README.md`** — add a bullet under `### Tools (via ansible)` ("**File sync**: Resilio Sync (optional, headless daemon on Linux / GUI cask on macOS)"), and add the `installResilioSync` key to the prompt/option table.
- **New page `docs/tools/resilio-sync.md` (required — user explicitly asked for usage docs).** Register in **`mkdocs.yml`** nav (Tools group) and run `uv run mkdocs build --strict`. Contents:
  - **What it is / when to use** — AirDrop-style cross-system transfer + phone→NAS photo backup; P2P, no cloud middleman.
  - **Install per platform** — the `installResilioSync` prompt; macOS GUI cask vs Linux headless daemon (note: Linux has *no* GUI, WebUI only).
  - **First-run / usage workflow** — macOS: open the app, add folder, share the key. Linux/headless: open WebUI `http://127.0.0.1:8888`, set a WebUI login, add folders, exchange keys/links. How linking two machines works (share key / read-only vs read-write / QR for mobile app).
  - **Headless-server access** — SSH tunnel: `ssh -L 8888:127.0.0.1:8888 host` → browse `localhost:8888` (WebUI binds to loopback only).
  - **Service management** — `systemctl --user status|restart resilio-sync`, `enable-linger` note (survives logout), config location `~/.config/resilio-sync/`.
  - **Phone→NAS backup recipe** — install the Resilio mobile app, enable camera-backup, point it at a read-write folder synced to the NAS/server host.
  - **Troubleshooting** — port 8888 in use, folder permissions (per-user service accesses your `$HOME`), firewall for LAN peer discovery.
  - zh-TW twin (`.zh-TW.md`) is a follow-up per repo i18n convention.
- `docs/playbooks/linux-gui-apps.md` is **not** touched (Resilio is a headless daemon, not a `gui_apps_linux` role app).

## Verification

- **Prompt drift**: `just gen-prompts -- --check` (and the `dotfiles-init-gen-check` pre-commit hook) pass with no drift.
- **Ansible**: run the narrowest practical play in check mode / container smoke for the new role, e.g. `ansible-playbook dot_ansible/playbooks/linux.yml --tags resilio_sync --check` (plus `--syntax-check` as a first pass). Per repo invariant, validate with the app, not just YAML syntax.
- **Linux end-to-end** (on an `ubuntu_*` host with `installResilioSync=true`): `chezmoi apply` → `systemctl --user status resilio-sync` shows active → `curl -sS http://127.0.0.1:8888 | head` returns the WebUI. On a headless server, `ssh -L 8888:127.0.0.1:8888 host` then open `localhost:8888` in a browser.
- **macOS**: `chezmoi apply` (or re-run `run_onchange_after_30_brew_bundle.sh.tmpl`) installs `cask "resilio-sync"`; confirm `brew list --cask resilio-sync` and the app launches.
- **Docs**: `uv run mkdocs build --strict` passes if the new page is added.
