# Notebook ecosystem (Jupyter, Marimo, Voila, JupyterHub, kernels)

Reference page covering the moving parts behind interactive notebooks: which **frontends** render notebooks, what **kernels** run the code, how `pip install` inside a notebook actually behaves, and the install-method quirks (e.g. when `jupyter` meta-CLI is on PATH and when only `jupyter-lab` is). For what this dotfiles repo specifically installs, see the "[In this repo](#in-this-repo)" section below.

## Frontends — UIs that render notebooks

| Frontend | Notebook format | Multi-doc UI | Reactive | Multi-language | Use it for |
|----------|-----------------|--------------|----------|----------------|-----------|
| [JupyterLab](https://jupyter.org/) | `.ipynb` | Yes (tabs, splits, file browser) | No (manual run) | Yes (any kernel) | General data science, multi-language, plugin-rich |
| [Jupyter Notebook v7+](https://github.com/jupyter/notebook) | `.ipynb` | No (single doc per tab) | No | Yes | "Classic" UI feel; rebuilt on JupyterLab JS components since v7 (2023) |
| [marimo](https://github.com/marimo-team/marimo) | `.py` (PEP 723) | Yes | **Yes** (DAG-based) | Python only | Reproducibility, git-friendly diffs, deterministic execution |
| [Voila](https://github.com/voila-dashboards/voila) | `.ipynb` (rendered) | N/A — single-app server | N/A | Inherits from kernel | Turning a notebook into a read-only/interactive dashboard for end-users |
| [JupyterHub](https://github.com/jupyterhub/jupyterhub) | N/A — multi-user spawner | N/A | N/A | Inherits | Institutional / classroom: each user gets their own Jupyter server |

**Key distinctions**:

- **JupyterLab vs Jupyter Notebook**: since Notebook v7 (2023) they're separate PyPI packages (`jupyterlab`, `notebook`) but built on the **same JupyterLab JS components**. They install side-by-side cleanly in one Python env. v6 of `notebook` was the legacy classic codebase — that's deprecated.
- **Marimo is not Jupyter**. It's a separate frontend AND separate execution model (reactive, DAG-based, no hidden cell-order state). It stores notebooks as plain `.py` files with PEP 723 metadata, not `.ipynb`. The [`marimo-jupyter-extension`](https://github.com/marimo-team/marimo-jupyter-extension) is a *JupyterLab plugin* that lets you launch marimo sessions from inside JupyterLab — it must be installed in the **JupyterLab env**, not the marimo env.
- **Voila and JupyterHub are layers, not full UIs**. Voila wraps a single notebook into a no-code dashboard. JupyterHub spawns per-user JupyterLab/Notebook instances behind auth.

## Kernels — what actually runs the code

A kernel is a small server process that owns a language runtime and speaks the [Jupyter messaging protocol](https://jupyter-client.readthedocs.io/en/stable/messaging.html). The frontend (Lab/Notebook/Voila) sends code; the kernel executes; results stream back. This decoupling is why Jupyter is multi-language.

**Kernel discovery paths** (in priority order):

1. `~/.local/share/jupyter/kernels/<name>/` — user-level (preferred for most installs)
2. `<sys.prefix>/share/jupyter/kernels/<name>/` — env-local (e.g. `~/.local/share/uv/tools/jupyterlab/share/jupyter/kernels/`)
3. `/usr/local/share/jupyter/kernels/`, `/usr/share/jupyter/kernels/` — system-wide

Each kernel directory has a `kernel.json` with the launch command. You can list them with `jupyter kernelspec list`.

**Common kernels and how to install them**:

| Language | Kernel | Install | Notes |
|----------|--------|---------|-------|
| Python | [`ipykernel`](https://github.com/ipython/ipykernel) | `python -m ipykernel install --user --name <name> --display-name "<label>"` | Auto-runs against the python that invokes it — register one per project venv |
| .NET (C#/F#/PowerShell) | [`Microsoft.dotnet-interactive`](https://github.com/dotnet/interactive) | `dotnet tool install -g Microsoft.dotnet-interactive && dotnet interactive jupyter install` | Installs three kernels: `.net-csharp`, `.net-fsharp`, `.net-pwsh` |
| Rust | [`evcxr_jupyter`](https://github.com/evcxr/evcxr) | `cargo install evcxr_jupyter && evcxr_jupyter --install` | REPL-style execution; supports `:dep` for crate deps |
| C++ | [`xeus-cling`](https://github.com/jupyter-xeus/xeus-cling) (legacy) / [`xeus-cpp`](https://github.com/compiler-research/xeus-cpp) (active) | conda only: `mamba install -c conda-forge xeus-cling` | Hard to install outside conda — depends on patched LLVM/Cling. xeus-cpp is the modern fork on Clang-Repl |
| Julia | [`IJulia`](https://github.com/JuliaLang/IJulia.jl) | From Julia REPL: `using Pkg; Pkg.add("IJulia")` | Auto-registers itself |
| R | [`IRkernel`](https://github.com/IRkernel/IRkernel) | In R: `install.packages("IRkernel"); IRkernel::installspec()` | |
| JavaScript / TypeScript | [`ijavascript`](https://github.com/n-riesco/ijavascript) / [`tslab`](https://github.com/yunabe/tslab) | `npm i -g ijavascript && ijsinstall` | Node.js REPL; `tslab` adds TypeScript support |
| Bash | [`bash_kernel`](https://github.com/takluyver/bash_kernel) | `pip install bash_kernel && python -m bash_kernel.install` | |
| Go | [`gophernotes`](https://github.com/gopherdata/gophernotes) | See repo — `go install` + manual `kernel.json` copy | |

Once a kernel is registered at the user level (`~/.local/share/jupyter/kernels/`), **it's visible to every Jupyter frontend on the host** — JupyterLab, Notebook, and Voila all see the same kernels. You don't need to reinstall the kernel per-frontend.

## In this repo

The dotfiles install two notebook frontends via `uv tool` (defined in [`dot_ansible/roles/python_uv_tools/defaults/main.yml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_ansible/roles/python_uv_tools/defaults/main.yml)):

| Tool | Primary package | Extras / `--with` | Exposes |
|------|-----------------|-------------------|---------|
| `marimo` | `marimo[recommended,mcp]` | `httpx[socks]` | `marimo` (binary) — completion auto-loads via [`dot_config/shell/29_marimo.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/29_marimo.sh) |
| `jupyterlab` | `jupyterlab` | `marimo[sandbox]`, `marimo-jupyter-extension`, `ipykernel`, `ipywidgets` | `jupyter-lab`, `jupyter-notebook`, `jupyter` (meta-CLI), `jupyter-server`, `jupyter-kernelspec`, ... — all four invocation forms work: `jupyter-lab` / `jupyter lab` / `jupyter-notebook` / `jupyter notebook` |

The two are **separate uv tool envs** (each lives under `~/.local/share/uv/tools/<name>/`), so their dependency trees don't collide. Marimo's reactive-DAG runtime never touches Jupyter; the JupyterLab env hosts both Lab and Notebook frontends behind one shared message protocol.

Marimo first-run config: [`dot_config/marimo/create_marimo.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/marimo/create_marimo.toml.tmpl) (uses chezmoi `create_` prefix — seeded once, then user-owned). Vim mode is gated on the `enableVimMode` chezmoi prompt, see [vim-mode.md](../this_repo/vim-mode.md).

**What's not installed by this repo** (but covered below for reference):

- **Voila** — install ad-hoc via `uv tool install voila` if you need to share a notebook as a dashboard. Not bundled because it's a deployment-time tool, not a daily driver.
- **JupyterHub** — server-side, multi-user. Not a per-user dotfile concern.
- **Language kernels other than Python/ipykernel** — install on demand via the recipes above.

## The `jupyter` meta-CLI vs standalone binaries

`jupyter` (the command you type) is a **dispatcher** from [`jupyter-core`](https://github.com/jupyter/jupyter_core), not its own application. It scans `$PATH` and `<sys.prefix>/bin/` for executables named `jupyter-<subcommand>` and forwards arguments. So `jupyter lab` literally execs `jupyter-lab`. Both invocation forms are equivalent — the dispatcher is just sugar.

This matters for **how you install things**:

| Install method | `jupyter` | `jupyter-lab` | `jupyter-notebook` | `jupyter kernelspec` |
|----------------|:---------:|:-------------:|:------------------:|:--------------------:|
| `pip install jupyterlab notebook` (in a venv) | ✓ | ✓ | ✓ | ✓ |
| `pip install jupyter` (meta-package) | ✓ | ✓ | ✓ | ✓ — pulls all components |
| `uv tool install jupyterlab` | ✗ | ✓ | ✗ | ✗ |
| `uv tool install jupyterlab --with notebook` | ✗ | ✓ | ✗ (installed but hidden) | ✗ |
| `uv tool install jupyterlab --with-executables-from notebook --with-executables-from jupyter-core` | ✓ | ✓ | ✓ | ✓ |
| `uv tool install jupyter` (meta-package) | ✗ | ✗ | ✗ | ✗ — empty stub, no scripts |

**Why uv tool is different from pip**: `uv tool install <pkg>` is designed to expose only the *primary* package's `[project.scripts]` entry points to `~/.local/bin`. `--with <dep>` adds runtime deps but hides their executables. The opt-in flag [`--with-executables-from <pkg>`](https://docs.astral.sh/uv/concepts/tools/) installs **and** exposes the executables of an extra package — that's how this repo gets `jupyter-notebook` and the `jupyter` dispatcher onto PATH from a single `uv tool install jupyterlab` invocation.

**Don't use `uv tool install jupyter`** (the meta-package). Inspecting its PyPI metadata: `provides_extra=[]`, `[project.scripts]={}`. It's an empty stub that just declares deps on `notebook + jupyterlab + ipykernel + ...`. uv would install the deps in an env but expose **zero** binaries because the primary package has no entry points of its own.

## Where does `!pip install <pkg>` actually go?

This is a frequent confusion. The short version: `!pip install` runs `pip` in a **subshell using the kernel's interpreter**, so it installs into whichever Python env is hosting the running kernel — which may not be where you think.

For this repo's setup, when you launch a notebook with the **default Python kernel** (the one provided by `ipykernel` shipped inside `~/.local/share/uv/tools/jupyterlab/`):

- `!pip install pandas` → installs `pandas` into `~/.local/share/uv/tools/jupyterlab/lib/python3.X/site-packages/`
- This **works** — the next cell can `import pandas` immediately
- But it's **fragile**: if you later run `uv tool upgrade jupyterlab` or `uv tool install --reinstall jupyterlab ...`, uv may rebuild the env from scratch and your ad-hoc package is gone
- It also **pollutes the UI env** — the JupyterLab env was meant to host Lab/Notebook itself, not your project's analysis libs

### Better: `%pip` magic instead of `!pip`

```python
%pip install pandas
```

This is a [Jupyter magic](https://ipython.readthedocs.io/en/stable/interactive/magics.html) — same effect, but Jupyter-aware: it prints a warning if it detects the kernel's env doesn't match the running shell, suggests a kernel restart after install, and uses `sys.executable` so you can't hit the wrong Python.

### Best: register a project kernel from a project venv

For anything beyond throwaway exploration, give each project its own venv with `ipykernel` and register it as a kernel:

```sh
cd ~/projects/my-analysis
uv venv .venv
source .venv/bin/activate
uv pip install ipykernel pandas matplotlib scikit-learn
python -m ipykernel install --user --name my-analysis --display-name "Python (my-analysis)"
```

Then in JupyterLab → kernel picker (top-right) → "Python (my-analysis)". The kernel spec lives in `~/.local/share/jupyter/kernels/my-analysis/kernel.json` and is visible to **every** Jupyter frontend on the host (Lab, Notebook, Voila).

Now `!pip install <new-pkg>` inside a cell installs into `.venv/`, not into the JupyterLab tool env. Project deps stay in the project, and you can blow away `.venv` without breaking JupyterLab.

To remove a registered kernel: `jupyter kernelspec uninstall my-analysis`.

### Best (marimo): PEP 723 sandbox

Marimo sidesteps the kernel-registration problem entirely. With sandbox mode (`--sandbox` flag, or set as default via `[runtime] sandbox` in `marimo.toml`), each notebook declares its deps inline as a [PEP 723](https://peps.python.org/pep-0723/) script-metadata block at the top of the `.py` file:

```python
# /// script
# requires-python = ">=3.11"
# dependencies = ["pandas", "matplotlib", "scikit-learn"]
# ///

import marimo as mo
# ...
```

When opened, marimo asks `uv` to materialize an isolated venv for that notebook. No global kernel registration, no `!pip install` ambiguity, no env pollution — and the notebook is self-contained and reproducible.

The [`marimo-jupyter-extension`](https://github.com/marimo-team/marimo-jupyter-extension) bundled in this repo lets you launch marimo notebooks from inside JupyterLab, picking the env per-notebook from PEP 723 metadata. That's why both `marimo[sandbox]` and the extension are pinned as `--with` deps on the JupyterLab uv tool.

## Quick decision matrix

| You want to... | Use |
|----------------|-----|
| Quickly explore data, deterministic re-runs | **marimo** (sandbox mode) |
| Multi-language exploration (Rust + Python + Julia) | **JupyterLab** + per-language kernels |
| Classic single-doc UI feel | `jupyter notebook` (Notebook v7 in this repo) |
| Turn a finished notebook into a no-code dashboard | **Voila** (`uv tool install voila`) |
| Multi-user / classroom deployment | **JupyterHub** (server-side, out of scope here) |
| Reproducible, diff-friendly notebooks with version control | **marimo** (`.py` files, no opaque `.ipynb` JSON) |
| Persist project deps independently of the UI | Project venv + `ipykernel` registered kernel |

## See also

- [llm.md](llm.md) — local LLM tools (LiteLLM, Ollama, models) often used alongside notebooks
- [vim-mode.md](../this_repo/vim-mode.md) — marimo's `[keymap] preset` is gated on `enableVimMode`
- [zsh/zsh-completions.md](../zsh/zsh-completions.md) — marimo shell completion auto-loads
- [chezmoi-prefixes.md](chezmoi-prefixes.md) — why marimo's config uses `create_` (seed-once) instead of `modify_` (overlay) prefix
- Upstream docs: [JupyterLab](https://jupyterlab.readthedocs.io/) · [marimo](https://docs.marimo.io/) · [Voila](https://voila.readthedocs.io/) · [JupyterHub](https://jupyterhub.readthedocs.io/) · [PEP 723](https://peps.python.org/pep-0723/)
