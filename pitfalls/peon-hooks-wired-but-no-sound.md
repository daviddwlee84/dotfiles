# Agent sound hooks are wired but nothing ever plays (`ansible_env` is undefined)

**Symptoms** (grep this section):
- `agentSounds` is `peon` (or `both`), `chezmoi apply` ran clean, and
  `~/.claude/settings.json` **does** carry all 9 peon hook events — but no sound
  ever plays and no peon overlay banner appears
- Claude Code's own hook trace reports success:
  `PreCompact [[ -x "$HOME/.claude/hooks/peon-ping/peon.sh" ] && … || true] completed successfully`
- `peon status` is perfectly healthy — `peon-ping: active`, `sounds enabled`,
  `default pack: sc2_scv`, `1 pack(s) installed`
- `peon preview task.complete` plays the sound fine by hand
- `ls ~/.claude/hooks/peon-ping/` → `No such file or directory`
- `~/.config/opencode/plugins/peon-ping.ts` is also missing
- In an ansible run:
  `Task failed: … Error while resolving value for 'creates': 'ansible_env' is undefined`
  followed by `...ignoring`

**First seen**: 2026-07
**Affects**: `dot_ansible/roles/coding_agents` peon-ping staging tasks; any
ansible task in this repo that uses a bare injected fact variable
**Status**: fixed — tasks use `ansible_facts['env']['HOME']`, parent dirs are
created explicitly, and a `ansible-no-injected-fact-vars` pre-commit hook blocks
regressions

## Root cause

`dot_ansible/ansible.cfg` sets:

```ini
inject_facts_as_vars = False
```

which means the bare injected fact variables **do not exist at runtime**. Facts
are reachable only through `ansible_facts[...]`. So this:

```yaml
dest: "{{ ansible_env.HOME }}/.claude/hooks/peon-ping/peon.sh"
```

is valid YAML, passes `ansible-playbook --syntax-check`, and then fails at run
time with `'ansible_env' is undefined`. The repo-wide idiom is
`{{ ansible_facts['env']['HOME'] }}` — 288 uses against the 6 that regressed,
all 6 in the peon block.

## Why it was invisible

Three independent silencers stacked, which is what made this cost real debugging
time rather than being obvious from the apply log:

1. **`ignore_errors: true`** on the staging blocks (correct in itself — a
   missing sound player must never abort a `chezmoi apply`) demotes the failure
   to a `...ignoring` line that scrolls past in a long run.
2. **The overlay's own guard** is `[ -x "$HOME/.claude/hooks/peon-ping/peon.sh" ] && … || true`.
   That guard exists so boxes without peon don't spam hook errors — but it turns
   a *missing* target into a **successful no-op**, so Claude Code cheerfully
   reports `completed successfully` on all 9 events.
3. **`peon status` inspects `~/.openpeon`, not the hook wiring.** The CLI, the
   pack, and the config were all genuinely fine; nothing in its output covers
   whether anything is actually *calling* it.

Net effect: every layer reported success and the only real signal — a symlink
that was never created — is not something any of them look at.

## Second, independent bug in the same block

`ansible.builtin.file` with `state: link` **does not create intermediate
directories**. Verified:

```
Error while linking: [Errno 2] No such file or directory:
  b'/tmp/…/src/peon.sh' -> b'/tmp/…/dest/peon-ping/peon.sh'
```

`~/.claude/hooks/` exists on any box with `notify.sh`, but
`~/.claude/hooks/peon-ping/` only exists if `peon-ping-setup` ran — and this
repo deliberately never runs it (see
[`peon-ping-setup-escapes-home.md`](peon-ping-setup-escapes-home.md)). So even
after fixing `ansible_env`, the link task would still have failed. Both fixes
are required; fixing either alone leaves the machine silent.

This one is easy to miss because the *other* symlink in the same role
(`~/.config/opencode/plugins/peon-ping.ts`) has a parent that already exists, so
it would have started working while Claude stayed silent — pointing suspicion at
Claude's hook format rather than at the shared staging code.

## Fix

```yaml
- name: Ensure the Claude peon-ping hook directory exists
  when: coding_agents_peon_sh.stdout | default('') | length > 0
  ansible.builtin.file:
    path: "{{ ansible_facts['env']['HOME'] }}/.claude/hooks/peon-ping"
    state: directory
    mode: "0755"

- name: Symlink peon.sh into the canonical Claude hook path
  when: coding_agents_peon_sh.stdout | default('') | length > 0
  ansible.builtin.file:
    src: "{{ coding_agents_peon_sh.stdout }}"
    dest: "{{ ansible_facts['env']['HOME'] }}/.claude/hooks/peon-ping/peon.sh"
    state: link
    force: true
```

## Verifying a fix (do not trust "apply succeeded")

`chezmoi apply` exiting 0 proves nothing here — that was the whole problem.
Check the artifact and then fire the hook the way Claude Code does:

```sh
ls -la ~/.claude/hooks/peon-ping/peon.sh          # must be a symlink into libexec
[ -x "$HOME/.claude/hooks/peon-ping/peon.sh" ] && echo OK

echo '{"hook_event_name":"Stop","session_id":"probe","cwd":"'"$PWD"'"}' \
  | "$HOME/.claude/hooks/peon-ping/peon.sh"

jq '.last_played' ~/.openpeon/.state.json
# -> { "task.complete": "sounds/JobsFinished.mp3" }
```

`.last_played` is the only machine-checkable proof that audio actually
dispatched; exit code 0 is not, because of silencer #2 above.

## Guard

`.pre-commit-config.yaml` → `ansible-no-injected-fact-vars` fails the commit on
`ansible_env` / `ansible_os_family` / `ansible_pkg_mgr` / … in
`dot_ansible/**/*.{yml,yaml,j2}`. Comment lines are exempt (`^[^#]*`) because
`coding_agents` and `lazyvim_deps` both discuss `ansible_pkg_mgr` in prose.

## Related

- [`peon-ping-setup-escapes-home.md`](peon-ping-setup-escapes-home.md) — why the
  installer is never run on a managed machine, which is *why* the hook directory
  is missing in the first place
- [`ansible-when-regex-replace-backslash-strip.md`](ansible-when-regex-replace-backslash-strip.md)
  — another "valid YAML, wrong at runtime" ansible trap in this repo
- [`docs/tools/agent-sounds.md`](../docs/tools/agent-sounds.md) — the tier design
