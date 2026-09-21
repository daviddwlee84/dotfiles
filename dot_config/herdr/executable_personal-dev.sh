#!/bin/sh
# A missing tool stays missing: shell/picker probes must never install software.
if command -v dev >/dev/null 2>&1; then
    exec dev
fi
printf '%s\n' 'dev is not installed. Enable Personal tools with dotcfg, then apply the configuration.' >&2
exit 127
