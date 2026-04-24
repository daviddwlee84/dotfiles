# `nvim-treesitter` `:TSInstall` fails on every parser with `spawn …/tree-sitter-cli/tree-sitter EACCES` — even though `tree-sitter --version` reports a version

**Symptoms** (grep this section):
- In Neovim, every `:TSInstall <lang>` (or auto-install on open) prints the
  same error for bash, python, javascript, html, markdown, yaml, json5, regex,
  luap, printf, dockerfile, xml, rst, vim, diff, c, typescript, query,
  git_config, markdown_inline, luadoc — literally every parser:
  ```
  [nvim-treesitter/install/<lang>] error: Error during "tree-sitter build":
  node:events:486
        throw er; // Unhandled 'error' event
        ^
  Error: spawn /home/<user>/.local/share/mise/installs/node/<VER>/lib/node_modules/tree-sitter-cli/tree-sitter EACCES
      at ChildProcess._handle.onexit (node:internal/child_process:286:19)
      at onErrorNT (node:internal/child_process:484:16)
      at process.processTicksAndRejections (node:internal/process/task_queues:89:21)
  Emitted 'error' event on ChildProcess instance at:
      at ChildProcess._handle.onexit (node:internal/child_process:292:12)
      ...
      errno: -13,
      code: 'EACCES',
      syscall: 'spawn /home/…/tree-sitter-cli/tree-sitter',
      spawnargs: [ 'build', '-o', 'parser.so' ]
  ```
- `tree-sitter --version` from the shell reports a version normally (e.g.
  `tree-sitter 0.26.8`) with exit code **0** → looks healthy
- `ls -la ~/.local/share/mise/installs/node/<VER>/lib/node_modules/tree-sitter-cli/tree-sitter`
  shows a **0-byte file** with mode **`-rw-------`** (0600) — not executable,
  no content
- `chezmoi apply` re-runs never reinstall tree-sitter: ansible's
  `treesitter_check` sees `rc=0` from `--version` and skips the install block
- Affected actions: `:TSInstall!`, `:TSUpdate`, any LazyVim auto-install on
  buffer open → red error banners, no syntax highlighting for the target
  language

**First seen**: 2026-04 on `jingle-207` (Ubuntu 22.04, noRoot=true,
useChineseMirror=true, tree-sitter-cli 0.26.8 installed via
`mise exec -- npm install -g tree-sitter-cli`). Traceable to an earlier apply
where the npm postinstall partially downloaded the prebuilt binary before
failing.
**Affects**: any host where `npm install -g tree-sitter-cli` postinstall
attempted to download `https://github.com/tree-sitter/tree-sitter/releases/download/vX.Y/tree-sitter-linux-<arch>.gz`
and the stream was interrupted (GFW flakiness, CDN 503, connection reset
mid-gunzip). The postinstall exits 0 even on failure.
**Status**: detection workaround in
`dot_ansible/roles/lazyvim_deps/tasks/main.yml` (aggregate check =
`--version` AND native-binary `[-s && -x]`); recovery = `rm` the empty
binary and reinstall. No upstream fix; this is a silent bug in
tree-sitter-cli's `install.js`.

## Symptom

Open any file type in Neovim on an affected host:

```
$ nvim foo.py
# red error banner appears repeatedly with the Node.js EACCES stack above,
# once per parser in the ensure_installed list
```

The shell-level sanity checks all pass:

```bash
$ which tree-sitter
/home/ldw/.local/share/mise/installs/node/24.13.0/bin/tree-sitter

$ tree-sitter --version
tree-sitter 0.26.8

$ echo "exit=$?"
exit=0
```

But the actual native binary is empty:

```bash
$ ls -la ~/.local/share/mise/installs/node/24.13.0/lib/node_modules/tree-sitter-cli/
-rwx------   303 Apr 22 23:16 cli.js        ← node wrapper (executable)
-rw-------  14k  Apr 22 23:16 dsl.d.ts
-rw------- 3.7k  Apr 22 23:16 install.js
-rw-------  749  Apr 22 23:16 package.json
-rw-------    0  Apr 22 23:16 tree-sitter   ← NATIVE BINARY, 0 BYTES, NOT EXECUTABLE
```

Resolution path (mise shim → mise dispatcher → cli.js → native `./tree-sitter`):

```bash
$ readlink -f $(which tree-sitter)
/home/ldw/.local/share/mise/installs/node/24.13.0/lib/node_modules/tree-sitter-cli/cli.js
```

`cli.js` is 303 bytes and IS executable — it's the thing that runs for
`tree-sitter --version`. When cli.js needs to do actual work (parser build),
it `spawn`s `./tree-sitter` relative to its own directory. That file is the
0-byte one.

## Root cause

Two bugs compound:

**Bug 1 (upstream, tree-sitter-cli)**: the npm `postinstall` script
`node install.js` downloads a prebuilt Linux binary from:

```
https://github.com/tree-sitter/tree-sitter/releases/download/v0.26.8/tree-sitter-linux-x64.gz
```

This 302-redirects to `release-assets.githubusercontent.com` (Azure blob
storage). On networks where Azure CDN is flaky (GFW, Cloudflare
interference, corporate proxy), the gunzip stream can:

- Complete the TCP connection and create the destination file
- Read 0 bytes (or a partial, corrupt stream)
- Fail the gunzip pipeline silently
- Still exit `install.js` with rc=0 via Node's default unhandled-rejection
  handler

Result: `./tree-sitter` exists, is 0 bytes, and retains the default
`fs.createWriteStream` mode of `0600` (which is `rw-` for owner, no exec
bit). The `fs.chmodSync(dest, '755')` call later in the script is either
never reached (exception swallowed) or was never there for the code path
that created the file.

The related "this hangs forever" failure mode is already documented in
[`pitfalls/npm-postinstall-github-releases-hang.md`](npm-postinstall-github-releases-hang.md).
This pitfall is the **opposite** failure: postinstall doesn't hang — it
returns "success" with a broken binary.

**Bug 2 (this repo, pre-fix)**: ansible's `treesitter_check` ran
`tree-sitter --version` as the liveness probe:

```yaml
- name: Check if tree-sitter is installed
  ansible.builtin.shell: |
    PATH="${HOME}/.cargo/bin:${PATH}" tree-sitter --version
  register: treesitter_check
  failed_when: false
```

But `--version` in `cli.js` just reads `package.json`:

```js
// cli.js (excerpt)
if (args[0] === '--version') {
  console.log(`tree-sitter ${require('./package.json').version}`);
  process.exit(0);
}
```

It never spawns the native binary. So `rc=0` from the check is consistent
with a completely broken install. The downstream install tasks (gated on
`treesitter_check.rc != 0`) were therefore never triggered, and re-running
`chezmoi apply` on an affected host indefinitely failed to self-heal.

## Workaround

**Immediate recovery on an affected host**:

Do NOT use `command -v tree-sitter` / `readlink -f` to locate the broken
binary — if cargo's version is also installed, PATH order may resolve to
cargo's healthy 12 MB ELF and you will delete the wrong thing. Scan the
mise install tree directly:

```bash
# 1. Find + delete every empty / non-executable native binary under mise's
#    node installs. Safe to run even if no mise npm install exists.
for d in "${HOME}/.local/share/mise/installs/node/"*/lib/node_modules/tree-sitter-cli; do
  [[ -d "$d" ]] || continue
  native="$d/tree-sitter"
  [[ -e "$native" ]] || continue
  if [[ ! -s "$native" || ! -x "$native" ]]; then
    echo "removing broken: $native"
    rm -f "$native"
  fi
done

# 2. Reinstall via mise/npm:
timeout 180 mise exec -- npm install -g tree-sitter-cli
# If this SIGTERMs on "Downloading https://github.com/.../releases/..." —
# the GFW/CDN hang — skip to step 3.

# 3. Fallback if step 2 fails (cargo builds from source via TUNA mirror):
cargo install tree-sitter-cli --force

# 4. If npm left the mise package dir behind without its native binary
#    (cli.js present, tree-sitter native missing), copy cargo's build in:
mise_dir=$(dirname "$(readlink -f "$(ls ~/.local/share/mise/installs/node/*/lib/node_modules/tree-sitter-cli/cli.js 2>/dev/null | head -1)")")
if [[ -n "$mise_dir" && ! -s "$mise_dir/tree-sitter" ]]; then
  cp "$HOME/.cargo/bin/tree-sitter" "$mise_dir/tree-sitter"
  chmod 755 "$mise_dir/tree-sitter"
fi

# 5. Verify: both the mise path AND cargo path (if present) should work.
tree-sitter --version                                     # uses first on PATH
"$HOME/.cargo/bin/tree-sitter" --version 2>/dev/null      # cargo path
```

Then in Neovim: `:TSInstall! <language>` should complete without EACCES.
(LazyVim's `ensure_installed` list will catch up on the next open.)

**Structural fix (in this repo, applied 2026-04)**:

Replace the `--version`-only check with a `--version` probe PLUS a direct
scan of every mise-installed tree-sitter-cli package, auto-purging any
whose native binary is empty or non-executable. See
`dot_ansible/roles/lazyvim_deps/tasks/main.yml`:

```yaml
- name: Check if tree-sitter --version works (any install path)
  when: ansible_facts["os_family"] == "Debian"
  ansible.builtin.shell: |
    PATH="${HOME}/.cargo/bin:${PATH}" tree-sitter --version
  register: treesitter_version_check
  changed_when: false
  failed_when: false

- name: Purge broken tree-sitter-cli native binary in mise node installs (if any)
  when: ansible_facts["os_family"] == "Debian"
  ansible.builtin.shell: |
    set +e
    for d in "${HOME}/.local/share/mise/installs/node/"*/lib/node_modules/tree-sitter-cli; do
      [[ -d "$d" ]] || continue
      native="$d/tree-sitter"
      [[ -e "$native" ]] || continue
      if [[ ! -s "$native" || ! -x "$native" ]]; then
        echo "BROKEN: $native"
        rm -f "$native"
      fi
    done
    exit 0
  register: treesitter_mise_cleanup
  changed_when: "'BROKEN' in (treesitter_mise_cleanup.stdout | default(''))"

- name: Compute treesitter_check aggregate
  ansible.builtin.set_fact:
    treesitter_check:
      rc: >-
        {{ 0 if (treesitter_version_check.rc | default(1) == 0
                 and not treesitter_mise_cleanup.changed)
           else 1 }}
```

Why scan the mise install tree directly (instead of `command -v tree-sitter`
+ `readlink -f`): on a host where cargo **also** installed tree-sitter
(fallback path fired on a previous apply), `command -v` — especially with
`${HOME}/.cargo/bin` prepended — resolves to the cargo monolithic binary,
not the mise shim, and the "is native binary healthy" check would pass
despite a broken mise install. nvim-treesitter may still pick the mise
path at runtime (PATH order, plugin config), so cargo's working binary
doesn't rescue it. Scanning `~/.local/share/mise/installs/node/*/lib/.../tree-sitter-cli/`
directly handles BOTH the single-install host (fresh mise-npm failure)
AND the dual-install host (stale broken mise alongside healthy cargo).

Downstream install tasks already gate on `treesitter_check.rc != 0` —
the aggregate fact makes the existing gates fire on broken-empty-binary
hosts without touching any other task.

## Prevention

When writing ansible liveness probes for tools that have **a lightweight
dispatcher wrapping a native binary** (tree-sitter, mise itself, rustup,
pyenv, many `uv`-installed shims), `--version` / `--help` is often a **false
positive signal** — it only exercises the wrapper, not the payload.

Checklist when writing a new "is this tool installed" probe:

1. **Does `--version` spawn the actual binary?** Inspect the wrapper script
   (often JS or shell). If it just reads from a manifest, you need a
   stronger probe.
2. **Is there a dry-run command that exercises the native binary?** E.g.
   `tree-sitter dump-languages | head`, `cargo --list`,
   `rustup toolchain list`. Prefer these over `--version`.
3. **Stat the resolved binary.** `readlink -f` through the shim chain and
   check `[[ -s PATH && -x PATH ]]` — cheap and catches both the
   empty-file case and the no-exec case.
4. **Don't trust postinstall scripts that touch the network.** Especially
   those that download prebuilt binaries from GitHub Releases (see
   [`brew-cask-slow-github-release-assets.md`](brew-cask-slow-github-release-assets.md)
   and [`npm-postinstall-github-releases-hang.md`](npm-postinstall-github-releases-hang.md)
   for the "slow" and "hangs forever" failure modes).

## Related

- [`pitfalls/npm-postinstall-github-releases-hang.md`](npm-postinstall-github-releases-hang.md)
  — sibling pitfall: same install path, hang instead of silent-empty-file
  failure. Both caused by the same upstream hardcoded URL to GitHub
  release-assets.
- [`pitfalls/brew-cask-slow-github-release-assets.md`](brew-cask-slow-github-release-assets.md)
  — same CDN path, different tool (Homebrew cask). Slow but usually
  eventually succeeds; doesn't produce empty files.
- [`docs/tools/mirrors.md`](../docs/tools/mirrors.md) → npm postinstall
  scripts that download from GitHub Releases
- [tree-sitter/tree-sitter-cli `install.js`](https://github.com/tree-sitter/tree-sitter/blob/master/cli/npm/install.js)
  — upstream source; no error handling for partial stream / zero-byte
  output case
