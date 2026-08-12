#!/usr/bin/env python3
"""Focus an exact Herdr pane from a versioned route token or explicit IDs."""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
from collections import deque
from dataclasses import dataclass
from typing import Any, Sequence

DIRECTIONS = ("left", "right", "up", "down")
MAX_PANES = 128
MAX_ATTEMPTS = 2


class FocusError(RuntimeError):
    """A pane could not be focused safely."""


class TopologyRace(FocusError):
    """The pane layout changed while a focus path was being applied."""


@dataclass(frozen=True)
class Route:
    socket_path: str
    workspace_id: str
    tab_id: str
    pane_id: str
    session: str = ""
    source: str = ""
    line_number: int | None = None
    line: str = ""
    agent_status: str | None = None
    cwd: str | None = None


@dataclass(frozen=True)
class Layout:
    workspace_id: str
    tab_id: str
    focused_pane_id: str
    pane_ids: frozenset[str]
    fingerprint: str


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="focus-pane.py",
        description="Focus one exact Herdr pane through an authoritative session socket.",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--route-token", help="versioned URL-safe base64 route JSON")
    mode.add_argument(
        "--preview-route-token",
        help="render stored match metadata and the pane's current visible content",
    )
    mode.add_argument("--socket-path", help="authoritative Herdr session socket")
    parser.add_argument("--workspace-id")
    parser.add_argument("--tab-id")
    parser.add_argument("--pane-id")
    return parser


def required_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"route field '{field}' must be a non-empty string")
    if "\x00" in value:
        raise ValueError(f"route field '{field}' contains NUL")
    return value


def decode_route(token: str) -> Route:
    try:
        padding = "=" * (-len(token) % 4)
        raw = base64.urlsafe_b64decode((token + padding).encode("ascii"))
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeEncodeError, UnicodeDecodeError, ValueError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid route token: {exc}") from exc

    if (
        not isinstance(payload, dict)
        or type(payload.get("schema_version")) is not int
        or payload.get("schema_version") != 1
    ):
        raise ValueError("route token must contain integer schema_version 1")
    line_number = payload.get("line_number")
    if line_number is not None and (type(line_number) is not int or line_number < 1):
        raise ValueError("route field 'line_number' must be a positive integer or null")

    optional_strings: dict[str, str | None] = {}
    for field in ("session", "source", "line", "agent_status", "cwd"):
        value = payload.get(field)
        if value is not None and not isinstance(value, str):
            raise ValueError(f"route field '{field}' must be a string or null")
        optional_strings[field] = value

    return Route(
        socket_path=required_string(payload.get("socket_path"), "socket_path"),
        workspace_id=required_string(payload.get("workspace_id"), "workspace_id"),
        tab_id=required_string(payload.get("tab_id"), "tab_id"),
        pane_id=required_string(payload.get("pane_id"), "pane_id"),
        session=optional_strings["session"] or "",
        source=optional_strings["source"] or "",
        line_number=line_number,
        line=optional_strings["line"] or "",
        agent_status=optional_strings["agent_status"],
        cwd=optional_strings["cwd"],
    )


def route_from_args(args: argparse.Namespace) -> Route:
    if args.socket_path is None:
        token = args.route_token or args.preview_route_token
        assert token is not None
        return decode_route(token)
    missing = [
        name
        for name, value in (
            ("--workspace-id", args.workspace_id),
            ("--tab-id", args.tab_id),
            ("--pane-id", args.pane_id),
        )
        if not value
    ]
    if missing:
        raise ValueError(f"{', '.join(missing)} required with --socket-path")
    return Route(
        socket_path=required_string(args.socket_path, "socket_path"),
        workspace_id=required_string(args.workspace_id, "workspace_id"),
        tab_id=required_string(args.tab_id, "tab_id"),
        pane_id=required_string(args.pane_id, "pane_id"),
    )


def clean_message(raw: bytes, fallback: str) -> str:
    message = " ".join(raw.decode("utf-8", errors="replace").strip().splitlines())
    return message or fallback


class HerdrClient:
    def __init__(self, binary: str, socket_path: str) -> None:
        self.binary = binary
        self.env = os.environ.copy()
        self.env["HERDR_SOCKET_PATH"] = socket_path

    def run(self, *args: str) -> subprocess.CompletedProcess[bytes]:
        try:
            return subprocess.run(
                [self.binary, *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.env,
                check=False,
            )
        except (OSError, ValueError) as exc:
            raise FocusError(f"failed to execute herdr: {exc}") from exc

    def json(self, operation: str, *args: str) -> dict[str, Any]:
        result = self.run(*args)
        if result.returncode != 0:
            raise FocusError(
                f"{operation} failed: {clean_message(result.stderr or result.stdout, 'herdr failed')}"
            )
        try:
            payload = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise FocusError(f"{operation} returned invalid JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise FocusError(f"{operation} returned a non-object JSON value")
        return payload


def result_object(payload: dict[str, Any], key: str, operation: str) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise FocusError(f"{operation} returned a non-object JSON value")
    result = payload.get("result")
    value = result.get(key) if isinstance(result, dict) else None
    if not isinstance(value, dict):
        raise FocusError(f"{operation} response is missing result.{key}")
    return value


def validate_pane(client: HerdrClient, route: Route) -> None:
    pane = result_object(client.json("pane get", "pane", "get", route.pane_id), "pane", "pane get")
    actual = (
        pane.get("workspace_id"),
        pane.get("tab_id"),
        pane.get("pane_id"),
    )
    expected = (route.workspace_id, route.tab_id, route.pane_id)
    if actual != expected:
        raise FocusError(
            "pane route is stale: expected "
            f"{route.workspace_id}/{route.tab_id}/{route.pane_id}, got {actual[0]}/{actual[1]}/{actual[2]}"
        )


def normalize_rect(value: Any, field: str) -> dict[str, int]:
    if not isinstance(value, dict):
        raise FocusError(f"layout {field} must be an object")
    rect: dict[str, int] = {}
    for key in ("x", "y", "width", "height"):
        item = value.get(key)
        if not isinstance(item, int):
            raise FocusError(f"layout {field}.{key} must be an integer")
        rect[key] = item
    return rect


def parse_layout_value(value: Any, route: Route) -> Layout:
    if not isinstance(value, dict):
        raise FocusError("pane layout response is missing a layout object")
    workspace_id = value.get("workspace_id")
    tab_id = value.get("tab_id")
    focused = value.get("focused_pane_id")
    panes = value.get("panes")
    splits = value.get("splits")
    zoomed = value.get("zoomed")
    if workspace_id != route.workspace_id or tab_id != route.tab_id:
        raise FocusError("pane layout no longer matches the selected workspace/tab")
    if not isinstance(focused, str) or not focused:
        raise FocusError("pane layout has no focused_pane_id")
    if not isinstance(panes, list) or not panes or len(panes) > MAX_PANES:
        raise FocusError(f"pane layout must contain 1..{MAX_PANES} panes")
    if not isinstance(splits, list) or not isinstance(zoomed, bool):
        raise FocusError("pane layout has invalid splits or zoomed fields")

    normalized_panes: list[dict[str, Any]] = []
    pane_ids: set[str] = set()
    for index, pane in enumerate(panes):
        if not isinstance(pane, dict):
            raise FocusError(f"layout pane {index} must be an object")
        try:
            pane_id = required_string(pane.get("pane_id"), f"layout.panes[{index}].pane_id")
        except ValueError as exc:
            raise FocusError(str(exc)) from exc
        if pane_id in pane_ids:
            raise FocusError(f"pane layout contains duplicate pane '{pane_id}'")
        pane_ids.add(pane_id)
        normalized_panes.append(
            {"pane_id": pane_id, "rect": normalize_rect(pane.get("rect"), f"panes[{index}].rect")}
        )
    if route.pane_id not in pane_ids or focused not in pane_ids:
        raise FocusError("pane layout does not contain the target or focused pane")

    normalized_splits: list[dict[str, Any]] = []
    for index, split in enumerate(splits):
        if not isinstance(split, dict):
            raise FocusError(f"layout split {index} must be an object")
        direction = split.get("direction")
        split_id = split.get("id")
        ratio = split.get("ratio")
        if direction not in ("right", "down") or not isinstance(split_id, str):
            raise FocusError(f"layout split {index} has invalid direction or id")
        if not isinstance(ratio, (int, float)):
            raise FocusError(f"layout split {index} has invalid ratio")
        normalized_splits.append(
            {
                "direction": direction,
                "id": split_id,
                "ratio": ratio,
                "rect": normalize_rect(split.get("rect"), f"splits[{index}].rect"),
            }
        )

    topology = {
        "area": normalize_rect(value.get("area"), "area"),
        "panes": sorted(normalized_panes, key=lambda item: item["pane_id"]),
        "splits": sorted(normalized_splits, key=lambda item: item["id"]),
        "tab_id": tab_id,
        "workspace_id": workspace_id,
        "zoomed": zoomed,
    }
    return Layout(
        workspace_id=workspace_id,
        tab_id=tab_id,
        focused_pane_id=focused,
        pane_ids=frozenset(pane_ids),
        fingerprint=json.dumps(topology, sort_keys=True, separators=(",", ":")),
    )


def get_layout(client: HerdrClient, route: Route) -> Layout:
    payload = client.json("pane layout", "pane", "layout", "--pane", route.pane_id)
    return parse_layout_value(result_object(payload, "layout", "pane layout"), route)


def neighbor(
    client: HerdrClient,
    route: Route,
    layout: Layout,
    pane_id: str,
    direction: str,
) -> str | None:
    payload = client.json(
        "pane neighbor",
        "pane",
        "neighbor",
        "--pane",
        pane_id,
        "--direction",
        direction,
    )
    value = result_object(payload, "neighbor", "pane neighbor")
    if value.get("pane_id") != pane_id or value.get("direction") != direction:
        raise TopologyRace("pane neighbor response does not match the requested edge")
    observed_layout = parse_layout_value(value.get("layout"), route)
    if observed_layout.fingerprint != layout.fingerprint:
        raise TopologyRace("pane topology changed during path discovery")
    candidate = value.get("neighbor_pane_id")
    if candidate is None:
        return None
    if not isinstance(candidate, str) or candidate not in layout.pane_ids:
        raise TopologyRace("pane neighbor points outside the current layout")
    if candidate == pane_id:
        return None
    return candidate


def shortest_path(
    client: HerdrClient,
    route: Route,
    layout: Layout,
) -> list[tuple[str, str, str]]:
    start = layout.focused_pane_id
    if start == route.pane_id:
        return []
    queue: deque[str] = deque([start])
    previous: dict[str, tuple[str, str] | None] = {start: None}

    while queue:
        node = queue.popleft()
        for direction in DIRECTIONS:
            candidate = neighbor(client, route, layout, node, direction)
            if candidate is None or candidate in previous:
                continue
            previous[candidate] = (node, direction)
            if candidate == route.pane_id:
                queue.clear()
                break
            queue.append(candidate)

    if route.pane_id not in previous:
        raise FocusError("target pane is unreachable from the tab's focused pane")

    reversed_edges: list[tuple[str, str, str]] = []
    current = route.pane_id
    while current != start:
        edge = previous[current]
        assert edge is not None
        origin, direction = edge
        reversed_edges.append((origin, direction, current))
        current = origin
    return list(reversed(reversed_edges))


def verify_current(client: HerdrClient, route: Route) -> None:
    # `pane current` identifies the calling pane, not the server's newly focused
    # pane. Verify global workspace/tab focus plus the tab-local focused pane.
    workspace = result_object(
        client.json("workspace get", "workspace", "get", route.workspace_id),
        "workspace",
        "workspace get",
    )
    if workspace.get("focused") is not True or workspace.get("active_tab_id") != route.tab_id:
        raise FocusError("final focus verification failed: target workspace/tab is not active")
    tab = result_object(
        client.json("tab get", "tab", "get", route.tab_id),
        "tab",
        "tab get",
    )
    if tab.get("focused") is not True:
        raise FocusError("final focus verification failed: target tab is not active")
    layout = get_layout(client, route)
    if layout.focused_pane_id != route.pane_id:
        raise FocusError(
            "final focus verification failed: expected "
            f"{route.pane_id}, got {layout.focused_pane_id}"
        )


def try_agent_focus(client: HerdrClient, route: Route) -> bool:
    result = client.run("agent", "get", route.pane_id)
    if result.returncode == 0:
        try:
            payload = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise FocusError(f"agent get returned invalid JSON: {exc}") from exc
        agent = result_object(payload, "agent", "agent get")
        if agent.get("pane_id") != route.pane_id:
            raise FocusError("agent get returned a different pane")
        client.json("agent focus", "agent", "focus", route.pane_id)
        verify_current(client, route)
        return True

    raw_error = result.stdout or result.stderr
    try:
        payload = json.loads(raw_error.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = None
    error = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(error, dict) and error.get("code") == "agent_not_found":
        return False
    raise FocusError(f"agent get failed: {clean_message(result.stderr or result.stdout, 'herdr failed')}")


def focus_ordinary(client: HerdrClient, route: Route) -> None:
    get_layout(client, route)  # preflight before changing focus
    client.json("workspace focus", "workspace", "focus", route.workspace_id)
    client.json("tab focus", "tab", "focus", route.tab_id)

    last_race: TopologyRace | None = None
    for attempt in range(MAX_ATTEMPTS):
        layout = get_layout(client, route)
        if layout.focused_pane_id == route.pane_id:
            verify_current(client, route)
            return
        try:
            path = shortest_path(client, route, layout)
            current_layout = layout
            for origin, direction, expected in path:
                actual = neighbor(client, route, current_layout, origin, direction)
                if actual != expected:
                    raise TopologyRace("planned pane neighbor changed before focus")
                client.json(
                    "pane focus",
                    "pane",
                    "focus",
                    "--direction",
                    direction,
                    "--pane",
                    origin,
                )
                current_layout = get_layout(client, route)
                if current_layout.fingerprint != layout.fingerprint:
                    raise TopologyRace("pane topology changed while applying focus path")
                if current_layout.focused_pane_id != expected:
                    raise TopologyRace("pane focus landed on an unexpected pane")
            verify_current(client, route)
            return
        except TopologyRace as exc:
            last_race = exc
            if attempt + 1 >= MAX_ATTEMPTS:
                break
    assert last_race is not None
    raise FocusError(f"pane layout kept changing after one replan: {last_race}")


def focus_route(client: HerdrClient, route: Route) -> None:
    validate_pane(client, route)
    if try_agent_focus(client, route):
        return
    focus_ordinary(client, route)


def preview_route(client: HerdrClient, route: Route) -> None:
    coordinate = "/".join(
        part for part in (route.session, route.workspace_id, route.tab_id, route.pane_id) if part
    )
    metadata = [f"pane={coordinate}"]
    if route.source:
        metadata.append(f"source={route.source}")
    if route.line_number is not None:
        metadata.append(f"capture-line={route.line_number}")
    if route.agent_status:
        metadata.append(f"status={route.agent_status}")
    if route.cwd:
        metadata.append(f"cwd={route.cwd}")
    print("  ".join(metadata))
    if route.line:
        print(f"match: {route.line}")
    print("\n── current visible pane ──")

    result = client.run("pane", "read", route.pane_id, "--source", "visible", "--format", "text")
    if result.returncode != 0:
        print(f"[pane unavailable: {clean_message(result.stderr or result.stdout, 'herdr failed')}]")
        return
    sys.stdout.write(result.stdout.decode("utf-8", errors="replace"))
    if result.stdout and not result.stdout.endswith(b"\n"):
        print()


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        route = route_from_args(args)
    except ValueError as exc:
        parser.error(str(exc))

    herdr = shutil.which("herdr")
    if herdr is None:
        print("focus-pane: herdr not found on PATH", file=sys.stderr)
        return 1
    client = HerdrClient(herdr, route.socket_path)

    if args.preview_route_token is not None:
        try:
            preview_route(client, route)
        except FocusError as exc:
            print(f"focus-pane: preview failed: {exc}")
        return 0

    try:
        focus_route(client, route)
    except FocusError as exc:
        print(f"focus-pane: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
