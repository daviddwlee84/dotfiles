"""Fleet orchestration package.

This `__init__.py` re-exports the shared inventory loading + SSH helpers from
`scripts/fleet/apply.py` (the chezmoi backend) so other subcommands
(`scripts/fleet/tmux.py`, `scripts/fleet/info.py`, `scripts/fleet/pueue.py`,
`scripts/fleet/exec.py`) can `from scripts.fleet import ...` without referring
to a specific submodule.

History: prior to 2026-05-13 this file lived at `scripts/fleet_apply.py` and
was the only fleet code. As the namespace grew (`fleet tmux/info/pueue/exec`
+ the user-facing `fleet chezmoi` rename), the file was moved into the
package and renamed `apply.py`. Eventually the shared `Host`/`load_hosts`
plumbing could carve out to `scripts/fleet/_lib.py`; for now `apply.py`
owns it.
"""

from __future__ import annotations

from scripts.fleet.apply import (
    DEFAULT_CONFIG_PATH,
    LOCAL_LOG_DIR,
    REMOTE_LOG_DIR,
    REMOTE_SUDO_PASS_PATH,
    Host,
    _connect_kwargs,
    connect_host,
    load_hosts,
    resolve_passwords,
    resolve_ssh_login_passwords,
)

__all__ = [
    "DEFAULT_CONFIG_PATH",
    "LOCAL_LOG_DIR",
    "REMOTE_LOG_DIR",
    "REMOTE_SUDO_PASS_PATH",
    "Host",
    "_connect_kwargs",
    "connect_host",
    "load_hosts",
    "resolve_passwords",
    "resolve_ssh_login_passwords",
]
