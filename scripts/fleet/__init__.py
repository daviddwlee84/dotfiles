"""Fleet orchestration package.

This `__init__.py` re-exports the shared inventory loading + SSH helpers from
the legacy `scripts/fleet_apply.py` so new subcommands (`scripts/fleet/tmux.py`,
`scripts/fleet/info.py`) can `from scripts.fleet import ...` without referring
to the legacy filename.

When the body of `scripts/fleet_apply.py` is eventually carved out into
`scripts/fleet/_lib.py`, only the import targets in this file change — every
downstream `from scripts.fleet import Host, ...` keeps working unchanged.
"""

from __future__ import annotations

from scripts.fleet_apply import (
    DEFAULT_CONFIG_PATH,
    LOCAL_LOG_DIR,
    REMOTE_LOG_DIR,
    REMOTE_SUDO_PASS_PATH,
    Host,
    _connect_kwargs,
    load_hosts,
    resolve_passwords,
)

__all__ = [
    "DEFAULT_CONFIG_PATH",
    "LOCAL_LOG_DIR",
    "REMOTE_LOG_DIR",
    "REMOTE_SUDO_PASS_PATH",
    "Host",
    "_connect_kwargs",
    "load_hosts",
    "resolve_passwords",
]
