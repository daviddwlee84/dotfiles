# resilio_sync install: `gpg: no valid OpenPGP data found`, a ~30-min hang, then `set: Illegal option -o pipefail`

**Symptoms** (grep this section): `chezmoi apply` / `ansible-playbook --tags resilio_sync` fails in the
`resilio_sync` role at task **"Add Resilio Sync GPG key (dearmored)"**. Two distinct failure modes, seen back-to-back:

1. The task **hangs for ~29 minutes** (`Slow tasks (>5s): resilio_sync : Add Resilio Sync GPG key (dearmored) (29m32s)`) then fails:
   ```
   stderr: 'gpg: no valid OpenPGP data found.'
   cmd: wget -qO- http://linux-packages.resilio.com/resilio-sync/key.asc | gpg --dearmor -o /etc/apt/keyrings/resilio-sync.gpg
   ```
2. After switching to `curl ... | gpg`, it fails **instantly** (~2 ms):
   ```
   stderr: '/bin/sh: 1: set: Illegal option -o pipefail'
   cmd: |-
       set -eo pipefail
       curl -fsSL --retry 3 --retry-delay 2 --max-time 60  https://linux-packages.resilio.com/resilio-sync/key.asc  | gpg --dearmor -o ...
   ```
The role's `rescue:` then removes the apt source and the service tasks skip (correctly gated on `dpkg-query`), so `systemctl --user status resilio-sync` reports **`Unit resilio-sync.service could not be found`**.

**First seen**: 2026-07-11 (bringing up the new `resilio_sync` role on David-Ubuntu, ubuntu_desktop).
**Affects**: `dot_ansible/roles/resilio_sync/tasks/main.yml`. Trap 2 (pipefail) affects *any* `ansible.builtin.shell` task in this repo that uses `set -o pipefail`.
**Status**: fixed — key + repo fetched over `https://` with `curl --max-time`, and the shell task pinned to `executable: /bin/bash`.

## Two independent traps, one masking the next

### Trap 1 — Resilio's CDN blocks port 80 on some networks; use HTTPS

`linux-packages.resilio.com` resolves to an **IPv6 Meta/Fastly endpoint** (`2a03:2880:...:face:b00c:...`). On this network **port 80 (`http://`) times out** while **443 (`https://`) works in ~1 s**:

```
$ curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{time_total}s\n' http://linux-packages.resilio.com/resilio-sync/key.asc
000 20.002s          # curl: (28) Operation timed out
$ curl -sS --max-time 20 -o /dev/null -w '%{http_code} %{time_total}s\n' https://linux-packages.resilio.com/resilio-sync/key.asc
200 1.171s           # valid 957-byte key, uid "Resilio, Inc. <support@getsync.com>"
```

Resilio's official docs give the `http://` URL. A bare **`wget` has no total timeout** and retries ~20× → the task hangs for tens of minutes on the dead endpoint, then hands empty stdin to `gpg` → `no valid OpenPGP data found`. The empty output is a *symptom of the network hang*, not a bad key.

→ Fix: use `https://` for both the key **and** the deb822 `uris:`; fetch with `curl -fsSL --retry 3 --max-time 60` so a dead endpoint fails in seconds, never minutes.

### Trap 2 — `ansible.builtin.shell` runs under dash, which has no `pipefail`

`ansible.builtin.shell` executes via the remote's `/bin/sh`. On Ubuntu that's **dash**, and `set -o pipefail` is a bashism → `set: Illegal option -o pipefail`, rc 2, instantly. (The whole point of `pipefail` here is so a failed `curl` fails the task instead of silently piping empty data to `gpg` — i.e. it would have made Trap 1 fail fast too.)

→ Fix: add `args.executable: /bin/bash` to the shell task. This is the established repo pattern — see `dot_ansible/roles/iac_tools/tasks/main.yml` (every `set -eo pipefail` shell task there sets `executable: /bin/bash`).

## The fix (both traps)

```yaml
- name: Add Resilio Sync GPG key (dearmored)
  ansible.builtin.shell: |
    set -eo pipefail
    curl -fsSL --retry 3 --retry-delay 2 --max-time 60 \
      https://linux-packages.resilio.com/resilio-sync/key.asc \
      | gpg --dearmor -o /etc/apt/keyrings/resilio-sync.gpg
  args:
    executable: /bin/bash          # dash has no pipefail
    creates: /etc/apt/keyrings/resilio-sync.gpg
# ... and deb822_repository uris: https://linux-packages.resilio.com/resilio-sync/deb
```

## Related design note (not a bug, but why the failure was clean)

The per-user service tasks are gated on `dpkg-query -W ... resilio-sync` reporting `install ok installed`.
Before that gate they ran unconditionally and reported a misleading `ok` while *enabling a systemd unit that
never existed*. If you see the service tasks "succeed" but `systemctl --user status resilio-sync` says
"could not be found", check that gate is present. See `docs/tools/resilio-sync.md`.
