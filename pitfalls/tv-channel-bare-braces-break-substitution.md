# Television channel previews show literal `{split:\t:N}` (bare braces in shell heredoc break the template parser)

**Symptoms** (grep this section): preview pane in a `tv` (television) channel
shows the **literal placeholder text** like `{split:	:2}`, `{split:	:1}`,
`{split:\t:N}` instead of the substituted value. Display row, header, and
actions all substitute correctly — only the preview body is affected. There is
**no error message anywhere** (no stderr, no `tv` log entry, no TOML parse
error).
**First seen**: 2026-04, television 0.15.6 on macOS, while building the
`agent-sessions` and `services` cable channels in this repo.
**Affects**: any cable channel where the `[preview]` (or `[actions.*]`)
`command = '''…'''` body contains a **bare `{...}` brace expression** that is
NOT a valid string-pipeline template — Python f-strings (`f'• {txt}'`),
Python empty-dict literals (`or {}`), shell brace-expansion examples in
comments, awk programs, JSON literals embedded in heredocs, etc.
**Status**: workaround documented (rewrite the inner script to avoid bare
braces). Not a TV bug per se — it's the documented behaviour of
[string-pipeline](https://docs.rs/string_pipeline/) (TV's templating engine),
but the silent-failure mode makes it extremely hard to diagnose.

## Symptom

A working channel like `agent-sessions` (TSV columns: `agent\twhen\tsid\tdir\ttitle`)
with a preview that drops into per-agent branches:

```toml
[preview]
command = [
  '''
  agent='{split:\t:0}'; sid='{split:\t:2}'; dir='{split:\t:3}'
  printf 'agent=%s sid=%s\n' "$agent" "$sid"
  case "$agent" in
    "[cc]")
      f=$(find "$HOME/.claude/projects" -name "${sid}.jsonl" | head -1)
      head -200 "$f" | python3 -c "
import sys, json
for line in sys.stdin:
  d = json.loads(line)
  m = d.get('message') or {}                 # <-- bare {} dict literal
  txt = (m.get('content') or '')[:300]
  print(f'• {txt}')                          # <-- bare {txt} f-string
"
      ;;
  esac
  ''',
]
```

renders in the preview pane as:

```
agent={split:	:0} sid={split:	:2}
```

— literal placeholders, never substituted. The header bar and display column
on the same row substitute correctly. Switching the source / picking a
different row makes no difference; cycling preview (`Ctrl+F`) to a second
preview command works only if THAT command happens not to contain bare braces.

## Root cause

TV uses [string-pipeline](https://docs.rs/string_pipeline/)'s `MultiTemplate`
parser to substitute `{...}` placeholders in `command` strings. The parser
walks the entire string looking for `{` and treats anything between matching
braces as a template expression like `{split:,:0}`, `{strip_ansi}`, etc.

When the parser hits a `{...}` chunk that is not a valid template (e.g. `{}`
or `{txt}` with no recognised operation), parsing of that **whole command
string fails silently** and TV emits the original string verbatim — so every
`{split:\t:N}` placeholder in the same string also stops being substituted.

There is no error log because TV is designed to be tolerant: a broken preview
command is supposed to "just" produce no output, not crash. Combined with the
fact that the brace expression usually lives deep inside an embedded Python
or awk program — visually unrelated to the placeholders at the top of the
shell snippet — the failure mode is invisible.

Confirmed by bisection: a minimal test channel with the same `'''…'''` block
substitutes correctly; adding back the original SQL (`||`, escaped quotes),
the ANSI escapes, the `case` statement, and the `find` command one at a time
keeps working — until the embedded Python f-string `print(f'• {txt}')` is
added back, at which point all `{split:\t:N}` go literal.

The two offending patterns in this repo's `agent-sessions` channel were:

| Bare-brace expression | Where | Looks like to TV |
|---|---|---|
| `m = d.get('message') or {}` | Python dict literal | empty template `{}` — invalid |
| `print(f'• {txt}')` | Python f-string | template `{txt}` — unknown op |

## Fix

Rewrite the inner shell/python/awk script to **avoid any literal `{...}` that
is not a string-pipeline template**.

| Bad | Good |
|---|---|
| `or {}` | `or dict()` |
| `f'• {txt}'` | `'• ' + txt` or `'• %s' % txt` or `'• {}'.format(txt)` (NB: `.format` itself is fine because the literal `{}` survives via the method call's positional binding — but the source string still contains `{}` → also breaks. Prefer `%` or `+` concatenation.) |
| `${var}` shell brace-expansion in **comments** | `$var` in comments, or remove the comment |
| awk `{print $1}` | move awk to a separate `executable_*.sh` helper script |
| JSON `{"k":"v"}` literal in heredoc | base64-encode the JSON, or use `printf '{' '"k":"v"' '}'` |

For the agent-sessions case the diff was:

```diff
-  m = d.get('message') or {}
+  m = d.get('message') or dict()
   c = m.get('content')
   ...
-  print(f'• {txt}')
+  print('  ' + txt)
```

After this fix, all placeholders in the same `command = '''…'''` string
substitute as expected. No need to escape the placeholders themselves; the
delimiter `\t` (literal 2 chars: backslash + lowercase-t) inside `{split:\t:N}`
works in both `"…"` and `'''…'''` TOML strings.

## How to detect proactively

Before deploying a new channel, grep the channel TOML for bare braces that are
NOT part of `{split:…}` / `{strip_ansi…}` / `{…|…}` / `{}` (the lone `{}`
which TV interprets as "the selected entry"):

```sh
rg -n '\{[^}]*\}' ~/.config/television/cable/<channel>.toml \
  | rg -v '\{(split|strip_ansi|trim|upper|lower|append|prepend|pad|substring|replace|regex_extract|filter|sort|reverse|unique|map|join|slice)' \
  | rg -v '\$\{' \
  | rg -v '\{\}'
```

Any line that survives all three filters is a candidate brace expression that
will silently break the template. Inspect it; if it's inside an embedded
language (Python / awk / etc.), rewrite to avoid braces or move the embedded
program into an external `executable_*.{py,sh}` helper file (see
`dot_config/television/executable_agent-sessions.py` for that pattern — the
helper is invoked from the TOML with `command = "agent-sessions.py all"` and
the channel TOML contains zero brace-laden code).

## Adjacent traps that look the same but aren't

1. **Real tab byte (0x09) inside the placeholder**: `{split:<TAB>:0}` (real
   tab, not `\t`) is rejected by the parser. Same literal-placeholder
   symptom. Fix: write `\t` (2 chars). This trap bit us first; the python
   "fix" script that "normalised" the file accidentally converted literal
   `\t` to a real tab. `od -c` on the deployed file is the diagnostic:
   look for `{   s   p   l   i   t   :  \t   :   0   }` — if you see `\t`
   between two `:` bytes, it's a real tab and broken; if you see two
   separate bytes `\` and `t`, it's correct.

2. **Display column missing a placeholder column referenced by preview**:
   was a red herring; TV substitutes preview placeholders independently of
   `display`. Confirmed by minimal test.

3. **`chezmoi apply` no-op'd silently** because the source mtime matched
   the target. Use `chezmoi apply --force <path>` while iterating, then
   verify with `od -c <deployed-path>`.

## References

- string-pipeline crate docs: <https://docs.rs/string_pipeline/0.12.0/string_pipeline/>
- TV channels guide (templating syntax): <https://alexpasmantier.github.io/television/user-guide/channels#templating-syntax>
- Repo channels using this pattern correctly:
  - `dot_config/television/cable/services.toml.tmpl` — multi-line preview, no embedded braces
  - `dot_config/television/cable/agent-sessions.toml` — fixed example
  - `dot_config/television/executable_agent-sessions.py` — preferred pattern: embed nothing, shell out to a helper
