#!/usr/bin/env bash
# Backward-compatibility shim: forwards all arguments to redact_secrets.py
# scoped to the .specstory/history prefix. Prefer calling redact_secrets.py
# directly; this shim exists for muscle memory and older docs.
exec "$(dirname "$0")/redact_secrets.py" --paths .specstory/history "$@"
