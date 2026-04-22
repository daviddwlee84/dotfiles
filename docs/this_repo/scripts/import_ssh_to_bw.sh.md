# import_ssh_to_bw.sh

Import SSH key pairs into a Bitwarden vault using the `bw` CLI.

## Requirements

- `bw` (Bitwarden CLI >= 2024.x) -- provides the SSH Key item type (type 5)
- `jq` -- for building JSON payloads and parsing responses
- `ssh-keygen` -- for extracting fingerprints and key types

## How It Works

1. **Discovery** -- Scans `~/.ssh` (or a custom directory) for files starting with `-----BEGIN...PRIVATE KEY-----`. Skips `.pub`, `known_hosts`, `config`, `authorized_keys`, swap files, etc.
2. **Metadata extraction** -- For each private key, looks for a matching `.pub` file (tries `<key>.pub` and `<stem>.pub`). Extracts the fingerprint, key type, and comment via `ssh-keygen -lf`.
3. **Interactive selection** -- Displays a table of discovered keys and prompts the user to pick which ones to import (by number, `a` for all, `q` to quit).
4. **Duplicate detection** -- Before creating an item, checks if an item with the same name already exists in the vault. In interactive mode, offers to overwrite; in `--all` mode, skips duplicates.
5. **Import** -- Creates a Bitwarden **SSH Key item** (type 5) with private key, public key, and fingerprint. Falls back to a **Secure Note** (type 2) if the fingerprint cannot be extracted.

## Usage

```bash
ssh-to-bitwarden [OPTIONS]
```

### Options

| Flag | Description |
|---|---|
| `-d, --dir DIR` | Directory to scan (default: `~/.ssh`) |
| `-a, --all` | Import all discovered keys without prompting |
| `-n, --dry-run` | Show what would be imported without creating items |
| `-p, --prefix STR` | Prefix for Bitwarden item names (default: `SSH`) |
| `-h, --help` | Show help message |

### Examples

```bash
# Interactive mode -- scan ~/.ssh, pick which keys to import
./import_ssh_to_bw.sh

# Import everything without prompting
./import_ssh_to_bw.sh --all

# Preview what would be imported
./import_ssh_to_bw.sh --dry-run

# Scan a different directory
./import_ssh_to_bw.sh --dir /path/to/keys

# Use a custom name prefix (items will be named "Work SSH: <keyname>")
./import_ssh_to_bw.sh --prefix "Work SSH"
```

## Bitwarden Item Types

| Condition | Bitwarden Type | Notes |
|---|---|---|
| Fingerprint extractable | SSH Key (type 5) | Stores private key, public key, and fingerprint natively |
| Fingerprint not available | Secure Note (type 2) | Private key stored in the notes field as fallback |

Items are named `<prefix>: <filename>` (e.g. `SSH: azure_vm1`, `SSH: Puff.pem`).

## Notes

- The `bw unlock` step requires interactive password input, so the script must be run directly in a terminal (not from a non-interactive shell).
- You must be logged in first (`bw login`). The script will error if the vault status is `unauthenticated`.
- When using `--all`, existing duplicates are skipped rather than overwritten. Use interactive mode to overwrite.
- Keys are sorted alphabetically by filename in the selection table.
