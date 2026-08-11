# Contributing

The most useful contribution is a report from a platform I cannot test on.
Development happens on Arch-based Linux; macOS, the BSDs, and the less common
package managers are written from documentation and verified against stubs, not
against the real thing.

## Running the tests

```sh
./tests/run.sh              # everything
./tests/run.sh safety       # only cases whose name contains "safety"
```

Nothing in the suite updates anything. Each case runs the script against a
throwaway `HOME` with **stub package managers** on `PATH` — every "update" is a
shell script that records how it was called and exits 0. That is what makes the
interesting properties testable: that `--check` never mutates, that
`--no-<manager>` stops a manager being consulted at all, that a second instance
refuses to start.

`sudo` is stubbed too, so the suite never elevates anything.

## What CI enforces

All of it runs locally:

```sh
shellcheck -S style update-anything.sh install.sh tests/run.sh completions/update-anything.bash
for f in update-anything.sh install.sh tests/run.sh; do bash -n "$f"; done
./tests/run.sh
```

Tests run on both Ubuntu and macOS. The macOS runner is not decoration — see
below.

## House rules

**bash 3.2, no exceptions.** macOS still ships bash 3.2, so no associative
arrays, no `mapfile`/`readarray`, no `${var,,}`, no `local -n`. CI fails the
build if any appear. If you need one of them, you need a different approach.

**Never assume a package manager exists.** Detect it, then use it. The script's
whole premise is that it updates what is actually installed and nothing else.

**Never force through a manager's own destructive prompts.** `--yes` skips
*this script's* confirmations. Package replacement, removal and conflicting
files stay interactive, because that is the point at which a user needs to be
looking.

**One manager failing must not abort the others.** A broken tap or an unreachable
mirror should cost you that manager, not the run.

**Destructive extras stay opt-in.** Orphan removal, cache cleanup and firmware
are flags, never defaults.

**Explain the why, not the what.** A comment restating the code is noise. One
explaining why the portable form was chosen over the obvious one is what stops
someone "simplifying" it back.

## Commits

Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, `refactor:`). Say in the
body what was wrong and why the fix has the shape it has.
