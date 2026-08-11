# Changelog

Notable changes, newest first. Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-08-11

### Added

- **20-case test suite** running the script against stub package managers in a
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

[1.0.1]: https://github.com/legeeknumero1/update-anything/releases/tag/v1.0.1
[1.0.0]: https://github.com/legeeknumero1/update-anything/releases/tag/v1.0.0
