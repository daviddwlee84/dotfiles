# `uv sync` fails with "Network is unreachable (os error 101)" on a USTC PyPI URL

**Symptoms** (grep this section): `error: Request failed after 3 retries`; `Caused by: Failed to fetch: https://pypi.mirrors.ustc.edu.cn/simple/<pkg>/`; `Caused by: error sending request for url (https://mirrors.ustc.edu.cn/pypi/simple/<pkg>/)`; `Caused by: tcp connect error`; `Caused by: Network is unreachable (os error 101)`; `curl` to the same URL works; the failing package is one that the first index (Aliyun) clearly has
**First seen**: 2026-11-20
**Affects**: uv 0.11.19 with the chezmoi `useChineseMirror` `uv.toml` (Aliyun → TUNA → USTC, `index-strategy = "unsafe-first-match"`) on a host with no IPv6 default route (ts_nas, Ubuntu)
**Status**: fixed in the template (USTC replaced by Huawei, 2026-11-20); hosts that have not re-applied chezmoi need a workaround

## Symptom

```
$ uv sync
error: Request failed after 3 retries in 5.7s
  Caused by: Failed to fetch: `https://pypi.mirrors.ustc.edu.cn/simple/jsonschema/`
  Caused by: error sending request for url (https://mirrors.ustc.edu.cn/pypi/simple/jsonschema/)
  Caused by: client error (Connect)
  Caused by: tcp connect error
  Caused by: Network is unreachable (os error 101)
```

It reads like "the network is down" or "there is no mirror configured". Neither is true: the
mirror config is present, and Aliyun and TUNA answer normally.

## Root cause

- `pypi.mirrors.ustc.edu.cn` now answers `301` to `mirrors.ustc.edu.cn/pypi/simple/`.
- `mirrors.ustc.edu.cn` has an AAAA record (`2001:da8:d800:95::110`). uv connects to the IPv6
  address and, without an IPv6 route, gets `ENETUNREACH` (os error 101) instead of falling back to
  IPv4. `curl` falls back, which is why probing with curl looks fine.
- A broken index anywhere in the list breaks the whole resolution. uv touches every configured
  index (including cache revalidation, `Found stale response … Sending revalidation request`), so
  being third behind Aliyun and TUNA does not protect you.
- Setting only `UV_INDEX` / `UV_DEFAULT_INDEX` does **not** help: uv merges them with the config
  file's `[[index]]` entries and still contacts USTC.

Measured from ts_nas (2026-11-20, `curl -4`):

| index | AAAA | IPv4 |
|---|---|---|
| mirrors.aliyun.com | none | 200, 0.09 s |
| pypi.tuna.tsinghua.edu.cn | yes | 200, 1.2 s (uv works) |
| pypi.mirrors.ustc.edu.cn | yes (after redirect) | 301 |
| repo.huaweicloud.com | none | 200, 0.28 s |
| mirrors.cloud.tencent.com | yes | 200, 0.28 s |

## Fix

Template: `dot_config/uv/uv.toml.tmpl` now lists Aliyun → TUNA → Huawei (Huawei has no AAAA
record). Re-apply chezmoi on affected hosts.

Workaround for a host that cannot re-apply yet (put it in `~/.shellrc.adhoc`; interactive shells only):

```sh
export UV_NO_CONFIG=1
export UV_INDEX_STRATEGY=unsafe-first-match
export UV_INDEX="https://mirrors.aliyun.com/pypi/simple/ https://pypi.tuna.tsinghua.edu.cn/simple/ https://repo.huaweicloud.com/repository/pypi/simple/"
```

`UV_NO_CONFIG=1` also skips `[tool.uv]` settings in a project's `pyproject.toml`
(`[tool.uv.sources]` still resolves); unset it for a project that relies on them. One-off:
`uv sync --config-file <copy of uv.toml without USTC>`.

## Prevention

- Before adding a PyPI mirror, check `getent ahostsv6 <host>` and redirects
  (`curl -sI`), and test with `uv sync --dry-run`, not curl, from a host without IPv6.
- Prefer indexes whose final host is IPv4-only, or keep the list short: every extra index is one
  more way for the whole resolution to fail.

## Related

- `docs/tools/mirrors.md` (PyPI row)
- [`docker-pull-fails-dead-registry-mirrors`](docker-pull-fails-dead-registry-mirrors.md): the same lesson for Docker, where one dead mirror poisons pulls
