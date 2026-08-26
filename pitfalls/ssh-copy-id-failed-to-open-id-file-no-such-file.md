# `ssh-copy-id: ERROR: failed to open ID file '…pub': No such file or directory`

**Symptoms** (grep this section):

```
--- Copy public key to <host> ---
Run ssh-copy-id to enable passwordless login? [Y/n]

> ssh-copy-id -i /Users/you/.ssh/some_key.pub <host>

/usr/bin/ssh-copy-id: ERROR: failed to open ID file '/Users/you/.ssh/some_key.pub': No such file or directory
ssh-copy-id failed. You may need to enter the remote password.
```

- The key does not appear in `ssh-setup-remote`'s "Existing keys in ~/.ssh/"
  listing at all, even though `ls ~/.ssh/` shows it.
- `~/.ssh/<key>` (the private half) exists; `~/.ssh/<key>.pub` does not.

**First seen**: 2026-08-25, setting up a `ProxyJump`ed host
(`~/.ssh/trading_vm_ed25519` had no matching `.pub`).
**Affects**: `ssh-setup-remote` (`dot_config/shell/96_ssh_setup.sh`) and its
`dotfiles-windows` counterpart, any version before the ProxyJump/`.pub`-repair
rework. Also bites anyone hand-running `ssh-copy-id` against a key whose
public half is missing.
**Status**: fixed. The key-listing helper now globs `~/.ssh/*` (filtering out
`config`/`known_hosts*`/`authorized_keys`/`.pub`/sockets/`.DS_Store`) instead
of `~/.ssh/*.pub`, so a private-only key shows up in the picker flagged
`(no .pub)`. Selecting or auto-creating a key now runs a repair step right
after selection — before `ssh-copy-id` is ever invoked — that offers
`ssh-keygen -y -f <key> > <key>.pub`.

## Root cause

The public half of a key pair can go missing several ways that don't involve
losing the private key: copying only the private key between machines,
importing a key into an SSH agent (Bitwarden, 1Password, a YubiKey) without
also keeping the `.pub` file on disk, or a partial `scp`.

The old code had two independent bugs that combined to make this fail late
and confusingly instead of failing fast with a clear message:

1. The "existing keys" listing globbed `~/.ssh/*.pub` — so a private key with
   no public half was **invisible in the picker**, even though typing its
   path manually still worked.
2. The existence guard was `[ ! -f "$key_path" ] && [ ! -f "${key_path}.pub" ]`
   — **OR semantics**: it only rejected the input when *both* files were
   missing. A private key alone passed straight through to `ssh-copy-id`,
   which needs the `.pub` file specifically and fails with the errno message
   above.

## Workaround (works on any version)

The public key is always derivable from the private key:

```bash
ssh-keygen -y -f ~/.ssh/some_key > ~/.ssh/some_key.pub
chmod 644 ~/.ssh/some_key.pub
```

(Prompts once for the passphrase if the key has one.) Then re-run
`ssh-copy-id` / `ssh-setup-remote`.

## Prevention

Current `ssh-setup-remote` does this automatically: key selection is followed
by an unconditional `.pub` check that offers the `ssh-keygen -y` repair before
any remote command runs. See `docs/tutorials/setup_ssh_key_on_remote.md` →
"A private key with no `.pub`".
