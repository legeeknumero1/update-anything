# update-anything

[![CI](https://github.com/legeeknumero1/update-anything/actions/workflows/ci.yml/badge.svg)](https://github.com/legeeknumero1/update-anything/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/tests-20%20passing-brightgreen)](tests/run.sh)
[![ShellCheck](https://img.shields.io/badge/shellcheck-strict-brightgreen)](https://www.shellcheck.net/)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

A single portable bash script that updates every package manager actually
installed on the machine, on any Unix (Linux, macOS, FreeBSD, OpenBSD),
without assuming any of them are present.

## 1. Purpose

Running `update-anything.sh` detects the OS and probes for every supported
package manager with `command -v`. Whatever isn't installed is silently
skipped; whatever is installed gets checked for updates, previewed, and
(after confirmation) upgraded. Nothing is hardcoded as "the" package
manager for a given OS -- a machine with both Homebrew and MacPorts gets
both updated, a minimal container with only `apk` gets only `apk`.

Supported so far: `pacman` (+ AUR via yay/paru/pikaur/trizen/aurman/pamac),
`apt`, `dnf`, `yum`, `zypper`, `apk`, Homebrew, MacPorts, FreeBSD `pkg`,
OpenBSD `pkg_add`, Flatpak, Snap, Nix, `cargo` (auto-uses `cargo-binstall`
as a backend when present), `uv`, `pnpm`, `bun`, global `npm`, `pipx`.

## 2. Requirements

- `bash` (written against 3.2 syntax -- works with macOS's stock bash, no
  need for a newer one from Homebrew).
- `sudo` present if any detected manager needs root (most system package
  managers do; Homebrew, MacPorts on macOS, cargo, npm, pipx don't).
- `curl` recommended for the connectivity check (falls back to `wget`,
  then to bash's `/dev/tcp`).

## 3. Install

```
git clone https://github.com/legeeknumero1/update-anything && cd update-anything
./install.sh
update-anything --help
```

`install.sh` copies a local checkout into `~/.local/bin`. There is deliberately
no `curl | bash` one-liner: piping a remote script straight into a shell is a
poor habit to encourage, and doubly so for a tool that goes on to invoke package
managers through `sudo`. Clone it, read it, then install it.

`install.sh` also installs shell completions into whichever completion
directory it actually finds (bash-completion, an existing zsh `$fpath` dir,
fish) -- none are assumed present. Run `./install.sh --uninstall` to remove
the binary and any completions it installed.

Every push and pull request runs ShellCheck at its strictest level, a syntax
parse, the test suite on both Linux and macOS, and two gates that reject bash
4+ syntax and hardcoded home directories. See [Tests](#tests).

## 4. Advanced, opt-in features

Everything below is off by default. A plain `update-anything` run never
triggers any of it -- these exist for power users who explicitly ask for
them via a flag or by placing files in a specific directory.

- **`--snapshot`** -- creates a system-level restore point before touching
  anything, using the first tool found: `snapper`, `timeshift`, `bectl`
  (FreeBSD boot environments), a ZFS root dataset (detected via `findmnt`,
  not a hardcoded pool name), or `tmutil` on macOS. Still asks for
  confirmation even under `--snapshot`, since e.g. Timeshift can take
  several minutes and real disk space depending on its backend.
- **`--deep-clean`** -- prunes dev/container residue after updating:
  unused Flatpak runtimes, dangling Docker/Podman images, `cargo-cache`'s
  git/registry caches, Go's build/module cache. Each tool gets its own
  confirmation, same pattern as `--clean`/`--orphans`.
- **`--inhibit-sleep`** -- re-executes itself once under `systemd-inhibit`
  (Linux) or `caffeinate` (macOS) so a lid-close or idle timeout doesn't
  kill a long AUR build or Homebrew compile mid-way.
- **Hooks** -- executable scripts in
  `~/.config/update-anything/hooks.d/pre-update/` and `.../post-update/`
  run in filename order, as your own user (this script never elevates
  them). Same trust model as pacman hooks or shell rc files: whatever you
  put there, under your own `$HOME`, runs with your own permissions.
  Non-executable files are skipped with a warning rather than silently run.
- **Webhook** -- set `UPDATE_ANYTHING_WEBHOOK_URL` to a Discord/Slack-style
  webhook URL to get a one-line status ping (hostname + outcome) at the
  end of a run. Unset by default; nothing is ever sent anywhere unless you
  explicitly set this.
- Post-update, if `needrestart` is installed, the script lists services
  still holding outdated libraries in memory and offers to restart just
  those, instead of only flagging "reboot needed" for kernel updates.
- **Config file** -- `~/.config/update-anything/config`, if present, is
  sourced as shell code before CLI flags are parsed, so flags always win.
  Same trust model as hooks.d/ or your shell rc files -- it's real shell
  code, not a restricted `key=value` parser. Copy `config.example` from
  this repo to get started (`cp config.example ~/.config/update-anything/config`);
  it documents every available toggle. Example:
  ```
  DO_NOTIFY=1
  UPDATE_ANYTHING_WEBHOOK_URL="https://discord.com/api/webhooks/..."
  ```
- **`--audit`** -- runs `arch-audit` if present (a real system-wide CVE
  check against installed pacman packages). `cargo audit` only runs if a
  `Cargo.lock` exists in the current directory, since it's a project-level
  tool, not a system scanner -- `npm audit` isn't run at all for the same
  reason (no meaningful "global" mode). If neither applies, it says so
  instead of pretending to have audited anything.
- **`--rollback`** -- diffs the last two package-list snapshots and exits.
  This is intentionally just a diff, not an automated downgrade: generating
  a correct downgrade command per package (right cached version, right
  syntax per package manager) is a project of its own, not a flag.
- Metered-connection check (Linux only, via `nmcli`) warns before a large
  download if the active connection is flagged as metered (e.g. a phone's
  mobile hotspot). No macOS equivalent is faked -- there's no reliable CLI
  signal for "this is a hotspot" on macOS, so it's just not checked there.

## 5. Threat model

| Risk | Mitigation |
|---|---|
| Partial upgrade corrupts the system (Arch-class distros explicitly warn against this) | Always full `-Syu`/`full-upgrade`/`upgrade`, never a scoped package list |
| Script silently answers "yes" to a package manager's own destructive prompt (replace/remove/conflict) | `--yes` only skips *this script's* confirmations; `--noconfirm`/`-y` is never passed to pacman, apt, dnf, zypper, apk, yay, paru |
| Two instances run concurrently, race on the package DB | `mkdir`-based atomic lock (portable, no `flock` dependency) |
| Disk fills up mid-transaction | Aborts before starting if free space on `/` is critically low |
| Runs as root, breaking AUR helpers / Homebrew (which refuse to run as root) or masking `sudo`-scoped intent | Refuses to start as root; calls `sudo` itself only where a specific manager needs it |
| Silent data loss on orphan removal / cache cleanup | Both are opt-in flags (`--orphans`, `--clean`), always list what will be removed and ask for confirmation first |
| No way to know what changed if something breaks | Snapshot of installed packages + full timestamped log written before touching anything (`~/.local/share/update-anything/`, auto-purged after 30 days) |
| Offline run leaves package DBs half-synced | Aborts before starting if connectivity check fails |
| Laptop loses power mid-transaction, corrupting the package DB | Aborts if battery <10% and discharging (Linux `/sys/class/power_supply`, macOS `pmset`); warns under 20%. Silently skipped on desktops (no battery found) |
| Hooks execute arbitrary code | Hooks only run from a directory under the invoking user's own `$HOME`, as that user (never elevated); non-executable files are skipped with a warning instead of being run |
| Webhook silently exfiltrates data | Nothing is ever sent anywhere unless `UPDATE_ANYTHING_WEBHOOK_URL` is explicitly set; payload is just hostname + pass/fail status |
| A slow AUR/Homebrew build gets killed by the system sleeping | `--inhibit-sleep` wraps the run in `systemd-inhibit`/`caffeinate`, opt-in only (never silently re-execs itself unless asked) |
| `--snapshot` silently eats minutes/disk space | Still asks for confirmation even when the flag is passed; only ever tries one detected tool, never several |
| Config file could be mistaken for a safe declarative format | Documented plainly as real sourced shell code (same trust level as hooks.d/), not a restricted parser |
| `--rollback` misused as an automatic downgrade tool | Deliberately scoped to a diff only; no downgrade command is generated or run |

## Tests

```sh
./tests/run.sh              # 20 cases
./tests/run.sh safety       # only cases matching a name
```

Nothing in the suite updates anything. Each case runs the script against a
throwaway `HOME` with **stub package managers** on `PATH` — every "update" is a
shell script that records how it was called and exits 0, and `sudo` is stubbed
too, so the suite never elevates anything.

That is what makes the safety properties testable rather than merely asserted:
that `--check` queries without ever mutating, that `--no-<manager>` stops a
manager being consulted at all, that a second instance refuses to start, that
the lock is released on a clean exit.

CI runs the suite on **Ubuntu and macOS**. The macOS runner is not decoration:
this script is written to bash 3.2 because that is what macOS ships, and a
Linux-only pipeline cannot prove that claim. Two further gates fail the build on
bash 4+ syntax and on hardcoded home directories.

## Usage

```
update-anything --check          # dry run, changes nothing
update-anything                  # interactive full update
update-anything -y                # skip this script's own prompts
update-anything --clean --orphans # also clean cache / remove orphans (asks first)
update-anything --no-snap --no-brew
update-anything --snapshot --inhibit-sleep --deep-clean
update-anything --audit --check    # see known CVEs in installed packages, change nothing
update-anything --rollback         # diff the last two package snapshots
```

See `update-anything --help` for the full flag list.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.
