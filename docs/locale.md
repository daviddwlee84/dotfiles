# Linux Locale Configuration

## What is a Locale?

A locale defines language, regional formatting, and character encoding preferences for a system. It affects how programs display text, sort strings, format dates/numbers/currency, and handle character encodings.

## Locale Categories

Each category controls a specific aspect of localization:

| Variable | Controls | Example Effect |
|----------|----------|----------------|
| `LANG` | Default for all categories | Base fallback locale |
| `LC_CTYPE` | Character classification, case conversion | What counts as a letter, `toupper()` behavior |
| `LC_COLLATE` | String sorting order | `sort` ordering (e.g. `a < B` vs `A < a < B`) |
| `LC_MESSAGES` | Language of system messages | Error messages in English vs Chinese |
| `LC_NUMERIC` | Number formatting | `1,234.56` (US) vs `1.234,56` (DE) |
| `LC_TIME` | Date/time formatting | `04/16/2026` vs `16.04.2026` |
| `LC_MONETARY` | Currency formatting | `$1,234` vs `1.234 €` |
| `LC_PAPER` | Default paper size | Letter (US) vs A4 (EU) |
| `LC_NAME` | Name formatting conventions | Given-name-first vs family-name-first |
| `LC_ADDRESS` | Address formatting | Country-specific postal format |
| `LC_TELEPHONE` | Phone number formatting | Country code conventions |
| `LC_MEASUREMENT` | Measurement system | Imperial vs metric |
| `LC_IDENTIFICATION` | Locale metadata | Locale's own description |
| `LC_ALL` | **Overrides ALL above** | Nuclear option — sets everything at once |
| `LANGUAGE` | GNU gettext message priority list | Fallback chain for translations |

**Note**: Locale does **not** control timezone. Timezone is set via `TZ` env var or `/etc/timezone`.

## Priority Order

When a program checks locale for a specific category:

```
LC_ALL  →  LC_<CATEGORY>  →  LANG
(highest)                     (lowest)
```

- `LC_ALL` overrides everything — if set, individual `LC_*` vars are ignored
- Individual `LC_*` vars override `LANG` for their specific category
- `LANG` is the default fallback

**Best practice**: Set `LANG` to your preferred locale. Use individual `LC_*` only for selective overrides. Avoid `LC_ALL` in permanent config — it's meant for one-off commands.

## Common Locale Values

| Locale | Description |
|--------|-------------|
| `C` or `POSIX` | Minimal ASCII locale, no UTF-8, fastest |
| `C.UTF-8` | ASCII sorting + UTF-8 encoding (safe universal default) |
| `en_US.UTF-8` | US English with UTF-8 |
| `en_GB.UTF-8` | British English with UTF-8 |
| `zh_TW.UTF-8` | Traditional Chinese (Taiwan) with UTF-8 |
| `ja_JP.UTF-8` | Japanese with UTF-8 |

The format is: `language_TERRITORY.ENCODING`

## Checking Current Locale

```bash
# Show all locale variables
locale

# List all installed/generated locales
locale -a

# Check if a specific locale exists
locale -a | grep en_US
```

## Generating Locales (Debian/Ubuntu)

A locale must be **generated** before it can be used. If `LC_ALL=en_US.UTF-8` is set but the locale isn't generated, every command will print warnings:

```
locale: Cannot set LC_CTYPE to default locale: No such file or directory
locale: Cannot set LC_ALL to default locale: No such file or directory
```

### Fix: Generate the Missing Locale

```bash
# Method 1: Uncomment in /etc/locale.gen and generate
sudo sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sudo locale-gen

# Method 2: Generate directly (Debian/Ubuntu)
sudo locale-gen en_US.UTF-8

# Method 3: Interactive reconfiguration
sudo dpkg-reconfigure locales
```

### Set System Default Locale

```bash
# Persistent default (writes to /etc/default/locale)
sudo update-locale LANG=en_US.UTF-8

# Or edit directly
echo 'LANG=en_US.UTF-8' | sudo tee /etc/default/locale
```

## Where Locale is Set

| Source | Scope | File |
|--------|-------|------|
| System default | All users | `/etc/default/locale` |
| PAM (login) | Login sessions | `/etc/pam.d/common-session` reads `/etc/default/locale` |
| SSH `SendEnv` | Remote sessions | Client's `~/.ssh/config` or `/etc/ssh/ssh_config` |
| SSH `AcceptEnv` | Remote sessions | Server's `/etc/ssh/sshd_config` |
| Shell profile | Current user | `~/.bashrc`, `~/.zshrc`, `~/.profile` |
| Systemd | Services | `DefaultEnvironment=` in `/etc/systemd/system.conf` |

### SSH Locale Forwarding (Common Gotcha)

SSH clients often forward the local machine's `LC_*` variables to the remote host. If your local machine has `LC_ALL=en_US.UTF-8` but the remote server hasn't generated that locale, you'll see locale warnings on every SSH command.

The flow:
```
Local: LC_ALL=en_US.UTF-8 → SSH SendEnv LC_* → Remote: tries en_US.UTF-8 → not generated → warnings
```

**Fix options:**

1. Generate the locale on the remote server (see above)
2. Stop forwarding: remove `SendEnv LANG LC_*` from local `/etc/ssh/ssh_config`
3. Stop accepting: remove `AcceptEnv LANG LC_*` from remote `/etc/ssh/sshd_config`
4. Override in shell profile on remote: `export LC_ALL=C.UTF-8`

## Impact on Tools

### Python / Ansible

Python's `locale.setlocale()` will raise an error if the requested locale doesn't exist. Ansible specifically requires UTF-8 encoding:

```
ERROR: Ansible could not initialize the preferred locale: unsupported locale setting  # locale missing
ERROR: Ansible requires the locale encoding to be UTF-8; Detected None.              # LC_ALL=C (no UTF-8)
```

**Safe fallback for scripts**: `export LC_ALL=C.UTF-8`

### Sorting (coreutils)

```bash
# C locale: ASCII byte order (A-Z before a-z)
LC_COLLATE=C sort <<< $'banana\nApple\napricot'
# → Apple, apricot, banana

# en_US locale: case-insensitive dictionary order
LC_COLLATE=en_US.UTF-8 sort <<< $'banana\nApple\napricot'
# → Apple, apricot, banana  (may vary)
```

### Regular Expressions

`[a-z]` in `C` locale matches only lowercase ASCII. In `en_US.UTF-8`, it may include accented characters. Use `[[:lower:]]` for portable behavior.

## Raspberry Pi Notes

Raspberry Pi OS often has `LC_ALL=en_US.UTF-8` set (via SSH forwarding or default config) without the locale actually generated. The kernel may report `aarch64` while the userland is 32-bit `armhf`, but this doesn't affect locale — locale is purely a userland concept.

Quick fix for RPi locale warnings:

```bash
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8
```

## This Dotfiles Repo

The bootstrap script (`run_once_before_00_bootstrap.sh.tmpl`) detects broken locales and falls back to `C.UTF-8` before running Ansible. The ansible onchange script (`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`) unconditionally exports `LC_ALL=C.UTF-8` for the same reason.
