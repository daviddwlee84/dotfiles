# VisiData 3.3 crashes opening `.feather` saved with pandas StringDtype — `Could not convert ... to a NumPy dtype` / `Cannot interpret '<StringDtype(na_value=<NA>)>' as a data type`

**Symptoms** (grep this section):

- `visidata foo.feather` opens, prints `opening foo.feather as feather`, then dies with
  ```text
  ValueError: Could not convert 0  sz-123251-d5442447
  1  sz-123258-d54458be
  ...
  Name: client_order_id, Length: 443, dtype: string to a NumPy dtype
  (via `.dtype` value <StringDtype(na_value=<NA>)>).
  ```
- Or, with older pandas (2.x): same `ValueError` but trailing string is
  `string[python]` instead of `<StringDtype(na_value=<NA>)>`.
- VisiData status pane shows `raw() returned ERR`; sheet has 0 rows / 1 dummy col.
- Pure `pd.read_feather('foo.feather')` succeeds — file is well-formed.
- Other `.feather` files from the same producer (or earlier days) open fine —
  only files whose **schema metadata** has `numpy_type: string` trigger it.

**First seen**: 2026-05
**Affects**: VisiData ≥ 2.0 (the broken code path has existed since pandas 2.0
shipped `StringDtype`) — surfaces whenever the **feather file's embedded
pandas metadata** marks any column as `StringDtype`, which any DataFrame
written from pandas ≥ 2.0 + pyarrow ≥ 7 will do by default for `string` cols.
v3.3 (latest on PyPI as of 2026-05) is unfixed; no relevant issue/PR upstream.
**Status**: workaround documented (this repo ships
[`dot_visidatarc`](../dot_visidatarc) — auto-routes `.feather` to the pure-arrow
loader; explicit per-invocation escape hatch via the `vd-arrow` alias in
[`dot_config/shell/10_aliases.sh`](../dot_config/shell/10_aliases.sh)).

## Symptom

```text
$ visidata sz_2026-05-13.feather
saul.pw/VisiData v3.3
opening sz_2026-05-13.feather as feather
ValueError: Could not convert 0      sz-123251-d5442447
1      sz-123258-d54458be
...
442    sz-128142-1e672faf
Name: client_order_id, Length: 443, dtype: string to a NumPy dtype
(via `.dtype` value <StringDtype(na_value=<NA>)>).
```

The exact trailing repr is version-dependent:

| pandas | pyarrow | what `.dtype` reports |
| --- | --- | --- |
| 3.0.x | 23.x  | `<StringDtype(na_value=<NA>)>` |
| 2.3.x | 24.x  | `string[python]` |
| 2.3.x | 16-18 | `string[python]` |
| < 2   | any   | n/a — pandas 1.x falls back to `object` (no repro) |

But all four hit the **same code path** and the same `ValueError`/`TypeError`
in `np.issubdtype`.

Reproducer outside VisiData (run inside VisiData's tool venv —
`/home/taa/.local/share/uv/tools/visidata/bin/python`):

```python
import pandas as pd, numpy as np
df = pd.read_feather('foo.feather')
np.issubdtype(df['some_str_col'].dtype, np.integer)
# TypeError: Cannot interpret '<StringDtype(na_value=<NA>)>' as a data type
```

## Root Cause — two parts that compound

### Part 1 — VisiData's feather loader funnels through pandas

[`visidata/loaders/_pandas.py`](https://github.com/saulpw/visidata/blob/main/visidata/loaders/_pandas.py)
auto-registers an `open_feather` shim that does
`PandasSheet(..., filetype='feather')`, which in turn calls
`pd.read_feather()` and then, for each column:

```python
# loaders/_pandas.py (paraphrased)
def dtype_to_type(self, dtype):           # <-- name lies: caller passes Series
    dtype = getattr(dtype, 'numpy_dtype', dtype)   # Series has no numpy_dtype
    if np.issubdtype(dtype, np.integer):  # <-- explodes on StringDtype
        return int
    ...

# in reload():
self.dtype_to_type(df[col])   # Series, not dtype
```

This has been broken **since pandas 2.0 (Apr 2023)** but most users never
noticed because, until pyarrow ≥ 14ish, `pd.read_feather` returned `object`
dtype for strings; the new `StringDtype` only became default for newly
written feather files in pandas 2.x + pyarrow ≥ 7 once the writer started
embedding `numpy_type: string` in the schema metadata.

### Part 2 — The dtype is baked into the feather file

```bash
$ python -c "
import pyarrow.feather as ft, json
t = ft.read_table('foo.feather')
print(json.loads(t.schema.metadata[b'pandas'])['columns'][1])
"
{'name': 'client_order_id', 'pandas_type': 'unicode',
 'numpy_type': 'string', 'metadata': None}
```

`pd.read_feather` honours this metadata and **restores** the column as
`StringDtype` regardless of which pandas / pyarrow version you read with.
So **downgrading the reader doesn't help** — the dtype identity travelled
inside the file.

Verified (with `--with 'pandas<3'` etc. via `uv run --isolated`): pandas 2.3.3 +
pyarrow 16 / 18 / 24 all hit `Cannot interpret 'string[python]' as a data type`
on the same file. The only escape would be pandas 1.x, but pandas 1.x doesn't
build on Python ≥ 3.12 (the version VisiData's tool venv uses today).

## Workaround — use the pure-arrow loader instead

VisiData also ships [`visidata/loaders/arrow.py`](https://github.com/saulpw/visidata/blob/main/visidata/loaders/arrow.py),
an **independent** pyarrow-only loader (`ArrowSheet`) that doesn't go through
pandas at all. Feather v2 is the Arrow IPC file format, so the same file
loads cleanly:

```sh
visidata -f arrow foo.feather   # works
```

This repo wires that up two ways:

1. **Permanent**, transparent — [`dot_visidatarc`](../dot_visidatarc) monkey-patches
   `VisiData.open_feather` to return `ArrowSheet` instead of `PandasSheet`.
   After `chezmoi apply`, plain `visidata foo.feather` "just works" without
   the `-f arrow` flag. Verified locally:
   ```text
   opening foo.feather as feather
   class: ArrowSheet  rows: 443  cols: 14   ← was: ValueError + 0 rows
   ```
2. **Explicit escape hatch** — `vd-arrow <file>` shell alias in
   [`dot_config/shell/10_aliases.sh`](../dot_config/shell/10_aliases.sh). Useful
   on machines where the dotfile hasn't been deployed yet, or when you want
   to bypass the override without editing `~/.visidatarc`.

> **Why `setattr(VisiData, …)` and not the `@VisiData.api` decorator?**
> The `for ft in 'feather gbq orc pickle sas stata'.split()` loop in
> `loaders/_pandas.py` already installed `open_feather` as a class attribute
> by the time `~/.visidatarc` loads. `@VisiData.api` resolves through the
> live `vd` instance and (in my testing on v3.3) **did not** shadow that
> attribute — the PandasSheet path still ran. Direct
> `VisiData.open_feather = open_feather` works because it replaces the
> attribute at the class level where the loader looks it up.

### Trade-off of the override

`ArrowSheet` lacks some `PandasSheet`-only conveniences (vectorized
`selectByRegex`, `g/`, in-place `sort` via `pd.DataFrame.sort_values`,
`PandasSheet`'s `addRow`/`delete_row` undo paths). VisiData still works
in arrow mode — sorting, filtering by typing `|`/`\`, copy, save-as — just
through the generic `Sheet` machinery instead of the pandas fast paths.
For day-to-day "open this file and look at it", indistinguishable. If you
ever need PandasSheet semantics back on a known-safe `.feather`, fall back
to `visidata -f feather foo.feather` (will explode unless the file's
metadata is StringDtype-free).

## Why not downgrade pandas / pyarrow in the visidata tool venv?

This was the first thing tried (the `dot_ansible/roles/python_uv_tools/defaults/main.yml`
entry already pins `--with pandas --with pyarrow` for visidata). Reasons it
doesn't fix this:

- The dtype identity is **in the file**, not in the reader (Part 2 above).
- The bug is in VisiData's `dtype_to_type`, which has been broken since
  pandas 2.0. Going to pandas 1.x would mask it, but pandas 1.x doesn't
  install on Python ≥ 3.12 — and downgrading just visidata's venv Python
  cascades into rebuilding numpy/pyarrow from source on every host.
- The CentOS 7 branch in `dot_ansible/roles/python_uv_tools/tasks/main.yml`
  already skips visidata via `needs_modern_gcc: true`, so the GFW-era
  `--with 'pandas<2'` workaround documented in
  [`centos7-numpy-pandas-source-build`](centos7-numpy-pandas-source-build.md)
  doesn't intersect this case.

So we leave the `with: [pandas, pyarrow]` pins alone — they're correct for
"open csv/json/parquet" and for the producer side. The fix is the
`open_feather` reroute, not a version pin.

## Prevention

- Keep `dot_visidatarc` deployed (default on every managed machine).
- When writing new pipelines that emit `.feather` AND will be inspected by
  VisiData on a host without this override (e.g. a colleague's machine),
  prefer one of:
  - Cast string columns to `object` before `to_feather()`:
    ```python
    for c in df.select_dtypes('string').columns:
        df[c] = df[c].astype(object)
    df.to_feather(out)
    ```
  - Or write Parquet (`df.to_parquet(out)`), which VisiData routes through
    its `parquet.py` loader. *(Caveat: Parquet's loader can hit the same
    `dtype_to_type` path if a `parquet`-specific shim falls back to
    `_pandas.py`. Not observed yet — flag this here if you see it.)*

## Related

- VisiData [`loaders/_pandas.py`](https://github.com/saulpw/visidata/blob/main/visidata/loaders/_pandas.py)
  and [`loaders/arrow.py`](https://github.com/saulpw/visidata/blob/main/visidata/loaders/arrow.py)
  in the upstream tree.
- [`centos7-numpy-pandas-source-build.md`](centos7-numpy-pandas-source-build.md) —
  the *other* visidata-adjacent pandas/numpy trap. Distinct trigger
  (toolchain) and distinct fix (skip-via-`needs_modern_gcc`); cross-linked
  so grepping `visidata pitfalls/` finds both.
- `dot_ansible/roles/python_uv_tools/defaults/main.yml` — the install spec
  that pulls in `pandas + pyarrow` so VisiData has the feather loader at all
  (just doesn't make it work without `dot_visidatarc`).
- [`dot_visidatarc`](../dot_visidatarc) — the deployed fix.
- [`dot_config/shell/10_aliases.sh`](../dot_config/shell/10_aliases.sh) — the
  `vd-arrow` escape-hatch alias.
