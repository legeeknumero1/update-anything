# Changelog

Notable changes, newest first. Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] — 2026-08-19

Everything here came out of the first real (non-`--check`) run on a live
machine. `--check` never requests sudo, so the test suite had never once
exercised that path — and it accounts for most of what follows.

### Fixed

- **The parallel block waited on the sudo keepalive.** `wait` with no
  arguments waits for *every* background job of the shell, and `warm_sudo`
  starts a `while true` keepalive that by design never exits on its own. The
  parallel phase therefore blocked until sudo's timestamp lapsed: 28 seconds
  of dead time on the run that exposed it, and on a machine whose timestamp
  keeps being refreshed it would never return at all. Each child's PID is now
  waited on individually.
- **A step could stop and ask a question that was never displayed.** A
  backgrounded step has its stdout and stderr redirected to a file, and
  `read -p` writes its prompt to stderr — so a manager with something to
  confirm asked into the file, and the run stopped at a bare cursor. Every
  parallel job also shares one stdin, so even a visible prompt would have been
  answered by whichever child read the keystroke first. Managers now run
  concurrently only under `--yes` or `--check`, the two cases where no step
  can prompt.
- **The parallel phase was written to the log twice**, the second copy still
  carrying its terminal escape codes. The children already append to the log
  directly and `run_step` tees the command's own output; the captured stdout
  was appended on top of both.
- **`.pacnew` files were listed on the terminal but never logged.** The
  warning ended with a colon and nothing followed it in the log — the one
  place you would look afterwards to find out which config files need
  merging.
- **Step timings never reached the log**, and `--quiet` dropped them entirely.
  The cron case, the only one where nobody watches it happen, was the case
  that lost them.
- **The password was asked for twice on any machine with Homebrew installed.**
  `warm_sudo` took the ticket, and the very next thing the run did was
  `brew list --versions` for the package snapshot. Every Homebrew invocation
  execs `sudo --reset-timestamp` before doing anything else, so the ticket was
  destroyed a fraction of a second after it was obtained, and the first
  privileged step prompted again — with the keepalive dying on its next
  iteration for the same reason. Two ordering changes fix it: the snapshot is
  taken before credentials are requested, and `brew` is now registered after
  every manager that needs the ticket rather than before `flatpak` and `snap`.
- **A successful `sudo -v` was treated as proof the credentials were kept.**
  It is not: with `timestamp_timeout=0` in sudoers, or a policy plugin that
  declines to cache, sudo authenticates and stores nothing — leaving a
  keepalive spinning for a minute with nothing to keep alive and no
  explanation for the repeated prompts. `warm_sudo` now asks sudo directly,
  with one non-interactive `sudo -n true`, and says so plainly when that is
  the answer.

### Testing

The suite now covers a real `--yes` run rather than only `--check`, which is
what makes the sudo path reachable at all. Eight new cases, and one fix to
the harness itself: sandbox utilities were resolved with `command -v`, which
answers with the builtin's name for `true`, `printf` and `kill` — the symlink
dangled, so the stub `sudo -n true` failed, the keepalive died on its first
iteration, and the hang could not reproduce. `type -P` resolves the binary.

Verified by putting each bug back and watching the new test fail.

## [1.1.0] — 2026-08-16

### Added

- **Held packages are reported before updating.** Packages your package manager
  has been told to hold back — `pacman` `IgnorePkg`, `apt-mark hold`, `dnf
  versionlock`, `brew pin`, `flatpak mask` — are listed at the start of a run.
  The script never adds or overrides a hold: that state belongs to the manager
  that owns it. It simply stops a package that never moves from being a
  mystery. Deselected managers are not consulted at all.
- **User-space managers run in parallel.** `cargo`, `npm`, `pipx`, `uv`, `pnpm`
  and `bun` need no elevation and touch separate trees, so they now run
  concurrently — measured at 2s instead of 6s for three managers taking 2s
  each. System managers deliberately stay sequential: they share a package
  database and a sudo ticket. `--no-parallel` restores the old behaviour when
  you want readable live output.
- **`--only <manager>`**, the inverse of `--no-<manager>`. Repeatable and
  comma-separated, and authoritative when both are given.
- **`-q`/`--quiet`**: only warnings and errors reach the terminal, while the
  log keeps everything. With the exit-status fix below, that is what makes this
  usable from cron — silent when it worked, loud when it did not.
- **Per-step timings** in the summary, longest first, so it is obvious what to
  skip next time.

### Changed

- **Long pending-update lists are folded.** A routine upgrade on a
  Haskell-heavy repo prints 250 lines of version bumps, pushing every
  pre-flight result and the summary out of the scrollback — the part worth
  reading is the part that scrolls away. The terminal now gets the first 20
  lines and a count of the rest; the log still gets every line, and `--full`
  prints them all. Measured on a real run: 326 lines of output down to 80.
- `brew update` is called with `--quiet`, which drops the "New Formulae" and
  "New Casks" listing it prints in full on every single run — forty-odd lines
  about packages nobody asked about, ahead of the handful that are actually
  outdated. Nothing else about brew's output changes.

### Project

- A demo GIF of a real `--check` run, and an AUR `PKGBUILD`.
- `CONTRIBUTING.md` now walks through the four places adding a package manager
  touches, with a worked example.

## [1.0.1] — 2026-08-11

### Added

- **23-assertion test suite** running the script against stub package managers in a
  throwaway `HOME`, so its safety properties are verified rather than asserted:
  that `--check` queries without mutating, that `--no-<manager>` stops a manager
  being consulted at all, that a second instance refuses to start, that the lock
  is released on a clean exit.
- **CI on macOS as well as Linux.** The script is written to bash 3.2 because
  that is what macOS ships; only a macOS runner proves the claim.
- **A portability gate** failing the build on `declare -A`, `mapfile`,
  `${var,,}` or `local -n`, and another rejecting hardcoded home directories.
- `CONTRIBUTING.md`, `SECURITY.md`, this changelog, issue and pull request
  templates, and an `.editorconfig`.

### Fixed

- **`--check` always exited 1, even on complete success.** The script's last
  statement was `[[ "$CHECK_ONLY" -eq 0 ]] && send_webhook`, and the `EXIT` trap
  propagates `$?` — so under `--check` the short-circuit decided the exit status.
- **A run with failed steps exited 0.** The same line, from the other side: on a
  normal run `send_webhook` succeeded and became the status, so three failed
  package managers still reported success. Anything scripting this — cron, CI,
  a `&&` chain — could not tell an update apart from a failure. The status is
  now set explicitly: zero only when every requested step succeeded.
- **The sudo keepalive outlived the script.** `cleanup` killed the keepalive
  subshell but not the `sleep 60` already running inside it, leaving an orphan
  process for up to a minute after exit; the same single long sleep meant a
  killed script kept its keepalive for just as long. It now sleeps in
  one-second steps, so both windows are a second.
- **CI was red on `main`.** Three ShellCheck warnings failed the only workflow
  run since the initial release. Two were real (`SC2155`, masking a return value
  by declaring and assigning together); the rest are deliberate and now carry an
  inline disable explaining why — `ls -t` because sorting by mtime portably is
  exactly what `find` cannot do on macOS and the BSDs, word-splitting a package
  list because that is the intent, and `COMPREPLY=( $(compgen …) )` because
  `mapfile` does not exist in bash 3.2.

### Changed

- ShellCheck now runs at `-S style`, its strictest level, instead of the default.

## [1.0.0] — 2026-08-04

Initial release: OS and package manager auto-detection, per-manager skip flags,
`--check`, package snapshots, opt-in cleanup and firmware steps, shell
completions for bash, zsh and fish, and an installer.

[1.1.1]: https://github.com/legeeknumero1/update-anything/releases/tag/v1.1.1
[1.1.0]: https://github.com/legeeknumero1/update-anything/releases/tag/v1.1.0
[1.0.1]: https://github.com/legeeknumero1/update-anything/releases/tag/v1.0.1
[1.0.0]: https://github.com/legeeknumero1/update-anything/releases/tag/v1.0.0
