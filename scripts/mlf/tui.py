"""mlf TUI — interactive Textual dashboard for MLflow.

Tree of experiments/runs/models on the left; tabbed detail view on the
right (Overview, Params, Metrics, Plot, Artifacts, Tags). One-key
dispatch to browser/clipboard/plot/download. Reuses helpers from
`scripts.mlf` (`open_id`, `copy_id`, `fetch_histories`, list-row builders)
so behavior is identical to the CLI subcommands.

See `dot_dotfiles/bin/executable_mlf` for the umbrella entry point.
"""
from __future__ import annotations

import json as _json
import os
import subprocess
from collections import defaultdict
from typing import Any, Optional

from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    Log,
    SelectionList,
    Static,
    TabbedContent,
    TabPane,
    Tree,
)

from scripts.mlf import (
    copy_id,
    fetch_histories,
    make_client,
    ms_to_iso,
    open_id,
    tracking_uri,
    tracking_uri_is_http,
)
from scripts.mlf.list import STATUS_ICON, Row, _models


class VimTree(Tree):
    """`Tree` with vim-style hjkl/g/G bindings on top of the defaults.

    Bindings layer ON TOP of Textual's built-ins (arrow keys, home/end,
    page-up/down) — vim users get j/k/h/l/g/G; everyone else's habits
    keep working.

    Mapping (matches what `tree`-like nvim/lf/yazi UIs use):
      j / k      cursor down / up
      h          go to parent (or collapse current if expanded — Textual's
                 `cursor_parent` handles "move to parent" semantically)
      l          toggle expand/collapse on the current node
      g          jump to first visible node
      G          jump to last visible node
    """

    BINDINGS = [
        Binding("j", "cursor_down", "Down", show=False),
        Binding("k", "cursor_up", "Up", show=False),
        Binding("h", "cursor_parent", "Up-level", show=False),
        Binding("l", "toggle_node", "Expand", show=False),
        Binding("g", "goto_top", "Top", show=False),
        Binding("G", "goto_bottom", "Bottom", show=False),
    ]

    def action_goto_top(self) -> None:
        self.cursor_line = 0
        # Mirror what Tree does on cursor moves so the viewport scrolls.
        self.scroll_to_line(0)

    def action_goto_bottom(self) -> None:
        # Tree.last_line is the highest valid cursor_line; falls back to a
        # large value if the property name varies across Textual versions
        # — the setter clamps.
        try:
            self.cursor_line = self.last_line  # type: ignore[attr-defined]
        except AttributeError:
            self.cursor_line = 10**9
        self.scroll_to_line(self.cursor_line)


def _backend_kind(uri: str) -> str:
    if uri.startswith("sqlite:"):
        return "sqlite"
    if uri.startswith(("http://", "https://")):
        return "http"
    if uri.startswith(("postgresql:", "mysql:")):
        return uri.split(":", 1)[0]
    return "file"


def _duration(start_ms: Any, end_ms: Any) -> str:
    if not start_ms or not end_ms or int(end_ms) <= int(start_ms):
        return "-"
    secs = (int(end_ms) - int(start_ms)) // 1000
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


class PlotDialog(ModalScreen[Optional[list[str]]]):
    """Multi-select which metrics to chart; returns the selected keys.

    Filter input narrows the visible list as the user types. Selections
    persist across filter changes (tracked in `self._selected` on the
    dialog, not just in the SelectionList widget), so you can search
    "corr", select both train_corr & valid_corr, search "loss", select
    that, then Apply with all three.
    """

    BINDINGS = [
        Binding("escape", "dismiss_none", "Cancel"),
        # SelectionList consumes Enter to toggle the highlighted item.
        # priority=True for Ctrl+A so it still fires when focus is on the
        # filter input (which by default maps Ctrl+A to "cursor home").
        Binding("ctrl+a", "apply", "Apply", priority=True),
        Binding("ctrl+l", "select_all", "All"),
        Binding("ctrl+n", "select_none", "None"),
    ]

    DEFAULT_CSS = """
    PlotDialog {
        align: center middle;
    }
    PlotDialog > Vertical {
        width: 70%;
        max-width: 100;
        height: 80%;
        max-height: 40;
        border: tall $accent;
        background: $surface;
        padding: 1 2;
    }
    PlotDialog #plot-filter { height: 3; margin: 1 0 0 0; }
    PlotDialog SelectionList { height: 1fr; margin: 1 0; }
    PlotDialog #plot-buttons {
        height: 3;
        align: center middle;
    }
    """

    def __init__(self, keys: list[str]) -> None:
        super().__init__()
        self._all_keys: list[str] = sorted(keys)
        # Source of truth for selection state — survives filter rebuilds.
        # Default: NOTHING pre-selected. MLflow runs commonly log metrics
        # at vastly different scales (loss=0.1 next to disk_usage=5e5);
        # auto-selecting "all non-system.*" produced charts where every
        # training metric was a flat line at the bottom.
        self._selected: set[str] = set()
        self._filter: str = ""

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(
                "Select metrics to plot — type to filter, "
                "[bold]Ctrl+L[/bold]=all  [bold]Ctrl+N[/bold]=none  "
                "[bold]Ctrl+A[/bold]=apply  Esc=cancel:"
            )
            yield Input(placeholder="filter metric names…", id="plot-filter")
            yield SelectionList[str](*self._sel_items(), id="plot-selection")
            with Horizontal(id="plot-buttons"):
                yield Button("Select All", id="select-all")
                yield Button("Clear", id="clear-all")
                yield Button("Apply", id="apply", variant="primary")
                yield Button("Cancel", id="cancel")

    def on_mount(self) -> None:
        # SelectionList focused by default so Ctrl+L / Ctrl+N work immediately;
        # user clicks or Tab-keys into the filter input when they want to narrow.
        self.query_one(SelectionList).focus()

    # ---------- helpers ----------

    def _visible_keys(self) -> list[str]:
        f = self._filter.lower()
        return [k for k in self._all_keys if not f or f in k.lower()]

    def _sel_items(self) -> list[tuple[str, str, bool]]:
        return [(k, k, k in self._selected) for k in self._visible_keys()]

    def _rebuild_list(self) -> None:
        sl = self.query_one(SelectionList)
        sl.clear_options()
        for tup in self._sel_items():
            sl.add_option(tup)

    # ---------- event handlers ----------

    @on(Input.Changed, "#plot-filter")
    def _on_filter(self, event: Input.Changed) -> None:
        self._filter = event.value
        self._rebuild_list()

    @on(SelectionList.SelectedChanged)
    def _on_selection_changed(self) -> None:
        # Sync visible toggles into the persistent set. Items outside the
        # current filter are left untouched so prior selections survive.
        sl = self.query_one(SelectionList)
        visible = set(self._visible_keys())
        sel_in_view = set(sl.selected)
        for k in visible:
            if k in sel_in_view:
                self._selected.add(k)
            else:
                self._selected.discard(k)

    # ---------- actions ----------

    def action_dismiss_none(self) -> None:
        self.dismiss(None)

    def action_apply(self) -> None:
        self._apply()

    def action_select_all(self) -> None:
        # "All" means all VISIBLE items (filter-scoped). Combined with
        # filter-narrow + select-all, this gives "select every metric
        # matching <substring>" as a single workflow.
        sl = self.query_one(SelectionList)
        sl.select_all()
        for k in self._visible_keys():
            self._selected.add(k)

    def action_select_none(self) -> None:
        sl = self.query_one(SelectionList)
        sl.deselect_all()
        for k in self._visible_keys():
            self._selected.discard(k)

    @on(Button.Pressed, "#apply")
    def _apply(self) -> None:
        # Sync once more just in case a toggle event hasn't propagated yet.
        self._on_selection_changed()
        self.dismiss(sorted(self._selected) if self._selected else None)

    @on(Button.Pressed, "#cancel")
    def _cancel(self) -> None:
        self.dismiss(None)

    @on(Button.Pressed, "#select-all")
    def _select_all_btn(self) -> None:
        self.action_select_all()

    @on(Button.Pressed, "#clear-all")
    def _clear_all_btn(self) -> None:
        self.action_select_none()


class DownloadDialog(ModalScreen[None]):
    """Spawn `mlf download` subprocess; stream output to a Log widget."""

    BINDINGS = [
        Binding("escape", "close", "Close"),
    ]

    DEFAULT_CSS = """
    DownloadDialog {
        align: center middle;
    }
    DownloadDialog > Vertical {
        width: 80%;
        max-width: 100;
        height: 80%;
        max-height: 32;
        border: tall $accent;
        background: $surface;
        padding: 1 2;
    }
    DownloadDialog Input { margin-bottom: 1; }
    DownloadDialog Log { height: 1fr; margin-top: 1; }
    DownloadDialog #dl-buttons { height: 3; align: center middle; }
    """

    def __init__(self, model_name: str) -> None:
        super().__init__()
        self.model_name = model_name
        self._proc: Optional[subprocess.Popen] = None

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(f"Download model: [bold]{self.model_name}[/bold]")
            yield Label("Version or alias (e.g. 1, latest, Champion):")
            yield Input(value="latest", id="dl-version")
            yield Label("Destination directory:")
            yield Input(value=f"./{self.model_name}-latest", id="dl-dest")
            with Horizontal(id="dl-buttons"):
                yield Button("Start", id="dl-start", variant="primary")
                yield Button("Close", id="dl-close")
            yield Log(id="dl-log", highlight=False, max_lines=2000)

    @on(Button.Pressed, "#dl-start")
    def _start(self) -> None:
        version = (self.query_one("#dl-version", Input).value or "latest").strip()
        dest = (
            self.query_one("#dl-dest", Input).value
            or f"./{self.model_name}-{version}"
        )
        log = self.query_one(Log)
        log.write_line(f"$ mlf download {self.model_name}@{version} --dest {dest}")
        self._spawn(version, dest)

    @work(thread=True, exclusive=True)
    def _spawn(self, version: str, dest: str) -> None:
        log = self.query_one(Log)
        try:
            proc = subprocess.Popen(
                ["mlf", "download", f"{self.model_name}@{version}", "--dest", dest],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError:
            self.app.call_from_thread(log.write_line, "Error: `mlf` not on PATH")
            return
        self._proc = proc
        assert proc.stdout is not None
        for line in proc.stdout:
            self.app.call_from_thread(log.write_line, line.rstrip())
        rc = proc.wait()
        self.app.call_from_thread(log.write_line, f"[exit {rc}]")

    @on(Button.Pressed, "#dl-close")
    def _close_btn(self) -> None:
        self.action_close()

    def action_close(self) -> None:
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
        self.dismiss(None)


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return max(1, int(raw))
    except ValueError:
        return default


class MLflowApp(App):
    """mlf interactive dashboard — `mlf` (no args) entry point."""

    CSS = """
    Screen { layout: vertical; }
    #main { height: 1fr; }
    #src-tree { width: 38%; border-right: solid $accent; }
    TabbedContent { width: 1fr; }
    #filter-input {
        dock: top;
        height: 3;
        border: tall $accent;
    }
    #status-bar {
        dock: bottom;
        height: 1;
        background: $primary-background;
        color: $text;
        padding: 0 1;
    }
    DataTable { height: 1fr; }
    #plot-static { padding: 1; }
    """

    # Tunable list-fetch caps; raise via env on hosts with many runs/models.
    EXP_LIMIT = _env_int("MLF_EXP_LIMIT", 500)
    RUNS_LIMIT = _env_int("MLF_RUNS_LIMIT", 200)
    MODEL_LIMIT = _env_int("MLF_MODEL_LIMIT", 500)

    BINDINGS = [
        # `q` is non-priority so the user can type "q…" into the filter input
        # without quitting the app mid-keystroke.
        Binding("q", "quit", "Quit"),
        Binding("escape", "escape", "Esc", show=False),
        Binding("slash", "focus_filter", "Filter"),
        Binding("r", "refresh", "Refresh"),
        Binding("b", "open_browser", "Browser"),
        Binding("y", "copy_selection", "Copy"),
        Binding("p", "show_plot", "Plot"),
        Binding("d", "show_download", "Download"),
        Binding("j", "dump_json", "JSON"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._client = None
        self._selection: Optional[tuple[str, str, str]] = None  # (kind, id, name)
        self._selection_data: Optional[Any] = None  # cached Run/Experiment/Model
        # Raw mlflow entities — we need `experiment_id` (on Run.info) and the
        # `mlflow.parentRunId` tag for the hierarchical tree build, which
        # the flat `Row` dataclass doesn't expose. Raw objects also let us
        # avoid double-fetching when an experiment is expanded.
        self._raw_exps: list = []
        self._raw_runs: list = []
        self._models_rows: list[Row] = []
        # Last successfully-plotted metric keys; reused when the user switches
        # to a different run that logs (a subset of) the same metrics, so they
        # don't have to re-open PlotDialog for every comparable run.
        self._last_plot_keys: Optional[list[str]] = None

    @property
    def client(self):
        if self._client is None:
            self._client = make_client()
        return self._client

    def compose(self) -> ComposeResult:
        uri = tracking_uri()
        backend = _backend_kind(uri)
        # The Header() widget reads `App.title` and `App.sub_title`. Set them
        # before the widget is mounted so the first render is correct.
        self.title = "MLflow"
        self.sub_title = f"{uri}  (mode: {backend})"
        yield Header(show_clock=False)
        yield Input(
            placeholder="filter… (substring match across name + id, Esc to clear)",
            id="filter-input",
        )
        with Horizontal(id="main"):
            tree: VimTree = VimTree("Sources", id="src-tree")
            tree.show_root = False
            tree.show_guides = True
            yield tree
            with TabbedContent(id="tabs"):
                with TabPane("Overview", id="tab-overview"):
                    yield DataTable(id="dt-overview", show_header=False, cursor_type="row")
                with TabPane("Params", id="tab-params"):
                    yield DataTable(id="dt-params", cursor_type="row")
                with TabPane("Metrics", id="tab-metrics"):
                    yield DataTable(id="dt-metrics", cursor_type="row")
                with TabPane("Plot", id="tab-plot"):
                    yield VerticalScroll(
                        Static(
                            "Select a run and press [bold]p[/bold] to plot metrics.",
                            id="plot-static",
                        )
                    )
                with TabPane("Artifacts", id="tab-artifacts"):
                    art = Tree("(no run selected)", id="art-tree")
                    art.show_root = True
                    yield art
                with TabPane("Tags", id="tab-tags"):
                    yield DataTable(id="dt-tags", cursor_type="row")
        yield Static(f"{uri} │ - │ idle", id="status-bar")
        yield Footer()

    def on_mount(self) -> None:
        for tbl_id, cols in [
            ("dt-overview", ("field", "value")),
            ("dt-params", ("key", "value")),
            ("dt-metrics", ("key", "last", "min", "max", "n")),
            ("dt-tags", ("key", "value")),
        ]:
            t = self.query_one(f"#{tbl_id}", DataTable)
            t.add_columns(*cols)
            t.zebra_stripes = True
        # Filter input is hidden until `/` reveals it. Toggling .display
        # works more reliably than juggling a CSS class — `remove_class`
        # in headless tests sometimes doesn't re-trigger layout.
        self.query_one("#filter-input", Input).display = False
        self._populate_tree()

    # ---------- Tree population ----------

    @work(thread=True, exclusive=True, group="tree")
    def _populate_tree(self) -> None:
        self.call_from_thread(self._set_status, "loading tree…")
        try:
            raw_exps = list(
                self.client.search_experiments(max_results=self.EXP_LIMIT)
            )
            exp_ids = [e.experiment_id for e in raw_exps]
            if exp_ids:
                raw_runs = list(
                    self.client.search_runs(
                        experiment_ids=exp_ids,
                        max_results=self.RUNS_LIMIT,
                        order_by=["attributes.start_time DESC"],
                    )
                )
            else:
                raw_runs = []
            # `_models` already handles the file-backend "no registry"
            # friendly fallback; keep its Row output (we don't need
            # raw RegisteredModel for tree structure — models are flat).
            models = _models(self.client, self.MODEL_LIMIT)
        except Exception as e:  # noqa: BLE001
            self.call_from_thread(self._show_connection_error, repr(e))
            return

        self._raw_exps = raw_exps
        self._raw_runs = raw_runs
        self._models_rows = models

        self.call_from_thread(self._rebuild_tree)
        self.call_from_thread(
            self._set_status,
            f"loaded {len(raw_exps)} exp / {len(raw_runs)} runs / {len(models)} models",
        )

    # --- raw-mlflow → Row converters (Row is the tree-node data payload that
    # `_on_tree_select` / `_fetch_detail` already know how to dispatch on).

    @staticmethod
    def _exp_row(e) -> Row:
        return Row(
            id=str(e.experiment_id),
            kind="experiment",
            name=e.name or "(unnamed)",
            status="-",
            lifecycle=e.lifecycle_stage or "-",
            extra=e.artifact_location or "",
            last_update=ms_to_iso(e.last_update_time),
        )

    @staticmethod
    def _run_row(r) -> Row:
        info = r.info
        return Row(
            id=info.run_id,
            kind="run",
            name=info.run_name or info.run_id[:8],
            status=STATUS_ICON.get(info.status, info.status or "?"),
            lifecycle=info.lifecycle_stage or "-",
            extra=info.experiment_id,
            last_update=ms_to_iso(info.start_time),
        )

    def _rebuild_tree(self) -> None:
        """Rebuild the hierarchical tree from raw caches, with filter applied.

        Layout:
          ▾ Experiments (N)
            ▾ <exp_id>  <exp_name>  (k runs)
                <root_run>            (no mlflow.parentRunId)
                ▾ <parent_run>        (has nested children in the loaded set)
                    <child_run>
                    <child_run>
                <root_run>
          ▸ Models (M)

        Filter is applied substring-style across name + id of each entity.
        An experiment is shown if it matches OR if it contains any matching
        run (so a run-only filter still surfaces the parent experiment as
        context). Run children inherit visibility — i.e. once a top-level
        run is included we attach all of its loaded descendants regardless
        of the filter, because the user's mental model is "show me this run
        and its tree".
        """
        tree = self.query_one("#src-tree", Tree)
        try:
            filter_text = self.query_one("#filter-input", Input).value
        except Exception:  # noqa: BLE001
            filter_text = ""
        f = filter_text.lower().strip()

        def run_matches(r) -> bool:
            if not f:
                return True
            name = r.info.run_name or ""
            return f in name.lower() or f in r.info.run_id.lower()

        def exp_matches(e) -> bool:
            if not f:
                return True
            return f in (e.name or "").lower() or f in str(e.experiment_id).lower()

        def model_matches(row) -> bool:
            if not f:
                return True
            return f in (row.name or "").lower() or f in (row.id or "").lower()

        # Index runs by experiment_id and by parent_run_id for tree assembly.
        runs_by_exp: dict[str, list] = defaultdict(list)
        children_by_parent: dict[Optional[str], list] = defaultdict(list)
        for r in self._raw_runs:
            runs_by_exp[r.info.experiment_id].append(r)
            parent_id = (r.data.tags or {}).get("mlflow.parentRunId")
            children_by_parent[parent_id].append(r)

        # Visibility per experiment: keep if exp matches OR any of its runs match.
        # When filtering, we must also know which RUN IDs survive — descendants
        # of a kept run come along for free.
        kept_run_ids: set[str] = set()
        if f:
            for r in self._raw_runs:
                if run_matches(r):
                    kept_run_ids.add(r.info.run_id)
            # Promote ancestors of matched runs so the chain is visible.
            id_to_run = {r.info.run_id: r for r in self._raw_runs}
            for rid in list(kept_run_ids):
                cur = id_to_run.get(rid)
                while cur is not None:
                    parent_id = (cur.data.tags or {}).get("mlflow.parentRunId")
                    if not parent_id or parent_id in kept_run_ids:
                        break
                    kept_run_ids.add(parent_id)
                    cur = id_to_run.get(parent_id)
        else:
            kept_run_ids = {r.info.run_id for r in self._raw_runs}

        visible_exps = [
            e for e in self._raw_exps
            if exp_matches(e) or any(
                r.info.run_id in kept_run_ids
                for r in runs_by_exp.get(e.experiment_id, [])
            )
        ]
        visible_models = [m for m in self._models_rows if model_matches(m)]

        tree.root.remove_children()
        # On active filter expand aggressively; otherwise the top-level
        # branches are collapsed by default to keep the initial view scannable.
        expand_top = True  # always show Experiments / Models headers expanded
        deep_expand = bool(f)

        exp_top = tree.root.add(
            f"Experiments ({len(visible_exps)})", expand=expand_top
        )
        for e in visible_exps:
            exp_id = e.experiment_id
            exp_runs = [
                r for r in runs_by_exp.get(exp_id, [])
                if r.info.run_id in kept_run_ids
            ]
            # Top-level runs within this experiment: those whose parent is
            # either absent, or not part of this experiment's loaded set
            # (orphans get promoted to top so they don't go missing).
            own_run_ids = {r.info.run_id for r in exp_runs}
            top_runs = [
                r for r in exp_runs
                if (r.data.tags or {}).get("mlflow.parentRunId") not in own_run_ids
            ]
            top_runs.sort(key=lambda r: r.info.start_time or 0, reverse=True)

            label = f"{exp_id}  {e.name or '(unnamed)'}  ({len(exp_runs)} runs)"
            exp_row = self._exp_row(e)
            if exp_runs:
                exp_node = exp_top.add(label, data=exp_row, expand=deep_expand)
                self._add_runs_recursive(
                    exp_node, top_runs, children_by_parent, own_run_ids, deep_expand
                )
            else:
                exp_top.add_leaf(label + "  (no recent runs)", data=exp_row)

        model_top = tree.root.add(
            f"Models ({len(visible_models)})", expand=deep_expand
        )
        if not visible_models and not f and not self._models_rows:
            model_top.add_leaf("(empty — file/sqlite backend?)", data=None)
        for r in visible_models:
            model_top.add_leaf(r.name, data=r)

    def _add_runs_recursive(
        self,
        parent_node,
        runs: list,
        children_by_parent: dict,
        own_run_ids: set,
        expand: bool,
    ) -> None:
        """Attach `runs` under `parent_node`; recurse for any with children."""
        for r in runs:
            row = self._run_row(r)
            label = f"{row.name}  {row.status}"
            kids = [
                c for c in children_by_parent.get(r.info.run_id, [])
                if c.info.run_id in own_run_ids
            ]
            if kids:
                kids.sort(key=lambda x: x.info.start_time or 0, reverse=True)
                node = parent_node.add(label, data=row, expand=expand)
                self._add_runs_recursive(
                    node, kids, children_by_parent, own_run_ids, expand
                )
            else:
                parent_node.add_leaf(label, data=row)

    def _show_connection_error(self, msg: str) -> None:
        tree = self.query_one("#src-tree", Tree)
        tree.root.remove_children()
        err = tree.root.add("[bold red]Connection failed[/bold red]", expand=True)
        err.add_leaf(f"URI: {tracking_uri()}")
        err.add_leaf(msg[:140])
        err.add_leaf("Press [r] to retry, [q] to quit.")
        self._set_status(f"error: {msg[:60]}")

    # ---------- Tree selection ----------

    @on(Tree.NodeSelected, "#src-tree")
    def _on_tree_select(self, event: Tree.NodeSelected) -> None:
        row = event.node.data
        if row is None or not isinstance(row, Row):
            return
        self._selection = (row.kind, row.id, row.name or row.id)
        self._set_status(f"loading {row.kind}…")
        self._fetch_detail(row.kind, row.id)

    @work(thread=True, exclusive=True, group="detail")
    def _fetch_detail(self, kind: str, ident: str) -> None:
        try:
            if kind == "run":
                data = self.client.get_run(ident)
            elif kind == "experiment":
                data = self.client.get_experiment(ident)
            elif kind == "model":
                data = self.client.get_registered_model(ident)
            else:
                return
        except Exception as e:  # noqa: BLE001
            self.call_from_thread(self._set_status, f"error: {str(e)[:80]}")
            return
        self._selection_data = data
        self.call_from_thread(self._render_detail)

    def _render_detail(self) -> None:
        if not self._selection or self._selection_data is None:
            return
        kind, ident, _ = self._selection
        if kind == "run":
            self._render_run(self._selection_data)
        elif kind == "experiment":
            self._render_experiment(self._selection_data)
        elif kind == "model":
            self._render_model(self._selection_data)
        self._set_status("idle")

    def _render_run(self, run) -> None:
        info, data = run.info, run.data
        t = self.query_one("#dt-overview", DataTable)
        t.clear()
        rows = [
            ("run_name", info.run_name or info.run_id[:8]),
            ("run_id", info.run_id),
            ("status", STATUS_ICON.get(info.status, info.status or "?")),
            ("experiment_id", info.experiment_id),
            ("user_id", info.user_id or "-"),
            ("start_time", ms_to_iso(info.start_time)),
            ("end_time", ms_to_iso(info.end_time)),
            ("duration", _duration(info.start_time, info.end_time)),
            ("artifact_uri", info.artifact_uri or "-"),
        ]
        for k, v in rows:
            t.add_row(k, str(v))

        t = self.query_one("#dt-params", DataTable)
        t.clear()
        for k in sorted((data.params or {}).keys()):
            t.add_row(k, str(data.params[k]))

        # Metrics: latest values only (full history fetched on Plot dialog).
        t = self.query_one("#dt-metrics", DataTable)
        t.clear()
        for k in sorted((data.metrics or {}).keys()):
            v = data.metrics[k]
            t.add_row(k, f"{v:.4g}", "—", "—", "—")

        t = self.query_one("#dt-tags", DataTable)
        t.clear()
        for k in sorted((data.tags or {}).keys()):
            if k.startswith("mlflow."):
                continue
            t.add_row(k, str(data.tags[k]))

        # Artifacts: lazy-loaded; reset hint until user activates the tab.
        art = self.query_one("#art-tree", Tree)
        art.reset(f"artifacts of {info.run_id[:8]} — Enter to expand")
        art.root.expand()
        art.root.data = ("run-root", info.run_id, "")  # marker for lazy fetch

        # Auto-replay: if a previous run-selection produced a plot, and the
        # new run logs at least one of those same metric keys, re-render with
        # the intersection. Comparing the same loss/accuracy curves across
        # runs is the canonical workflow — making the user re-open PlotDialog
        # for every run breaks the flow. We re-render only on overlap so an
        # unrelated run doesn't get an empty / misleading chart.
        avail = set(data.metrics or {})
        if self._last_plot_keys:
            replay = [k for k in self._last_plot_keys if k in avail]
        else:
            replay = []
        if replay:
            self._set_status(
                f"auto-replay plot ({len(replay)}/{len(self._last_plot_keys or [])} keys)…"
            )
            self._render_plot(info.run_id, replay)
        else:
            self.query_one("#plot-static", Static).update(
                "Press [bold]p[/bold] to plot metric history."
            )

    def _render_experiment(self, exp) -> None:
        t = self.query_one("#dt-overview", DataTable)
        t.clear()
        for k, v in [
            ("experiment_id", exp.experiment_id),
            ("name", exp.name or "(unnamed)"),
            ("lifecycle_stage", exp.lifecycle_stage or "-"),
            ("artifact_location", exp.artifact_location or "-"),
            ("creation_time", ms_to_iso(getattr(exp, "creation_time", None))),
            ("last_update", ms_to_iso(exp.last_update_time)),
        ]:
            t.add_row(k, str(v))
        for tid in ("dt-params", "dt-metrics", "dt-tags"):
            self.query_one(f"#{tid}", DataTable).clear()
        self.query_one("#plot-static", Static).update("(plot is run-only)")
        art = self.query_one("#art-tree", Tree)
        art.reset("(plot/artifacts are run-only)")

    def _render_model(self, model) -> None:
        t = self.query_one("#dt-overview", DataTable)
        t.clear()
        latest = model.latest_versions or []
        for k, v in [
            ("name", model.name),
            (
                "description",
                (model.description or "").splitlines()[0]
                if model.description
                else "-",
            ),
            ("creation_time", ms_to_iso(model.creation_timestamp)),
            ("last_update", ms_to_iso(model.last_updated_timestamp)),
            (
                "latest_versions",
                ", ".join(f"v{v.version}({v.current_stage})" for v in latest) or "-",
            ),
        ]:
            t.add_row(k, str(v))
        for tid in ("dt-params", "dt-metrics", "dt-tags"):
            self.query_one(f"#{tid}", DataTable).clear()
        self.query_one("#plot-static", Static).update("(plot is run-only)")
        art = self.query_one("#art-tree", Tree)
        art.reset("(artifacts are run-only)")

    # ---------- Artifact tree lazy-load ----------

    @on(Tree.NodeExpanded, "#art-tree")
    def _on_artifact_expand(self, event: Tree.NodeExpanded) -> None:
        node = event.node
        # Only fetch if we haven't loaded children yet AND this is a known
        # artifact-tree node (marked via .data tuple of (kind, run_id, path)).
        if not isinstance(node.data, tuple) or len(node.data) != 3:
            return
        if node.children:
            return  # already loaded
        _, run_id, path = node.data
        self._fetch_artifacts(node.id, run_id, path)

    @work(thread=True, exclusive=False, group="artifact")
    def _fetch_artifacts(self, node_id: int, run_id: str, path: str) -> None:
        try:
            entries = list(self.client.list_artifacts(run_id, path or None))
        except Exception as e:  # noqa: BLE001
            self.call_from_thread(self._set_status, f"artifacts error: {str(e)[:60]}")
            return

        def _add() -> None:
            tree = self.query_one("#art-tree", Tree)
            try:
                node = tree.get_node_by_id(node_id)
            except Exception:  # noqa: BLE001
                return
            if not entries:
                node.add_leaf("(empty)", data=None)
                return
            for e in entries:
                rel = e.path
                label = rel.split("/")[-1] or rel
                if e.is_dir:
                    node.add(label + "/", data=("dir", run_id, rel))
                else:
                    size = f" ({e.file_size}B)" if getattr(e, "file_size", None) else ""
                    node.add_leaf(label + size, data=None)

        self.call_from_thread(_add)

    # ---------- Status bar ----------

    def _set_status(self, msg: str) -> None:
        uri = tracking_uri()
        sel = "-"
        if self._selection:
            kind, ident, _ = self._selection
            sel = f"{kind}:{ident[:12]}"
        try:
            self.query_one("#status-bar", Static).update(f"{uri} │ {sel} │ {msg}")
        except Exception:  # noqa: BLE001
            pass  # status bar not mounted yet during early startup

    # ---------- Filter ----------

    def action_focus_filter(self) -> None:
        inp = self.query_one("#filter-input", Input)
        inp.display = True
        inp.focus()

    def action_escape(self) -> None:
        """Esc: clear filter if it's visible, otherwise quit."""
        try:
            inp = self.query_one("#filter-input", Input)
        except Exception:  # noqa: BLE001
            inp = None
        if inp is not None and inp.display:
            had_value = bool(inp.value)
            inp.value = ""
            inp.display = False
            if had_value:
                self._rebuild_tree()
            self.query_one("#src-tree", Tree).focus()
            return
        self.exit()

    @on(Input.Changed, "#filter-input")
    def _on_filter_changed(self, event: Input.Changed) -> None:
        # Rebuild from cache on every keystroke; cheap because we don't hit
        # the MLflow client — just walk the cached lists.
        _ = event
        self._rebuild_tree()

    @on(Input.Submitted, "#filter-input")
    def _on_filter_submitted(self, _: Input.Submitted) -> None:
        # Enter in the filter input shifts focus back to the tree so the
        # user can navigate matches with arrow keys.
        self.query_one("#src-tree", Tree).focus()

    # ---------- Actions ----------

    def action_refresh(self) -> None:
        self._populate_tree()

    def action_open_browser(self) -> None:
        if not self._selection:
            self._set_status("no selection")
            return
        if not tracking_uri_is_http():
            self._set_status("open: requires http(s):// MLFLOW_TRACKING_URI")
            return
        _, ident, _ = self._selection
        # `open_id` calls webbrowser.open which is non-blocking; we don't
        # need to suspend the terminal. Its stderr is swallowed under the
        # TUI but the status bar surfaces success/failure.
        rc = open_id(ident)
        self._set_status(
            f"opened {ident[:12]} in browser" if rc == 0 else f"open failed (rc={rc})"
        )

    def action_copy_selection(self) -> None:
        if not self._selection:
            self._set_status("no selection")
            return
        _, ident, _ = self._selection
        rc = copy_id(ident)
        self._set_status(
            f"copied {ident[:12]}" if rc == 0 else f"copy failed (rc={rc})"
        )

    def action_show_plot(self) -> None:
        if not self._selection or self._selection[0] != "run":
            self._set_status("plot: select a run row first")
            return
        run = self._selection_data
        if not run or not (run.data.metrics or {}):
            self._set_status("plot: this run has no metrics logged")
            return
        keys = sorted(run.data.metrics.keys())
        self.push_screen(PlotDialog(keys), self._on_plot_chosen)

    def _on_plot_chosen(self, result: Optional[list[str]]) -> None:
        if not result:
            return
        run = self._selection_data
        if not run:
            return
        self._set_status(f"plotting {len(result)} metric(s)…")
        self._render_plot(run.info.run_id, result)

    @work(thread=True, exclusive=True, group="plot")
    def _render_plot(self, run_id: str, keys: list[str]) -> None:
        # Update status to show progress while the (possibly slow) fetch runs.
        self.call_from_thread(
            self._set_status, f"fetching history for {len(keys)} metric(s)…"
        )
        try:
            series, skipped = fetch_histories(self.client, run_id, keys)
        except Exception as e:  # noqa: BLE001
            self.call_from_thread(self._set_status, f"plot error: {str(e)[:60]}")
            return

        if not series:
            msg = f"no metric history available for run {run_id[:8]}"
            if skipped:
                msg += f" ({len(skipped)} keys failed; first: {skipped[0][0]} — {skipped[0][1]})"
            self.call_from_thread(self._plot_show_message, msg)
            return

        def _draw() -> None:
            import plotext as plt

            plt.clf()
            plt.theme("pro")
            # Size from the App screen (always known) rather than the
            # plot-static widget's size — the latter is stale here because
            # we update the Static BEFORE switching to its tab, so its
            # rendered height is still 0 or 1.
            #
            # Layout reserved rows:
            #   header(1) + tab-strip(2) + status-bar(1) + footer(1)
            #   + stats lines below the chart (~6) + safety(2) = 13
            # Width: tree sidebar is 38%; subtract small padding for
            # tab-pane borders.
            screen_w = self.size.width or 120
            screen_h = self.size.height or 40
            plot_w = max(60, int(screen_w * 0.62) - 4)
            plot_h = max(15, screen_h - 13)
            plt.plotsize(plot_w, plot_h)
            plt.title(f"{run_id[:8]} — metrics")
            plt.xlabel("step")
            plt.ylabel("value")
            for key, (steps, values) in series.items():
                plt.plot(steps, values, label=key)
            chart_ansi = plt.build()

            # plotext.build() returns a raw ANSI string. Static.update()
            # accepts a Rich renderable; Text.from_ansi parses the colour
            # codes so the chart actually renders (vs. showing literal
            # escape sequences). This is the load-bearing detail that made
            # the v1 plot path silently "do nothing".
            body = Text.from_ansi(chart_ansi)
            if series:
                body.append("\n\n")
                for k, (_, vs) in series.items():
                    if vs:
                        body.append(
                            f"  {k}: min={min(vs):.4g}  max={max(vs):.4g}  "
                            f"last={vs[-1]:.4g}  n={len(vs)}\n"
                        )
            if skipped:
                body.append(
                    f"\nskipped {len(skipped)} key(s) "
                    f"(first: {skipped[0][0]} — {skipped[0][1]})\n",
                    style="yellow",
                )

            self.query_one("#plot-static", Static).update(body)
            self.query_one("#tabs", TabbedContent).active = "tab-plot"
            self._set_status(
                f"plotted {len(series)}/{len(keys)} metric(s)"
                + (f"  •  {len(skipped)} skipped" if skipped else "")
            )
            # Remember this selection so the next run-select can auto-replay.
            # Use the ORIGINAL requested `keys` (not just `series.keys()`) so
            # that a transient fetch failure on one metric doesn't permanently
            # drop it from the auto-replay set when we move to the next run.
            self._last_plot_keys = list(keys)

        self.call_from_thread(_draw)

    def _plot_show_message(self, msg: str) -> None:
        self.query_one("#plot-static", Static).update(msg)
        self.query_one("#tabs", TabbedContent).active = "tab-plot"
        self._set_status(msg[:80])

    def action_show_download(self) -> None:
        if not self._selection:
            self._set_status("no selection")
            return
        kind, ident, _ = self._selection
        if kind != "model":
            self._set_status("download: select a Model row first")
            return
        self.push_screen(DownloadDialog(ident))

    def action_dump_json(self) -> None:
        if not self._selection_data or not self._selection:
            self._set_status("no selection")
            return
        kind, ident, _ = self._selection
        try:
            if kind == "run":
                data = self._selection_data
                payload = {
                    "info": {
                        f: getattr(data.info, f, None)
                        for f in (
                            "run_id", "run_name", "experiment_id", "user_id",
                            "status", "start_time", "end_time",
                            "lifecycle_stage", "artifact_uri",
                        )
                    },
                    "data": {
                        "params": dict(data.data.params or {}),
                        "metrics": dict(data.data.metrics or {}),
                        "tags": dict(data.data.tags or {}),
                    },
                }
            elif kind == "experiment":
                e = self._selection_data
                payload = {
                    "experiment_id": e.experiment_id,
                    "name": e.name,
                    "lifecycle_stage": e.lifecycle_stage,
                    "artifact_location": e.artifact_location,
                    "creation_time": getattr(e, "creation_time", None),
                    "last_update_time": e.last_update_time,
                    "tags": dict(getattr(e, "tags", None) or {}),
                }
            else:
                m = self._selection_data
                payload = {
                    "name": m.name,
                    "description": m.description,
                    "creation_timestamp": m.creation_timestamp,
                    "last_updated_timestamp": m.last_updated_timestamp,
                    "latest_versions": [
                        {
                            "version": v.version,
                            "current_stage": v.current_stage,
                            "run_id": v.run_id,
                            "source": v.source,
                            "status": v.status,
                        }
                        for v in (m.latest_versions or [])
                    ],
                    "tags": dict(getattr(m, "tags", None) or {}),
                }
        except Exception as e:  # noqa: BLE001
            payload = {"id": ident, "kind": kind, "error": str(e)}

        text = _json.dumps(payload, indent=2, default=str)
        with self.suspend():
            proc = subprocess.Popen(
                ["less", "-R"], stdin=subprocess.PIPE, text=True
            )
            try:
                proc.communicate(text)
            except BrokenPipeError:
                pass
        self._set_status(f"dumped {kind} JSON")


def main() -> int:
    # Refuse to run when stdout is piped — the TUI needs a TTY for input
    # and would corrupt downstream pipes with escape sequences.
    import sys
    if not sys.stdout.isatty():
        print(
            "mlf: TUI requires a terminal. Use 'mlf list ...' or 'mlf -h' for "
            "piped output.",
            file=sys.stderr,
        )
        return 2
    MLflowApp().run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
