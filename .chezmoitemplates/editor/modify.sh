#!/bin/sh
# chezmoi modify_ script body: deep-merge a shared overlay into an editor's settings.json.
#
# Shared across VSCode (Code), Cursor, and Antigravity on both macOS
# (~/Library/Application Support/<Editor>/User/settings.json) and Linux
# (~/.config/<Editor>/User/settings.json). Each editor's modify_settings.json.tmpl
# is a 1-liner that includes this template.
#
# Why overlay (not whole-file): the live settings.json in each editor is a
# museum of project- and machine-specific junk (remote hosts, extension keys,
# one-off editor UI nudges). Tracking the whole file produces constant diff.
# `jq '. * $overlay'` enforces ONLY the keys declared in $overlay; everything
# else stays verbatim.
#
# To manage an additional key: edit .chezmoitemplates/editor/overlay.json.
# Per-editor deltas (future): add a sibling editor/overlay.<editor>.json and
# a second `jq '. * $extra'` pass; wire it in below. Minimal scope ships the
# shared overlay only.
#
# JSONC handling: VSCode / Cursor / Antigravity all write settings.json as
# JSONC (JSON with `//` and `/* */` comments plus trailing commas), but `jq`
# only reads strict JSON. The inline Python preprocessor below strips those
# while respecting string literals (so URLs like `https://...` inside strings
# are preserved). Normalisation means the managed settings.json will NOT
# preserve user-authored comments -- if you value them, keep notes in a
# sidecar file.
#
# Failure mode: if the live file is malformed beyond JSONC (e.g. unbalanced
# braces), jq exits non-zero and chezmoi skips this file for the apply. The
# broken live file is left untouched.
#
# Requires: jq + python3 (both installed by the `base` ansible role; system
# python3 is also pre-installed on macOS).
set -eu

overlay=$(cat <<'JSON'
{{ template "editor/overlay.json" . }}
JSON
)

base=$(cat)
[ -z "$base" ] && base='{}'

printf '%s' "$base" | python3 -c 'import sys, re
data = sys.stdin.read()
if not data.strip():
    data = "{}"
out = []
i, n = 0, len(data)
in_str = False
esc = False
quote = None
while i < n:
    c = data[i]
    if in_str:
        out.append(c)
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == quote:
            in_str = False
        i += 1
        continue
    if c == "\"" or c == "\x27":
        in_str = True
        quote = c
        out.append(c)
        i += 1
        continue
    if c == "/" and i + 1 < n and data[i + 1] == "/":
        while i < n and data[i] != "\n":
            i += 1
        continue
    if c == "/" and i + 1 < n and data[i + 1] == "*":
        i += 2
        while i + 1 < n and not (data[i] == "*" and data[i + 1] == "/"):
            i += 1
        i += 2
        continue
    out.append(c)
    i += 1
stripped = "".join(out)
stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
sys.stdout.write(stripped)
' | jq --argjson overlay "$overlay" '. * $overlay'
