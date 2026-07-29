# `Illegal instruction` in iSH for a binary that only uses SSE2

**Symptoms** (grep this section): `Illegal instruction` / `illegal instruction at 0x571b64ee: 66 0f 6a d0 66 0f 7e d0` / `illegal instruction at 0x56da8a42: 66 0f 72 f0 05 66 0f fe` / `Bad system call` when running `node`, `npm`, `rg`, `cargo`, `rustc` inside iSH on iOS; `nodejs and npm versions are not supported` when installing an agent CLI; `apk add` succeeded but the binary dies instantly
**First seen**: 2026-07 (this repo's investigation; upstream reports run 2018→2026)
**Affects**: iSH (iOS) any build incl. 812; Alpine i686 packages; anything built by Rust's `i686-*` targets; Node/V8
**Status**: WONTFIX-ish upstream — an 8-year open issue chain (ish-app/ish#90 → #917 → #1564 → #1724 → #2335 → #2604). Not reproduced on-device by us; derived from iSH sources + upstream reports.

## Symptom

A package installs cleanly and then refuses to run:

```
localhost:~# apk add nodejs
(1/4) Installing nodejs (...)
OK: 142 MiB in 61 packages
localhost:~# node --version
Illegal instruction
```

`dmesg` inside iSH shows the offending opcode bytes:

```
illegal instruction at 0x571b64ee: 66 0f 6a d0 66 0f 7e d0
illegal instruction at 0x56da8a42: 66 0f 72 f0 05 66 0f fe
```

Older reports show `Bad system call` instead. Installing an agent CLI reports:

```
nodejs and npm versions are not supported
```

Also hits `ripgrep` (`rg`), `cargo`, `rustc` — i.e. things you would not
suspect of using SIMD at all.

## Root cause

**Not** "iSH lacks SSE2". That is the intuitive diagnosis and it is wrong.

iSH's CPUID leaf 1 *does* advertise `fpu|cmov|mmx|sse2` (ECX = 0, max leaf 1 —
so no SSE3/SSSE3/SSE4/POPCNT/AES-NI/AVX, and no leaf 7, so no BMI/AVX2).

The traps come from somewhere else: `emu/decode.h` has 31 `UNDEFINED` points
and `asbestos/gen.c` has NULL gadget slots. **A perfectly legal instruction,
inside the advertised baseline, still raises SIGILL if its host gadget is
unimplemented.** Proof by extreme example: `LOOP` (0xE0/0xE1/0xE2, an 8086-era
instruction) was still unimplemented at build 812. The SSE2 instruction
`PMULLW` has its own SIGILL report (ish-app/ish#1417).

Decoding the bytes above confirms the family but not the diagnosis:

| Bytes | Instruction | Set |
|---|---|---|
| `66 0f 6a d0` | `PUNPCKHDQ xmm2, xmm0` | SSE2 |
| `66 0f 7e d0` | `MOVD eax, xmm2` | SSE2 |
| `66 0f 72 f0 05` | `PSLLD xmm0, 5` | SSE2 |
| `66 0f fe` | `PADDD` | SSE2 |

They are all *inside* the advertised baseline. They trap anyway.

Why the blast radius is wide:

- **V8** emits `cvtdq2pd` among others, so every Node version dies. A patch
  exists only in an unmerged personal fork (`d0309a5`, ahead 1 / behind 51, no
  PR opened).
- **Rust's `i686-*` targets assume SSE2** by default (rust-lang/rust#114479),
  so Rust CLIs are affected even when the program has no SIMD of its own —
  see ish-app/ish#805, titled `Illegal instruction in rust programs: paddd`.
- **Go** binaries hit a separate but equally fatal problem: a race condition
  that hangs forever (ish-app/ish#1230, from an iSH contributor: *"The go
  language currently triggers some sort of race condition in iSH which causes
  it to lock up forever. It's easy to reproduce."*). `chezmoi` is Go.

## Workaround

There is none for the affected binaries. Do not chase it:

- **Do not upgrade Alpine to `edge` hoping for a fixed build.** Alpine formally
  raised the x86 baseline to SSE2 and builds `-march=pentium-m`
  ([alpine-users list](https://lists.alpinelinux.org/~alpine/users/%3CCTQBXQ3S98WX.167V56IKQX4EI%40sumire%3E):
  *"if you are using edge, and you have a CPU without sse2, then the hardware
  will most likely not work with alpine linux anymore"*). That makes things
  strictly worse — more of userland moves into the unimplemented range.
- **Do not downgrade Node.** ish-app/ish#1564 shows
  `apk add nodejs-current==15.10.0-r0 --force` still trapping.
- Stop at **Alpine 3.18**; 3.19 crashes `sudo` and segfaults `uptime` via
  `procps`, 3.20's `coreutils` breaks `/dev`.

Run the workload elsewhere and use iSH as an SSH client — see
[`docs/playbooks/ios-terminals.md`](../docs/playbooks/ios-terminals.md).

## Prevention

**The generalisable lesson: on iSH you cannot predict whether a binary runs by
reasoning about its instruction set.** "This only needs SSE2, and iSH has SSE2"
is not a valid argument. The only reliable test is running it.

Corollary for triage: when something dies in iSH, check `dmesg` for the opcode
bytes before assuming a missing CPU feature — an unimplemented gadget for a
supported instruction looks identical from userspace.

Also note the second, larger wall that makes all of this moot for agent CLIs:
iOS forbids `fork`/`exec` of arbitrary binaries, so `child_process` is
unavailable regardless of CPU. See the ios-terminals playbook.

## Related

- [`docs/playbooks/ios-terminals.md`](../docs/playbooks/ios-terminals.md) — full
  platform analysis and the recommended stack
- [`pitfalls/ish-tmux-ctrl-digit-dead-wrong-binding.md`](ish-tmux-ctrl-digit-dead-wrong-binding.md)
  — the other iSH trap, also a false-positive capability report
- [`docs/glibc-and-musl.md`](../docs/glibc-and-musl.md)
- Upstream: ish-app/ish#90, #805, #917, #1230, #1417, #1564, #1724, #2335,
  #2604; rust-lang/rust#114479; astral-sh/uv#2732 (closed not-planned)
