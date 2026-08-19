# ADR 0005 — `--yes` is unattended, or it is nothing

Status: accepted (2026-08-19)

## Context

Until 1.2.0, `--yes` answered this script's own confirmations and deliberately
stopped there. The reasoning was defensible on paper: a package manager's
prompt about removing or replacing a package is the last thing standing
between an automated run and a broken system, and a wrapper has no business
answering it.

The first real unattended run showed what that costs. With `-y`:

- `pacman -Syu` still asked `:: Proceed with installation? [Y/n]`
- `yay -Sua` asked four times — packages to exclude, packages to cleanBuild,
  diffs to show, then proceed — and answering "all" to the third printed nine
  hundred lines of a Chrome EULA into the terminal

Meanwhile the README offered `update-anything -y --quiet` as "what a cron
entry looks like". Both statements could not be true. In cron the managers
happen to read EOF on a closed stdin and fall back to their defaults, so it
mostly worked — by accident, not by design, and invisibly.

## Options considered

**Keep the guarantee, drop the claim.** Remove the cron example and document
`-y` as "fewer prompts, still interactive". Honest, and it abandons the only
use case that needed the flag.

**A second flag.** `--yes` for this script, `--noconfirm-managers` for the
rest. It keeps both behaviours and pushes the decision onto the user, which is
where it belongs — except that nobody automating a machine will type the first
without the second, so the pair is one flag with extra steps and a worse name.

**Depend on EOF.** Document that in cron, with no terminal, managers take
their defaults. This is relying on unspecified behaviour of six different
programs to produce the outcome we want, with no way to test it and no signal
when one of them changes its mind.

**Make `-y` mean what its name says.** Pass each manager its own
non-interactive flag, and be loud about it.

## Decision

`-y` passes the manager's own flag: `--noconfirm` (pacman, yay, paru, pikaur,
trizen, aurman), `--no-confirm` (pamac), `-y` (apt, dnf, yum, FreeBSD `pkg`,
`fwupdmgr`), `--non-interactive` (zypper), `-N` (MacPorts), `-I` (`pkg_add`).
Orphan removal and firmware updates are included; both prompt otherwise.

Two things keep this from being a quiet downgrade in safety:

Every `-y` run opens with a warning naming exactly what is being waived —
package removals, replacements, unreviewed AUR `PKGBUILD` changes — and says
to run without `-y` if the user is not certain. It is a warning, never a
prompt: a run started with `--yes` must not stop for anything, including a
question about whether it should stop.

Interactive mode is untouched. Without `-y`, no manager is handed a
non-interactive flag, and the test suite asserts the absence, not just the
presence.

## Consequences

The strongest safety claim this project made is gone, and the threat model
table says so rather than quietly dropping the row. What replaces it is
narrower and true: the dangerous mode is opt-in, named after what it does, and
announces itself.

The flag list is per-manager and hand-maintained. A manager added later that
prompts and is not given a flag turns `-y` back into a run that hangs — the
same shape of hazard as the ordering constraint in ADR 0004 and the allowlist
in ADR 0003. `CONTRIBUTING.md` names it in the checklist for adding a manager.
