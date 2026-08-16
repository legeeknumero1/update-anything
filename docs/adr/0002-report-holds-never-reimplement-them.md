# ADR 0002 — report package holds, never reimplement them

Status: accepted (2026-08-16)

## Context

A held-back package is invisible. `pacman` skips anything in `IgnorePkg`,
`apt` skips what `apt-mark hold` names, and neither says so in a way that
survives a wrapper's output. From the user's side the package simply never
moves, with nothing to explain why.

The obvious feature request is "let the updater hold packages too" — a list in
this tool's own config that it honours.

## Options considered

**A hold list in this tool's config.** Simple to write, and wrong. The
authority on whether a package is held is the manager that owns it. A second
list means two sources of truth that disagree the moment someone runs
`apt-mark unhold` — and the one that loses is the one the rest of the system,
including unattended-upgrades and the user's own manual commands, actually
obeys.

**Working around holds.** Trivially possible (`pacman -Syu --ignore=` and
friends) and a direct betrayal: the user recorded that decision deliberately,
often because upgrading breaks something.

**Reporting only.** Read each manager's own mechanism and print what it says.

## Decision

Read and report. `IgnorePkg` from `/etc/pacman.conf`, `apt-mark showhold`,
`dnf versionlock list`, `brew list --pinned`, `flatpak mask`. Never write to
any of them, never pass a flag that circumvents one.

Managers deselected with `--no-<manager>` are not consulted at all, not even
for their hold list: `--no-flatpak` has to mean flatpak is not touched, not
that it merely goes un-upgraded.

## Consequences

Setting a hold means using the manager's own command — one more thing the user
has to know, and a legitimate criticism of this decision.

In exchange, this tool can never be the reason a held package moved, and there
is no state here to drift out of sync with the system. The visibility problem,
which was the actual complaint, is solved without owning any of it.
