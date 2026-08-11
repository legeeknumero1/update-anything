# Security policy

## Scope

`update-anything` invokes package managers, several of them through `sudo`. That
makes its argument handling and its confirmation logic security-relevant, and
they are the parts worth scrutinising.

Design constraints that exist for this reason:

- it refuses to run as root, so user-space managers are never run as root
- `--yes` skips only this script's own confirmations, never a package manager's
  prompts about replacement, removal or conflicting files
- destructive operations — orphan removal, cache cleanup, firmware — are opt-in
  flags and never run by default
- a package snapshot is written before anything is changed
- a lock directory prevents two instances racing each other

The full threat model is in the [README](README.md#5-threat-model).

## Reporting a vulnerability

Open a [security advisory](https://github.com/legeeknumero1/update-anything/security/advisories/new)
rather than a public issue. Expect a first response within a week.

Reports that are particularly welcome:

- a path where `--yes` suppresses a package manager's own destructive prompt
- command injection through a package name, a config value, or a hook
- a way to make the script run a user-space manager as root
- a webhook or hook execution path that leaks credentials into a log

## Not vulnerabilities here

Whatever your package managers do with the packages they install. This script
decides *when* and *whether* to invoke them; it does not vet their contents.

## Supported versions

The tip of `main`.
