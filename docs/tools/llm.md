# Local LLM Tools

Optional role (`installLlmTools`). Install via `chezmoi init --force` and enable the prompt.

## Tools

| Tool | Binary | Purpose | Install path |
|------|--------|---------|--------------|
| [Ollama](https://ollama.com/) | `ollama` | Local LLM runtime and API server | macOS: Homebrew formula or `ollama-app` via Brewfile; Linux: official installer |
| [LiteLLM](https://github.com/BerriAI/litellm) | `litellm` | Local proxy / unified API for LLM backends | `uv tool install litellm[proxy] --with httpx[socks]` |
| [llmfit](https://github.com/AlexsJones/llmfit) | `llmfit` | Recommend models that fit your hardware | macOS: Homebrew formula; Linux: official local installer |
| [models](https://github.com/arimxyer/models) | `models` | Browse models, benchmarks, coding agents, provider status | macOS/Linuxbrew: Homebrew formula; Linux fallback: `cargo install modelsdev` |

## Platform Notes

- **macOS, `installBrewApps=false`**: ansible installs `ollama`, `llmfit`, and `models` via Homebrew formulas.
- **macOS, `installBrewApps=true`**: ansible still installs `llmfit` and `models`, but `ollama` is deferred to `~/.config/homebrew/Brewfile.darwin` as `ollama-app`.
- **Linux with sudo**: ansible installs `litellm`, `llmfit`, `models`, and `ollama`.
- **Linux with `noRoot=true`**: ansible installs `litellm`, `llmfit`, and `models`, and explicitly skips `ollama`.

## macOS GUI vs CLI

- `ollama-app` is preferred when you already opted into GUI apps with `installBrewApps=true`.
- `brew install ollama` is used when you want the CLI/runtime without the GUI app.
- The macOS app also exposes the `ollama` CLI from inside the app bundle.

## Common Usage

```bash
# Start the Ollama API server
ollama serve

# Run the LiteLLM proxy
litellm --help

# Check which models fit your hardware
llmfit

# Browse models and benchmarks
models
```

## noRoot Reminder

`noRoot=true` skips `ollama` because the official Linux install path sets up system locations and a systemd service. The other tools remain user-level installs.
