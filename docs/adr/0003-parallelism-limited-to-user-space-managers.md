# ADR 0003 — parallelism limited to user-space managers

Status: accepted (2026-08-16)

## Context

A full run is mostly waiting on the network. Nineteen managers checked one
after another is slower than the work requires, and the obvious answer is to
run them concurrently.

The obvious answer is also how you corrupt a package database.

## Options considered

**Everything in parallel.** Two system managers running at once is precisely
the failure this tool's locking exists to prevent — they contend for the same
package database, and on Arch `pacman` will refuse outright with a lock file
while the other holds it. Worse, several of them need `sudo`, and interleaved
password prompts from concurrent children are unusable even when they are not
dangerous.

**Nothing in parallel.** Correct, and what the tool did until now. It leaves
real time on the table for managers that provably cannot collide.

**A dependency graph of what can run with what.** Over-engineered for a set
that changes once a year and fits on one line.

## Decision

A fixed list, `PARALLEL_SAFE`, of managers that need no elevation and touch
entirely separate trees: `cargo`, `npm`, `pipx`, `uv`, `pnpm`, `bun`. Those run
concurrently. Everything else stays sequential.

The list is an allowlist, not a denylist, so a package manager added later is
sequential until someone deliberately argues it into the fast path.

Each parallel job writes to its own `${tmpdir}/${mgr}.out` and `.rc`; output is
replayed in a fixed order once they finish, and the exit status is carried back
through the `.rc` file — a subshell cannot set a variable in its parent, and a
failure that does not reach `FAILED_STEPS` is a failure the exit status lies
about.

## Consequences

Measured at 2s instead of 6s for three managers taking 2s each.

Output is no longer live for those managers: it appears in a block when each
one finishes. That is a real regression in a long `cargo install-update` run,
and `--no-parallel` exists for it.

The elevation boundary is doing double duty here — "needs no root" is also a
good proxy for "shares no state". If a future user-space manager breaks that
correlation, the list is the thing to revisit, not the mechanism.
