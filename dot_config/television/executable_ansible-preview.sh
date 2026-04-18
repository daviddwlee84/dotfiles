#!/bin/sh
# Preview script for the `ansible` tv channel.
# Usage: ansible-preview.sh <view> <kind> <name> <path>
#   view: main | alt
#   kind: playbook | role | tag

view="$1"
kind="$2"
name="$3"
path="$4"

show_yaml() {
  f="$1"
  if command -v bat >/dev/null 2>&1; then
    bat --color=always --paging=never -l yaml --style=numbers "$f"
  else
    cat "$f"
  fi
}

case "$view:$kind" in
  main:playbook)
    show_yaml "$path"
    ;;
  alt:playbook)
    grep -hoE 'tags: \[[^]]+\]' "$path" \
      | sed -E 's/tags: \[//; s/\]//; s/,/\n/g' \
      | tr -d ' ' | sort -u
    ;;
  main:role)
    main="$path/tasks/main.yml"
    defs="$path/defaults/main.yml"
    if [ -f "$main" ]; then
      echo "=== tasks/main.yml ==="
      show_yaml "$main"
    fi
    if [ -f "$defs" ]; then
      echo
      echo "=== defaults/main.yml ==="
      show_yaml "$defs"
    fi
    ;;
  alt:role)
    ls -la "$path"
    ;;
  main:tag)
    grep -rn --color=always "tags: \[.*${name}.*\]" "$HOME/.ansible/playbooks/" 2>/dev/null
    ;;
  alt:tag)
    grep -rln "tags: \[.*${name}.*\]" "$HOME/.ansible/roles/" 2>/dev/null | head -40
    ;;
esac
