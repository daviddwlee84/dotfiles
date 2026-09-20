#!/usr/bin/env bash
# Read the small go_tools manifest schema without adding a YAML runtime to the
# upgrade command. Unknown/malformed records fail before any packages are output.
# Usage: go_tool_packages defaults.yml Darwin|Linux
go_tool_packages() {
  local manifest="$1" platform="$2"
  case "$platform" in Darwin | Linux) ;; *) return 0 ;; esac
  awk -v platform="$platform" '
    function fail(message) {
      print "go_tools manifest: " message > "/dev/stderr"
      failed=1
    }
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function unquote(value) {
      value=trim(value)
      if (value ~ /^"[^"\\]*"$/ || value ~ /^\047[^\047]*\047$/) {
        value=substr(value, 2, length(value)-2)
      }
      return value
    }
    function finish(    count, values, i, selected) {
      if (!record) return
      if (name !~ /^[A-Za-z0-9][A-Za-z0-9._\/+~-]*@[A-Za-z0-9][A-Za-z0-9.+-]*$/ ||
          binary !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || length(platforms) < 3 ||
          substr(platforms, 1, 1) != "[" || substr(platforms, length(platforms), 1) != "]") {
        fail("each entry needs name@version, binary and an inline platforms list")
        return
      }
      if (names[name]++ || binaries[binary]++) {
        fail("duplicate package or binary")
        return
      }
      platforms=substr(platforms, 2, length(platforms)-2)
      count=split(platforms, values, ",")
      selected=0
      for (i=1; i<=count; i++) {
        values[i]=unquote(values[i])
        if (values[i] != "Darwin" && values[i] != "Linux") fail("unsupported platform")
        if (values[i] == platform) selected=1
      }
      if (selected) packages[++package_count]=name
    }
    /^[[:space:]]*(#.*)?$/ { next }
    /^go_tools:[[:space:]]*(#.*)?$/ { in_list=1; found=1; next }
    !in_list { next }
    {
      line=$0
      sub(/[[:space:]]+#.*$/, "", line)
      if (line ~ /^[^[:space:]]/) { finish(); record=0; in_list=0; next }
      if (line ~ /^[[:space:]]*-[[:space:]]*name:/) {
        finish()
        sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
        name=unquote(line); binary=""; platforms=""; record=1
      } else if (record && line ~ /^[[:space:]]*binary:/ && binary == "") {
        sub(/^[[:space:]]*binary:[[:space:]]*/, "", line); binary=unquote(line)
      } else if (record && line ~ /^[[:space:]]*platforms:/ && platforms == "") {
        sub(/^[[:space:]]*platforms:[[:space:]]*/, "", line); platforms=trim(line)
      } else {
        fail("unsupported entry syntax; use name, binary and inline platforms")
      }
    }
    END {
      finish()
      if (!found) fail("go_tools list is missing")
      if (failed) exit 1
      for (i=1; i<=package_count; i++) print packages[i]
    }
  ' "$manifest"
}
