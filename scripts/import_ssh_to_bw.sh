#!/usr/bin/env bash
# ssh-to-bitwarden - Import SSH key pairs into Bitwarden vault
#
# Scans a directory (default: ~/.ssh) for SSH private keys, shows an
# interactive menu for selecting which keys to import, then creates
# Bitwarden vault items for each selected key.
#
# Requirements: bw (Bitwarden CLI >= 2024.x), jq, ssh-keygen
#
# Usage:
#   ssh-to-bitwarden [OPTIONS]
#
# Options:
#   -d, --dir DIR       Directory to scan (default: ~/.ssh)
#   -a, --all           Import all discovered keys without prompting
#   -n, --dry-run       Show what would be imported without creating items
#   -p, --prefix STR    Prefix for Bitwarden item names (default: "SSH")
#   -h, --help          Show this help message

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
SSH_DIR="$HOME/.ssh"
IMPORT_ALL=false
DRY_RUN=false
NAME_PREFIX="SSH"

# Field separator for internal record passing (ASCII Unit Separator)
FS=$'\x1f'

# ── Colors (disabled if not a terminal) ───────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'    DIM='\033[2m'    RESET='\033[0m'
  GREEN='\033[32m'  YELLOW='\033[33m' RED='\033[31m' CYAN='\033[36m'
else
  BOLD='' DIM='' RESET='' GREEN='' YELLOW='' RED='' CYAN=''
fi

# ── Helpers ───────────────────────────────────────────────────────────
info()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
skip()  { printf "${DIM}[SKIP]${RESET}  %s\n" "$*"; }

usage() {
  cat <<'USAGE'
ssh-to-bitwarden - Import SSH key pairs into Bitwarden vault

Usage:
  ssh-to-bitwarden [OPTIONS]

Options:
  -d, --dir DIR       Directory to scan (default: ~/.ssh)
  -a, --all           Import all discovered keys without prompting
  -n, --dry-run       Show what would be imported without creating items
  -p, --prefix STR    Prefix for Bitwarden item names (default: "SSH")
  -h, --help          Show this help message

Examples:
  ssh-to-bitwarden                  # Interactive mode, scan ~/.ssh
  ssh-to-bitwarden --all            # Import all keys without prompting
  ssh-to-bitwarden -d /tmp/keys     # Scan a custom directory
  ssh-to-bitwarden --dry-run        # Preview what would be imported
USAGE
  exit 0
}

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)     SSH_DIR="$2"; shift 2 ;;
    -a|--all)     IMPORT_ALL=true; shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -p|--prefix)  NAME_PREFIX="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            error "Unknown option: $1"; usage ;;
  esac
done

# ── Dependency checks ────────────────────────────────────────────────
for cmd in bw jq ssh-keygen; do
  if ! command -v "$cmd" &>/dev/null; then
    error "Required command '$cmd' not found. Please install it first."
    exit 1
  fi
done

# ── Discover SSH private keys ────────────────────────────────────────
# Scans the given directory for files that look like SSH private keys.
# Outputs one file path per line.
discover_keys() {
  local dir="$1"

  if [ ! -d "$dir" ]; then
    error "Directory not found: $dir"
    exit 1
  fi

  while IFS= read -r -d '' file; do
    local name
    name=$(basename "$file")

    # Skip known non-key files
    case "$name" in
      *.pub|known_hosts*|config|authorized_keys*|*.swp|*.swo|*~|*.un~|*.log) continue ;;
    esac

    # Check if file begins with a PEM private key header
    if head -1 "$file" 2>/dev/null | grep -q '^\-\-\-\-\-BEGIN.*PRIVATE KEY\-\-\-\-\-'; then
      echo "$file"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
}

# ── Extract key metadata ─────────────────────────────────────────────
# Returns a FS-delimited record:
#   privkey FS pubkey FS fingerprint FS key_type FS basename
get_key_info() {
  local privkey="$1"
  local pubkey="${privkey}.pub"
  local name
  name=$(basename "$privkey")

  local fingerprint="N/A"
  local key_type="unknown"

  # Look for a matching .pub file
  if [ ! -f "$pubkey" ]; then
    local stem="${privkey%.*}"
    if [ -f "${stem}.pub" ]; then
      pubkey="${stem}.pub"
    else
      pubkey=""
    fi
  fi

  # Extract fingerprint and type from ssh-keygen
  # Output format: "bits SHA256:xxx comment (TYPE)"
  local keygen_src="${pubkey:-$privkey}"
  local keygen_output
  keygen_output=$(ssh-keygen -lf "$keygen_src" 2>/dev/null) || true

  if [ -n "$keygen_output" ]; then
    fingerprint=$(awk '{print $2}' <<< "$keygen_output")
    key_type=$(grep -oE '\([A-Za-z0-9_-]+\)\s*$' <<< "$keygen_output" | tr -d '() ') || key_type="unknown"
    [ -z "$key_type" ] && key_type="unknown"
  fi

  printf '%s' "${privkey}${FS}${pubkey}${FS}${fingerprint}${FS}${key_type}${FS}${name}"
}

# Parse a key-info record into variables.
# Usage: parse_key_info "$record"  (sets: K_PRIV, K_PUB, K_FP, K_TYPE, K_NAME)
parse_key_info() {
  local record="$1"
  IFS="$FS" read -r K_PRIV K_PUB K_FP K_TYPE K_NAME <<< "$record"
}

# ── Display key table ─────────────────────────────────────────────────
display_keys() {
  local -n _keys=$1
  local count=${#_keys[@]}

  printf "\n${BOLD}Found %d SSH private key(s) in %s:${RESET}\n\n" "$count" "$SSH_DIR"
  printf "  ${BOLD}%-4s  %-28s  %-10s  %-10s  %-50s${RESET}\n" "#" "Name" "Type" "Has .pub" "Fingerprint"
  printf "  %-4s  %-28s  %-10s  %-10s  %-50s\n" "----" "----------------------------" "----------" "----------" "--------------------------------------------------"

  local i=1
  for record in "${_keys[@]}"; do
    parse_key_info "$record"
    local has_pub="no"
    [ -n "$K_PUB" ] && [ -f "$K_PUB" ] && has_pub="yes"
    printf "  ${CYAN}%-4s${RESET}  %-28s  %-10s  %-10s  %s\n" \
      "$i" "$K_NAME" "$K_TYPE" "$has_pub" "$K_FP"
    ((i++))
  done
  echo ""
}

# ── Interactive selection ─────────────────────────────────────────────
select_keys() {
  local -n _keys=$1
  local -n _selected=$2
  local count=${#_keys[@]}

  while true; do
    printf "${BOLD}Select keys to import:${RESET}\n"
    printf "  ${DIM}Enter numbers separated by spaces (e.g. 1 3 4)${RESET}\n"
    printf "  ${DIM}Enter 'a' for all, 'q' to quit, 'l' to list again${RESET}\n"
    printf "> "
    read -r choice

    case "$choice" in
      q|Q)
        echo "Aborted."
        exit 0
        ;;
      a|A)
        _selected=("${_keys[@]}")
        return 0
        ;;
      l|L)
        display_keys _keys
        continue
        ;;
      "")
        warn "No selection made. Try again."
        continue
        ;;
    esac

    # Parse numeric selections
    _selected=()
    local valid=true
    for num in $choice; do
      if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "$count" ]; then
        error "Invalid selection: $num (must be 1-$count)"
        valid=false
        break
      fi
      _selected+=("${_keys[$((num - 1))]}")
    done

    if $valid && [ ${#_selected[@]} -gt 0 ]; then
      return 0
    fi
  done
}

# ── Check for existing items in vault ─────────────────────────────────
check_existing() {
  local name="$1"
  local existing
  existing=$(bw list items --search "$name" 2>/dev/null \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' 2>/dev/null) || true
  echo "$existing"
}

# ── Import a single key ──────────────────────────────────────────────
import_key() {
  parse_key_info "$1"

  local item_name="${NAME_PREFIX}: ${K_NAME}"
  local has_pub=false
  [ -n "$K_PUB" ] && [ -f "$K_PUB" ] && has_pub=true

  info "Importing: ${K_NAME}"
  printf "       Type: %s | Fingerprint: %s | Has .pub: %s\n" \
    "$K_TYPE" "$K_FP" "$has_pub"

  # Check for duplicates
  local existing_id
  existing_id=$(check_existing "$item_name")
  if [ -n "$existing_id" ]; then
    warn "Item '$item_name' already exists in vault (id: $existing_id)"
    if ! $IMPORT_ALL; then
      printf "       Overwrite? [y/N] > "
      read -r overwrite
      if [[ ! "$overwrite" =~ ^[yY]$ ]]; then
        skip "Skipped $K_NAME (already exists)"
        echo ""
        return 0
      fi
      # Delete old item before re-creating
      info "Deleting existing item $existing_id..."
      bw delete item "$existing_id" >/dev/null
    else
      skip "Skipped $K_NAME (already exists; use interactive mode to overwrite)"
      echo ""
      return 0
    fi
  fi

  if $DRY_RUN; then
    ok "[DRY RUN] Would create: $item_name"
    echo ""
    return 0
  fi

  local private_key_content
  private_key_content=$(cat "$K_PRIV")

  local public_key_content=""
  if $has_pub; then
    public_key_content=$(cat "$K_PUB")
  fi

  # Build vault item JSON
  local item_json result item_id

  if [ "$K_FP" != "N/A" ]; then
    # SSH Key item (type 5)
    item_json=$(jq -n \
      --arg name "$item_name" \
      --arg priv "$private_key_content" \
      --arg pub "$public_key_content" \
      --arg fp "$K_FP" \
      '{
        type: 5,
        name: $name,
        sshKey: {
          privateKey: $priv,
          publicKey: $pub,
          keyFingerprint: $fp
        }
      }')
  else
    # Fallback: Secure Note (type 2)
    warn "Cannot extract fingerprint; storing as Secure Note instead"
    item_json=$(jq -n \
      --arg name "$item_name" \
      --arg notes "$private_key_content" \
      '{
        type: 2,
        name: $name,
        notes: $notes,
        secureNote: { type: 0 }
      }')
  fi

  result=$(echo "$item_json" | bw encode | bw create item)
  item_id=$(echo "$result" | jq -r '.id')
  ok "Created: $item_name (id: $item_id)"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────
main() {
  echo ""
  printf "${BOLD}ssh-to-bitwarden${RESET} - Import SSH keys into Bitwarden vault\n"
  echo ""

  if $DRY_RUN; then
    warn "Dry-run mode enabled. No items will be created."
    echo ""
  fi

  # Discover keys
  info "Scanning $SSH_DIR for SSH private keys..."
  local key_files=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key_files+=("$line")
  done < <(discover_keys "$SSH_DIR")

  if [ ${#key_files[@]} -eq 0 ]; then
    warn "No SSH private keys found in $SSH_DIR"
    exit 0
  fi

  # Gather metadata for each key
  local key_infos=()
  for keyfile in "${key_files[@]}"; do
    key_infos+=("$(get_key_info "$keyfile")")
  done

  # Sort by name for consistent display
  IFS=$'\n' key_infos=($(for r in "${key_infos[@]}"; do echo "$r"; done | sort -t"$FS" -k5))
  unset IFS

  # Display discovered keys
  display_keys key_infos

  # Select keys to import
  local selected=()
  if $IMPORT_ALL; then
    info "Importing all keys (--all flag)"
    selected=("${key_infos[@]}")
  else
    select_keys key_infos selected
  fi

  local total=${#selected[@]}
  printf "\n${BOLD}Importing %d key(s)...${RESET}\n\n" "$total"

  # Ensure vault is unlocked (unless dry-run)
  if ! $DRY_RUN; then
    local status
    status=$(bw status 2>/dev/null | jq -r '.status')
    case "$status" in
      unauthenticated)
        error "Not logged in. Run 'bw login' first."
        exit 1
        ;;
      locked)
        info "Vault is locked. Unlocking..."
        BW_SESSION=$(bw unlock --raw)
        export BW_SESSION
        ok "Vault unlocked."
        ;;
      unlocked)
        ok "Vault already unlocked."
        ;;
    esac

    info "Syncing vault..."
    bw sync >/dev/null
    ok "Vault synced."
    echo ""
  fi

  # Import each selected key
  local imported=0 failed=0
  for record in "${selected[@]}"; do
    if import_key "$record"; then
      ((imported++))
    else
      ((failed++))
    fi
  done

  # Summary
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if $DRY_RUN; then
    printf "${BOLD}Dry run complete.${RESET} %d key(s) would be imported.\n" "$total"
  else
    printf "${BOLD}Done!${RESET} %d key(s) processed" "$total"
    [ "$failed" -gt 0 ] && printf " (%d failed)" "$failed"
    printf ".\n"
  fi
  echo ""
  if ! $DRY_RUN; then
    printf "${DIM}Verify with: bw list items --search '%s'${RESET}\n" "$NAME_PREFIX"
  fi
}

main
