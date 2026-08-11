# Changelog

Notable changes, newest first. Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[1.0.0]: https://github.com/legeeknumero1/update-anything/releases/tag/v1.0.0
