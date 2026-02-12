# Specify CLI (Spec Kit)

`specify-cli` is the CLI from GitHub Spec Kit for spec-driven development workflows.

## Installation in This Dotfiles Repo

`specify-cli` is installed automatically by the `coding_agents` ansible role using `uv`.

Install command used by the role:

```bash
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
```

## Manual Install / Upgrade

```bash
# Install
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git

# Upgrade
uv tool install specify-cli --force --from git+https://github.com/github/spec-kit.git
```

## Verify and Quick Start

```bash
specify check
specify init . --ai claude
```

## References

- [Spec Kit repository](https://github.com/github/spec-kit)
- [Spec Kit documentation](https://github.github.io/spec-kit/)
