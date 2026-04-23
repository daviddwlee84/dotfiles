# `npm install -g <pkg>` hangs forever after "Downloading https://github.com/.../releases/..."

**Symptoms** (grep this section):
- `npm install -g tree-sitter-cli` hangs indefinitely on a fresh China-based
  (GFW) host
- Last visible output: `Downloading https://github.com/tree-sitter/tree-sitter/releases/download/vX.Y.Z/tree-sitter-linux-x64.gz`
- `npm http fetch GET 200 https://registry.npmmirror.com/...` succeeds (so npm
  registry mirror IS working)
- `ansible-playbook` task `Install tree-sitter-cli via mise npm` never returns;
  whole `chezmoi apply` runs over `command_timeout` budget (2 hours)
- `pgrep -lf "node install"` shows `node install.js` stuck; `strace -p <pid>`
  shows it `read(socket, ...)` blocked
- `ssh HOST pstree -p $PID` shows `chezmoi → ansible-playbook → … → node install.js`

**First seen**: 2026-04 on `jingle207` (Ubuntu 22.04, China network, useChineseMirror=true)
**Affects**: any npm package whose `postinstall` script downloads a prebuilt
binary directly from `github.com/.../releases/download/...` — confirmed for
`tree-sitter-cli`, suspected for any node-gyp prebuilt fallback path
**Status**: workaround in place (`timeout 180` + cargo fallback in
`dot_ansible/roles/lazyvim_deps/tasks/main.yml`); no upstream fix expected
(tree-sitter install.js hardcodes the URL, no env-var override)

## Symptom

After running `chezmoi apply` (or `just fleet-apply`) on a fresh Ubuntu host
in China, the apply hangs at:

```
[27] TASK · [lazyvim_deps : Check if tree-sitter is installed]
ok: [localhost] (0.5s)
[28] TASK · [lazyvim_deps : Install tree-sitter-cli via mise npm (Debian/Ubuntu)]
```

Drill in:

```bash
ssh HOST pgrep -lf "tree-sitter|node install|npm install tre"
# 1539421 npm install tre
# 1539702 sh
# 1539703 MainThread
```

Reproduce manually:

```bash
ssh HOST 'mise exec -- npm install -g tree-sitter-cli --loglevel=http' &
# After ~30s, output stops at:
# npm http fetch GET 200 https://registry.npmmirror.com/tree-sitter-cli 123ms (cache revalidated)
# (then nothing — postinstall hangs)
```

Force the postinstall to error fast to see what it's doing:

```bash
ssh HOST 'timeout 30 mise exec -- npm install -g tree-sitter-cli 2>&1 | tail -10'
# npm error signal SIGTERM
# npm error command sh -c node install.js
# npm error Downloading https://github.com/tree-sitter/tree-sitter/releases/download/v0.26.8/tree-sitter-linux-x64.gz
```

## Root cause

`tree-sitter-cli`'s `package.json` has a `postinstall` script that runs
`node install.js`. The script (verbatim, from the package):

```js
const releaseURL = `https://github.com/tree-sitter/tree-sitter/releases/download/v${packageJSON.version}`;
const assetName = `tree-sitter-${platform.name}-${arch.name}.gz`;
const assetURL = `${releaseURL}/${assetName}`;
// ...
get(assetURL, response => { ... });
```

The URL is **hardcoded**. There is no `TREE_SITTER_BINARY_URL`,
`TREE_SITTER_MIRROR`, or any environment-variable override.

`github.com` itself is reachable from China (HTTP 200 with reasonable
latency), but it issues a 302 redirect to
`release-assets.githubusercontent.com` — Azure blob storage — which is
frequently unreachable or extremely slow from Chinese networks. The Node
HTTPS client has no default timeout, so the connection hangs indefinitely
in `read()` waiting for the TLS handshake or first byte.

Why the npm tarball mirror doesn't help: `registry.npmmirror.com` mirrors
the npm package itself (the `.tgz` containing JS files, including
`install.js`). It does NOT mirror the `tree-sitter` binary releases (those
are published to GitHub Releases, not to npm). npmmirror's binary mirror
namespace (`/-/binary/`) only covers ~99 well-known projects (Node.js,
Electron, Chromium, etc.); tree-sitter is not on the list.

Why ansible's `ignore_errors: true` doesn't save you: it only catches
non-zero exit. A hang has no exit code — the task just sits in `running`
state until ansible's external timeout (none by default) or fleet-apply's
outer `command_timeout` kicks in (2h default).

## Workaround

Wrap the npm install with `timeout(1)` and trigger a `cargo install` fallback
on non-zero exit (timeout exits 124, which is non-zero):

```yaml
- name: Install tree-sitter-cli via mise npm (Debian/Ubuntu)
  ansible.builtin.shell: |
    timeout 180 {{ mise_bin }} exec -- npm install -g tree-sitter-cli
  args:
    executable: /bin/bash
  register: treesitter_npm
  changed_when: "'added' in treesitter_npm.stdout or 'added' in treesitter_npm.stderr"
  failed_when: false  # Don't kill the play; cargo fallback handles it.

- name: Install tree-sitter-cli via cargo (fallback)
  when:
    - treesitter_npm.rc | default(1) != 0  # Catches both fail AND timeout 124.
  ansible.builtin.shell: |
    cargo install tree-sitter-cli
```

Why cargo works behind GFW:

- `crates.io` is mirrored via TUNA sparse index (configured in
  `~/.cargo/config.toml` when `useChineseMirror=true`)
- `cargo install` builds from source on the local machine — no GitHub
  Releases roundtrip
- All transitive deps come through the same TUNA mirror

Cost: ~3-5 min build time vs ~30s for the prebuilt binary, plus
`libclang-dev` apt dep (also installed by the role).

Manual one-shot fix on a host that's already stuck:

```bash
# Kill the hung npm process tree
ssh HOST 'pkill -9 -f "npm install -g tree-sitter-cli"; pkill -9 -f "node install.js"'

# Install via cargo using the right rustc (mise's, not system 1.75):
ssh HOST 'mise exec -- cargo install tree-sitter-cli'

# Verify
ssh HOST '~/.cargo/bin/tree-sitter --version'
```

## Prevention

When adding a new ansible task that runs `npm install -g <package>`:

1. **Check for postinstall binary downloads** before merging:

   ```bash
   npm view <package> scripts.postinstall
   # Or read the package's install.js / preinstall.js
   ```

   If the script `https.get` from `github.com/.../releases/`, you're at
   risk on GFW hosts.

2. **Always wrap with `timeout`**, even if the package looks safe today
   — postinstall scripts can be added in a minor release. Pick a
   timeout that's 3-5x the expected install time on a working network.

3. **Provide a fallback** — usually `cargo install`, `apt install`, or
   manual binary download from a mirrored host (npmmirror's
   `/-/binary/` namespace, conda-forge, etc.).

4. **Use `failed_when: false` + explicit `rc` gate**, not `ignore_errors:
   true`. The latter masks the failure but keeps the task `ok` in
   recap, hiding the fact that the fallback fired.

5. **Consider whether npm is even the right install method.** For
   tree-sitter specifically, `cargo install` works on every platform
   without GFW concerns; the npm path only exists because it's faster
   on a clean network. If you don't care about install speed, skip npm
   entirely.

## Related

- [docs/tools/mirrors.md → npm postinstall scripts](../docs/tools/mirrors.md#npm-postinstall-scripts-that-download-from-github-releases)
  — coverage matrix and adding-new-tasks checklist
- [docs/this_repo/fleet-apply.md → When a host hangs](../docs/this_repo/fleet-apply.md#when-a-host-hangs)
  — recovery flow when this (or a similar) hang manifests as a stuck
  fleet-apply run
- [tree-sitter/tree-sitter-cli install.js](https://github.com/tree-sitter/tree-sitter/blob/master/cli/npm/install.js)
  — upstream source confirming hardcoded URL
