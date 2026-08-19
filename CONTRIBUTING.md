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

## Adding a package manager

The most common change, and it touches four places. Take `flatpak` as the
worked example.

**1. Detection.** One line in `detect_managers()`, and it must be a probe, never
an assumption about the platform:

```bash
command -v flatpak >/dev/null 2>&1 && MANAGERS+=("flatpak")
```

If the binary name and the manager name differ (`apt-get` → `apt`), the
`MANAGERS` entry is what every flag and message uses.

**2. The step.** A `step_<name>()` function — dispatched by name, so `flatpak`
means `step_flatpak`. It has to honour `CHECK_ONLY` by returning before it
mutates anything, ask through `confirm` before it does, and hand the real work
to `run_step` so failures are recorded without aborting the run:

```bash
step_flatpak() {
  info "Checking flatpak updates..."
  [[ "$CHECK_ONLY" -eq 1 ]] && { flatpak remote-ls --updates; return 0; }
  confirm "Apply flatpak updates?" || { warn "Skipped flatpak by user choice."; return 0; }
  run_step "flatpak update" flatpak update
}
```

Long pending lists go through `preview_list` rather than a bare `echo`, so the
terminal stays readable and the log stays complete.

Registration order matters and is not obvious: a manager that needs `sudo` has
to be registered **before** `brew`, which drops the sudo ticket on every
invocation — see [ADR 0004](docs/adr/0004-one-sudo-ticket-owned-by-the-run-order.md).

**3. Completions.** All three: `completions/update-anything.bash`,
`completions/_update-anything`, `completions/update-anything.fish`. `--no-<name>`
is generic in the parser, but it still has to be listed to be completable.

**4. A test.** At minimum that `--check` does not mutate and that `--no-<name>`
suppresses it entirely. `new_sandbox flatpak` gives you a stub that records how
it was called:

```bash
run_in "$home" --check --yes >/dev/null 2>&1
assert_absent_from "$(calls_in "$home")" "flatpak update" "never told to update"
```

Then the README's supported list, and a `CHANGELOG.md` entry under
`## [Unreleased]`.

## Commits

Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, `refactor:`). Say in the
body what was wrong and why the fix has the shape it has.
