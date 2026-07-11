# Fix: LAN router CLIs break under a global HTTP/SOCKS proxy

## Context

`mi-router` (and its sibling `reyee`) talk to a router on the **LAN** (e.g.
`192.168.31.1`). But `httpx.Client` defaults to `trust_env=True`, so it reads
the user's shell proxy env:

```
ALL_PROXY=socks://127.0.0.1:7890
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
```

Two problems result:
1. **Wrong routing** — LAN traffic to the router should never go through a proxy.
2. **Hard crash** — httpx has no SOCKS support unless `httpx[socks]` is installed,
   so `ALL_PROXY=socks://…` raises `ValueError: Unknown scheme for proxy URL`
   before any request is even made (the traceback the user hit).

The router address is always a LAN IP for these tools, so the correct fix is to
tell httpx to ignore the ambient proxy env entirely.

## Approach

Pass `trust_env=False` to the `httpx.Client(...)` constructor. This disables
httpx's reading of `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` (and `.netrc` /
SSL env), which is exactly right for plaintext HTTP to a LAN device.

Rejected alternatives:
- Adding `httpx[socks]` — wrong direction; it would still route LAN traffic
  through the proxy, which cannot reach `192.168.31.1`.
- Setting `NO_PROXY` / custom `mounts` — more code for no benefit; these tools
  only ever contact the LAN router, so blanket `trust_env=False` is simplest and
  fully correct.

## Files to change

Both are exact mirrors — same one-line edit:

- `dot_dotfiles/bin/executable_mi-router:124`
  ```python
  self.client = httpx.Client(timeout=timeout, follow_redirects=False, trust_env=False)
  ```
- `dot_dotfiles/bin/executable_reyee:172` — identical change (same bug, same LAN-only
  assumption).

Add a short inline comment on each explaining why (`# LAN device — ignore ambient
HTTP(S)/SOCKS proxy env`).

## Out of scope (note only)

- `dot_dotfiles/bin/executable_sms` uses `huawei-lte-api`'s `Connection` (backed
  by `requests`, not httpx), so it has the same latent problem but a different
  fix (`requests.Session(trust_env=False)` passed via `requests_session=`). The
  user did not report `sms` failing; leave it unless they want it fixed too.

## Verification

On this proxied host (`ALL_PROXY=socks://127.0.0.1:7890` is set):

1. Apply and run the tool against the live router:
   ```
   chezmoi apply --include=dot_dotfiles/bin/executable_mi-router
   mi-router wifi          # should print the Wi-Fi table, no ValueError
   mi-router login-test    # quick creds/connectivity check
   ```
   (Credentials are already saved in `~/.config/mi-router/config.toml`.)
2. Sanity-check the proxy is genuinely being bypassed — the traceback originating
   from `httpx/_config.py … Unknown scheme for proxy URL` must be gone.
3. No completion/doc updates required: this is an internal bug fix with no change
   to the CLI surface (subcommands/flags unchanged), so per CLAUDE.md's cross-file
   table nothing else needs touching. Optionally add a one-line
   `pitfalls/` note ("LAN router CLI crashes under global SOCKS proxy →
   `trust_env=False`") if we want it grep-able later.
