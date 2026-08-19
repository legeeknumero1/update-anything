# ADR 0004 — one sudo ticket, protected by the run order

Status: accepted (2026-08-19)

## Context

The tool asks for a password once, at the start, and expects the ticket to
still be there when `pacman -Syu` or `snap refresh` runs a few seconds later.
On the first machine with Homebrew installed, it was not: the password was
asked for twice, immediately, with nothing in between that could plausibly
have consumed it.

The cause is not in this tool. `Library/Homebrew/brew.sh` runs

```sh
"${SUDO}" --reset-timestamp 2>/dev/null || true
```

unconditionally, before dispatching any command. Every `brew` invocation —
including `brew list --versions`, which the package snapshot uses, and
`brew list --pinned`, which the holds report uses — destroys the caller's sudo
ticket as a side effect. Homebrew's reasoning is sound for Homebrew: it must
never inherit elevation it did not ask for. It is simply invisible to anything
that shares the terminal with it.

## Options considered

**Re-authenticate before each privileged step.** `sudo -n true || sudo -v`
ahead of every `sudo` command. It does not help: if the ticket is gone the
prompt happens either way, one line earlier. It buys a nicer label on the
prompt for real added complexity at a dozen call sites.

**Hide `sudo` from Homebrew.** Homebrew prefers `/usr/bin/sudo` by absolute
path, so this means shadowing the binary or running brew in a modified mount
namespace. Sabotaging another tool's security decision to work around it is
not a trade this project should make.

**Hold the ticket in the keepalive.** The keepalive re-runs `sudo -n true`,
which fails once the timestamp is reset, and it cannot re-authenticate without
a terminal. Nothing to hold.

**Order the run so the reset never falls inside the window.** The window that
matters runs from `warm_sudo` to the last privileged step. Keep every brew
invocation outside it.

## Decision

Ordering, in two places.

The package snapshot runs *before* `warm_sudo`, not after. It needs no
elevation, and it is the only pre-flight step that calls brew.

`brew` is registered *after* every manager that needs the ticket — after
`macports`, `flatpak` and `snap`, rather than in the middle of the system
managers where it looks like it belongs. The registration order is the
execution order, so this is the whole mechanism.

Separately, `warm_sudo` now verifies with one `sudo -n true` that the ticket it
just obtained was actually stored, and says so when it was not. A successful
`sudo -v` is not evidence of caching: `timestamp_timeout=0` authenticates and
keeps nothing.

## Consequences

The constraint is invisible in the code it constrains. Two lines that read as
arbitrary ordering are load-bearing, which is why both carry a comment naming
Homebrew and why `tests/run.sh` asserts the relative positions in the call log
rather than only that each command ran.

Any manager added later that needs `sudo` must be registered before `brew`.
The allowlist in ADR 0003 has the same shape of hazard: a list whose order
carries meaning that its contents do not advertise.

If Homebrew ever drops the reset, none of this becomes wrong — only
unnecessary.
