#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML>=6.0"]
# ///
"""Parser for Clash / mihomo config YAML files, used by the `clash` tv channel.

Subcommands emit TSV rows for the TV source (`proxies`, `groups`, `rules`,
`summary`) or plain text for previews / copy actions (`path`, `yaml`, `server`,
`controller`).

TSV schema: kind \t name \t type_or_meta \t server_or_target \t extra
kind ∈ {proxy, group, rule, config, none}

Config discovery order (first existing file wins):
    $CLASH_CONFIG env var (explicit override)
    ~/.config/clash/config.{yaml,yml}
    ~/.config/mihomo/config.{yaml,yml}
    ~/Library/Application Support/clash/config.{yaml,yml}   (macOS)
    ~/Library/Application Support/mihomo/config.{yaml,yml}  (macOS)

Parsed config is cached as YAML.safe_load output; this script never writes back
to the config file.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import yaml


def _default_candidate_paths() -> list[Path]:
    home = Path.home()
    paths: list[Path] = []
    for base in (
        home / ".config" / "clash",
        home / ".config" / "mihomo",
        home / "Library" / "Application Support" / "clash",
        home / "Library" / "Application Support" / "mihomo",
    ):
        for ext in ("config.yaml", "config.yml"):
            paths.append(base / ext)
    return paths


def find_config() -> tuple[Path | None, str | None]:
    """Return (path, error_detail).

    When $CLASH_CONFIG is set we treat it as an explicit override — if the path
    does not exist we surface that as an error, never falling back to the
    common paths (picking up the wrong config and leaking credentials in
    preview output would be worse than surfacing the bad override).
    """
    env = os.environ.get("CLASH_CONFIG", "").strip()
    if env:
        p = Path(env).expanduser()
        try:
            if p.is_file():
                return p, None
        except OSError as e:
            return None, f"CLASH_CONFIG unreadable: {p} ({e})"
        return None, f"CLASH_CONFIG path not found: {p}"
    for p in _default_candidate_paths():
        try:
            if p.is_file():
                return p, None
        except OSError:
            continue
    return None, "Set CLASH_CONFIG or place under ~/.config/clash/"


def load_config(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return data if isinstance(data, dict) else {}


def _clean(value: object) -> str:
    """Return a TSV-safe representation of value (collapses tabs/newlines)."""
    s = "" if value is None else str(value)
    return s.replace("\t", " ").replace("\n", " ").replace("\r", " ")


def tsv(*cols: object) -> str:
    return "\t".join(_clean(c) for c in cols)


def _proxy_flags(p: dict) -> str:
    flags = []
    if p.get("tls"):
        flags.append("tls")
    if p.get("udp"):
        flags.append("udp")
    net = p.get("network")
    if isinstance(net, str) and net:
        flags.append(net)
    cipher = p.get("cipher")
    if isinstance(cipher, str) and cipher not in ("", "auto"):
        flags.append(cipher)
    return ",".join(flags) if flags else "-"


def cmd_proxies(cfg: dict) -> None:
    proxies = cfg.get("proxies") or []
    if not isinstance(proxies, list):
        return
    for p in proxies:
        if not isinstance(p, dict):
            continue
        name = p.get("name", "?")
        typ = p.get("type", "?")
        server = p.get("server", "-")
        port = p.get("port", "-")
        print(tsv("proxy", name, typ, f"{server}:{port}", _proxy_flags(p)))


def cmd_groups(cfg: dict) -> None:
    groups = cfg.get("proxy-groups") or []
    if not isinstance(groups, list):
        return
    for g in groups:
        if not isinstance(g, dict):
            continue
        name = g.get("name", "?")
        typ = g.get("type", "?")
        members = g.get("proxies") or []
        first = members[0] if members else "-"
        extra = f"{len(members)} members"
        print(tsv("group", name, typ, first, extra))


def cmd_rules(cfg: dict) -> None:
    rules = cfg.get("rules") or []
    if not isinstance(rules, list):
        return
    for idx, r in enumerate(rules, 1):
        if not isinstance(r, str):
            continue
        parts = [part.strip() for part in r.split(",")]
        kind = parts[0] if parts else "?"
        if kind == "MATCH":
            pattern = "-"
            target = parts[1] if len(parts) > 1 else "-"
            modifier = ""
        else:
            pattern = parts[1] if len(parts) > 1 else "-"
            target = parts[2] if len(parts) > 2 else "-"
            modifier = parts[3] if len(parts) > 3 else ""
        extra = f"{target} {modifier}".strip() if modifier else target
        print(tsv("rule", f"#{idx:04d}", kind, pattern, extra))


_SUMMARY_KEYS = (
    "port",
    "socks-port",
    "mixed-port",
    "redir-port",
    "tproxy-port",
    "allow-lan",
    "bind-address",
    "mode",
    "log-level",
    "ipv6",
    "external-controller",
    "external-ui",
    "secret",
    "interface-name",
    "routing-mark",
    "geodata-mode",
    "geox-url",
    "tun",
    "dns",
    "experimental",
)


def cmd_summary(cfg: dict) -> None:
    for key in _SUMMARY_KEYS:
        if key not in cfg:
            continue
        value = cfg[key]
        if isinstance(value, (dict, list)):
            rendered = yaml.safe_dump(value, default_flow_style=True, sort_keys=False)
            rendered = rendered.strip().rstrip("...").strip()
            if len(rendered) > 80:
                rendered = rendered[:77] + "..."
            type_tag = "dict" if isinstance(value, dict) else "list"
        else:
            rendered = str(value)
            type_tag = "scalar"
        print(tsv("config", key, type_tag, rendered, "-"))

    proxies = cfg.get("proxies") or []
    groups = cfg.get("proxy-groups") or []
    rules = cfg.get("rules") or []
    if isinstance(proxies, list):
        print(tsv("config", "proxies.count", "scalar", len(proxies), "-"))
    if isinstance(groups, list):
        print(tsv("config", "proxy-groups.count", "scalar", len(groups), "-"))
    if isinstance(rules, list):
        print(tsv("config", "rules.count", "scalar", len(rules), "-"))


def cmd_yaml(cfg: dict, kind: str, name: str) -> str:
    if kind == "proxy":
        for p in cfg.get("proxies") or []:
            if isinstance(p, dict) and p.get("name") == name:
                return yaml.safe_dump(p, sort_keys=False, allow_unicode=True)
    elif kind == "group":
        for g in cfg.get("proxy-groups") or []:
            if isinstance(g, dict) and g.get("name") == name:
                return yaml.safe_dump(g, sort_keys=False, allow_unicode=True)
    elif kind == "rule":
        rules = cfg.get("rules") or []
        try:
            idx = int(name.lstrip("#")) - 1
        except ValueError:
            idx = -1
        if 0 <= idx < len(rules):
            return f"{rules[idx]}\n"
    elif kind == "config":
        if name.endswith(".count"):
            base = name.rsplit(".", 1)[0]
            value = cfg.get(base) or []
            return f"# {name} = {len(value) if isinstance(value, list) else value}\n"
        if name in cfg:
            return yaml.safe_dump({name: cfg[name]}, sort_keys=False, allow_unicode=True)
    return f"# no entry found for kind={kind}, name={name}\n"


def cmd_server(cfg: dict, name: str) -> str:
    for p in cfg.get("proxies") or []:
        if isinstance(p, dict) and p.get("name") == name:
            server = p.get("server", "")
            port = p.get("port", "")
            return f"{server}:{port}" if server or port else ""
    return ""


def cmd_controller(cfg: dict) -> tuple[str, str]:
    host = os.environ.get("CLASH_CONTROLLER", "").strip() or (cfg.get("external-controller", "") or "")
    secret = os.environ.get("CLASH_SECRET", "").strip() or (cfg.get("secret", "") or "")
    return str(host), str(secret)


def cmd_groups_for_switch(cfg: dict) -> None:
    """Emit groups eligible for PUT /proxies/:name (select type only)."""
    for g in cfg.get("proxy-groups") or []:
        if not isinstance(g, dict):
            continue
        if g.get("type") not in ("select", "fallback", "url-test", "load-balance"):
            continue
        name = g.get("name", "?")
        typ = g.get("type", "?")
        members = g.get("proxies") or []
        print(tsv("group", name, typ, " | ".join(members)))


def _emit_placeholder(mode: str, reason: str, detail: str) -> None:
    if mode in {"proxies", "groups", "rules", "summary", "groups-for-switch"}:
        print(tsv("none", reason, "-", detail, "-"))
    elif mode in {"path", "server"}:
        print("")
    elif mode == "controller":
        print("")
        print("")
    else:
        print(f"# {reason}: {detail}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "mode",
        choices=[
            "proxies",
            "groups",
            "rules",
            "summary",
            "path",
            "yaml",
            "server",
            "controller",
            "groups-for-switch",
        ],
    )
    ap.add_argument("--kind", default="", help="kind for `yaml` mode")
    ap.add_argument("--name", default="", help="name for `yaml` / `server` mode")
    ap.add_argument("--config", default="", help="override config path")
    args = ap.parse_args()

    if args.config:
        path = Path(args.config).expanduser()
        if not path.is_file():
            _emit_placeholder(
                args.mode,
                "no-clash-config",
                f"--config path not found: {path}",
            )
            return 0
    else:
        found, err = find_config()
        if found is None:
            _emit_placeholder(args.mode, "no-clash-config", err or "no config found")
            return 0
        path = found

    if args.mode == "path":
        print(str(path))
        return 0

    try:
        cfg = load_config(path)
    except yaml.YAMLError as e:
        _emit_placeholder(args.mode, "invalid-yaml", str(e)[:120])
        return 0
    except OSError as e:
        _emit_placeholder(args.mode, "read-error", str(e)[:120])
        return 0

    if args.mode == "proxies":
        cmd_proxies(cfg)
    elif args.mode == "groups":
        cmd_groups(cfg)
    elif args.mode == "rules":
        cmd_rules(cfg)
    elif args.mode == "summary":
        cmd_summary(cfg)
    elif args.mode == "yaml":
        sys.stdout.write(cmd_yaml(cfg, args.kind, args.name))
    elif args.mode == "server":
        print(cmd_server(cfg, args.name))
    elif args.mode == "controller":
        host, secret = cmd_controller(cfg)
        print(host)
        print(secret)
    elif args.mode == "groups-for-switch":
        cmd_groups_for_switch(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
