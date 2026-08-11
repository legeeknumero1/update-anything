#!/usr/bin/env bash
#
# update-anything test suite.
#
# No framework, and nothing here updates anything. The script's whole job is to
# invoke package managers with elevated privileges, so the suite runs it against
# a throwaway HOME with stub package managers on PATH: every "update" is a shell
# script that records the arguments it was called with and exits 0.
#
# That is what makes the interesting properties testable at all — that --check
# queries without ever mutating, that --no-<manager> stops a manager being
# consulted at all, that a second instance refuses to start, and that the lock
# is released on a clean exit.
#
# Written to the same bash 3.2 baseline as the script under test.
#
# Usage: tests/run.sh [name-filter]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT
readonly SCRIPT="$ROOT/update-anything.sh"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    readonly GREEN=$'\033[32m' RED=$'\033[31m' DIM=$'\033[2m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    readonly GREEN='' RED='' DIM='' BOLD='' RESET=''
fi

PASSED=0
FAILED=0
FILTER="${1:-}"
SANDBOX=""

# --- Harness ----------------------------------------------------------------

fail() { printf '    %s✗%s %s\n' "$RED" "$RESET" "$1"; FAILED=$((FAILED + 1)); }
pass() { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASSED=$((PASSED + 1)); }

assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else
        fail "$3"
        printf '      expected: %s\n      actual:   %s\n' "$2" "$1"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass "$3" ;;
        *) fail "$3"; printf '      looked for: %s\n' "$2" ;;
    esac
}

assert_absent_from() {
    case "$1" in
        *"$2"*) fail "$3"; printf '      unexpectedly present: %s\n' "$2" ;;
        *) pass "$3" ;;
    esac
}

assert_exists() { if [ -e "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi; }

# Utilities the script legitimately needs. The sandbox PATH is built from this
# list alone, so the host's real package managers are unreachable: inheriting
# /usr/bin meant a test machine with pacman installed actually ran pacman, and
# the result depended on what happened to be installed on it.
readonly SANDBOX_UTILS="bash sh date uname df awk sed grep find tee mkdir rmdir rm \
cat cut head tail wc sort uniq diff hostname sleep kill tr basename dirname \
mktemp chmod ls printf touch env id xargs"

# A throwaway HOME plus stub package managers. Each stub appends its arguments
# to a call log, so a test can assert both that a manager ran and how.
new_sandbox() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/sysbin" "$SANDBOX/.config"

    local util path
    for util in $SANDBOX_UTILS; do
        path="$(command -v "$util" 2>/dev/null)" || continue
        [ -n "$path" ] && ln -sf "$path" "$SANDBOX/sysbin/$util"
    done

    local mgr
    for mgr in "$@"; do
        cat > "$SANDBOX/bin/$mgr" <<EOF
#!/bin/sh
echo "$mgr \$*" >> "$SANDBOX/calls.log"
exit 0
EOF
        chmod +x "$SANDBOX/bin/$mgr"
    done

    # sudo must not actually elevate during tests: it simply runs what follows.
    cat > "$SANDBOX/bin/sudo" <<EOF
#!/bin/sh
[ "\$1" = "-v" ] && exit 0
[ "\$1" = "-n" ] && shift
exec "\$@"
EOF
    chmod +x "$SANDBOX/bin/sudo"

    # A curl that always succeeds, so the connectivity pre-flight passes
    # without the suite depending on a working network — and, more to the
    # point, without it reaching one.
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/curl"
    chmod +x "$SANDBOX/bin/curl"

    # No pacman lock to find, and no processes to inspect.
    printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/pgrep"
    chmod +x "$SANDBOX/bin/pgrep"

    : > "$SANDBOX/calls.log"
    echo "$SANDBOX"
}

drop_sandbox() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; SANDBOX=""; }

# GNU timeout is not on macOS or the BSDs, where it is gtimeout from coreutils
# and often absent entirely. It is a guard against a hung test, not something
# the suite depends on, so it is used when present and skipped when not —
# hardcoding it made every macOS assertion fail with no output at all.
# Resolved to an absolute path deliberately: run_in wipes the environment with
# env -i and hands it a PATH containing only the sandbox, so env would look for
# a bare "timeout" there and fail with the command never running at all.
TIMEOUT_CMD=""
if _t="$(command -v timeout 2>/dev/null)" && [ -n "$_t" ]; then
    TIMEOUT_CMD="$_t 60"
elif _t="$(command -v gtimeout 2>/dev/null)" && [ -n "$_t" ]; then
    TIMEOUT_CMD="$_t 60"
fi
unset _t
readonly TIMEOUT_CMD

# Nothing from the host leaks in: no real PATH, no XDG pointing at real state.
run_in() {
    local home="$1"; shift
    # shellcheck disable=SC2086  # TIMEOUT_CMD is a command plus its argument
    env -i \
        HOME="$home" \
        PATH="$home/bin:$home/sysbin" \
        TMPDIR="$home/tmp" \
        NO_COLOR=1 \
        $TIMEOUT_CMD bash "$SCRIPT" "$@"
}

calls_in() { cat "$1/calls.log" 2>/dev/null; }

describe() {
    if [ -n "$FILTER" ]; then
        case "$1" in *"$FILTER"*) ;; *) return 1 ;; esac
    fi
    printf '\n  %s%s%s\n' "$BOLD" "$1" "$RESET"
    return 0
}

# --- Interface --------------------------------------------------------------

test_version() {
    describe "interface: --version" || return 0
    local home out
    home="$(new_sandbox)"; mkdir -p "$home/tmp"
    out="$(run_in "$home" --version 2>&1)"
    assert_contains "$out" "update-anything v" "prints a version string"
    drop_sandbox
}

test_help() {
    describe "interface: --help" || return 0
    local home out
    home="$(new_sandbox)"; mkdir -p "$home/tmp"
    out="$(run_in "$home" --help 2>&1)"
    assert_contains "$out" "--check" "documents --check"
    assert_contains "$out" "--yes" "documents --yes"
    drop_sandbox
}

test_unknown_flag_rejected() {
    describe "interface: an unknown flag is refused" || return 0
    local home out rc
    home="$(new_sandbox)"; mkdir -p "$home/tmp"
    out="$(run_in "$home" --definitely-not-a-flag 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "exits non-zero"
    else
        fail "accepted an unknown flag"
    fi
    assert_contains "$out" "nknown" "says which flag it did not understand"
    drop_sandbox
}

# --- Safety properties ------------------------------------------------------

test_check_only_mutates_nothing() {
    describe "safety: --check queries but never mutates" || return 0
    local home
    home="$(new_sandbox pacman flatpak npm)"; mkdir -p "$home/tmp"

    run_in "$home" --check --yes >/dev/null 2>&1

    # Read-only queries are expected and fine; the mutating forms are not.
    local calls; calls="$(calls_in "$home")"
    assert_absent_from "$calls" "flatpak update" "flatpak was never told to update"
    assert_absent_from "$calls" "pacman -Syu" "pacman never ran a full upgrade"
    assert_absent_from "$calls" "npm update" "npm never updated anything"
    drop_sandbox
}

test_skip_flag_suppresses_manager() {
    describe "safety: --no-<manager> suppresses only that manager" || return 0
    local home
    home="$(new_sandbox flatpak npm)"; mkdir -p "$home/tmp"

    run_in "$home" --check --yes --no-flatpak >/dev/null 2>&1

    # Not even the read-only query: a skipped manager is not consulted at all.
    local calls; calls="$(calls_in "$home")"
    assert_absent_from "$calls" "flatpak" "the skipped manager was not invoked at all"
    drop_sandbox
}

test_refuses_to_run_as_root() {
    describe "safety: refuses to run as root" || return 0
    # EUID is readonly in bash and cannot be faked, and running the suite as
    # root to check this would be a worse idea than the bug it guards against.
    # So this is asserted structurally: the guard exists, it exits rather than
    # warning, and it runs before any package manager step can.
    local body
    body="$(sed -n '/^require_not_root()/,/^}/p' "$SCRIPT")"

    assert_contains "$body" 'EUID' "reads EUID to detect root"
    assert_contains "$body" 'exit 1' "aborts instead of merely warning"

    local guard_line first_step
    guard_line="$(grep -n '^\s*require_not_root$' "$SCRIPT" | head -1 | cut -d: -f1)"
    first_step="$(grep -n '^\s*step_[a-z_]*$' "$SCRIPT" | head -1 | cut -d: -f1)"
    if [ -n "$guard_line" ] && { [ -z "$first_step" ] || [ "$guard_line" -lt "$first_step" ]; }; then
        pass "runs before any package manager step"
    else
        fail "the guard is not reached before the first step"
    fi
}

test_second_instance_refused() {
    describe "safety: a second instance refuses to start" || return 0
    local home
    home="$(new_sandbox)"; mkdir -p "$home/tmp"

    # Pre-create the lock the way a running instance would.
    mkdir -p "$home/tmp/update-anything.lock"

    local out rc
    out="$(run_in "$home" --check --yes 2>&1)"; rc=$?
    assert_contains "$out" "already running" "reports the other instance"
    if [ "$rc" -ne 0 ]; then pass "exits non-zero"; else fail "exited 0 despite the lock"; fi
    drop_sandbox
}

test_lock_released_on_exit() {
    describe "safety: the lock is released when it finishes" || return 0
    local home
    home="$(new_sandbox)"; mkdir -p "$home/tmp"

    run_in "$home" --check --yes >/dev/null 2>&1

    if [ ! -d "$home/tmp/update-anything.lock" ]; then
        pass "no stale lock is left behind"
    else
        fail "the lock directory survived a normal exit"
    fi
    drop_sandbox
}

# --- Exit status ------------------------------------------------------------
#
# The status is what anything scripting this actually reads, and it used to be
# decided by whichever command happened to run last.

test_exit_zero_on_success() {
    describe "exit status: zero when everything succeeded" || return 0
    local home rc
    home="$(new_sandbox flatpak)"; mkdir -p "$home/tmp"

    run_in "$home" --yes >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "0" "a clean run exits 0"

    run_in "$home" --check --yes >/dev/null 2>&1; rc=$?
    assert_eq "$rc" "0" "--check exits 0 as well"
    drop_sandbox
}

test_exit_nonzero_on_failure() {
    describe "exit status: non-zero when a step failed" || return 0
    local home rc
    home="$(new_sandbox flatpak)"; mkdir -p "$home/tmp"

    # A manager that fails its update but answers every other call.
    cat > "$home/bin/flatpak" <<'EOF'
#!/bin/sh
case "$1" in update) exit 3 ;; esac
exit 0
EOF
    chmod +x "$home/bin/flatpak"

    run_in "$home" --yes >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "a failed step is reported through the exit status"
    else
        fail "reported success despite a failed step (exit $rc)"
    fi
    drop_sandbox
}

# --- State ------------------------------------------------------------------

test_log_written() {
    describe "state: a log is written for every run" || return 0
    local home
    home="$(new_sandbox)"; mkdir -p "$home/tmp"
    run_in "$home" --version >/dev/null 2>&1

    local logs
    logs="$(find "$home/.local/share/update-anything/logs" -name 'update-*.log' 2>/dev/null | wc -l)"
    if [ "$logs" -ge 1 ]; then
        pass "even --version leaves a log behind"
    else
        fail "no log was written"
    fi
    drop_sandbox
}

test_snapshot_before_changes() {
    describe "state: --snapshot records packages before touching anything" || return 0
    local home
    home="$(new_sandbox pacman)"; mkdir -p "$home/tmp"
    run_in "$home" --check --yes --snapshot >/dev/null 2>&1
    assert_exists "$home/.local/share/update-anything/pkg-snapshots" "the snapshot directory exists"
    drop_sandbox
}

test_config_is_honoured() {
    describe "state: the config file is read" || return 0
    local home
    home="$(new_sandbox flatpak)"; mkdir -p "$home/tmp" "$home/.config/update-anything"
    printf 'SKIP_LIST=" flatpak "\n' > "$home/.config/update-anything/config"

    run_in "$home" --check --yes >/dev/null 2>&1
    assert_absent_from "$(calls_in "$home")" "flatpak" \
        "a manager skipped in the config does not run"
    drop_sandbox
}

# --- Portability ------------------------------------------------------------

test_bash32_compatible() {
    describe "portability: no bash 4+ syntax" || return 0
    # macOS ships bash 3.2. These four constructs are the usual way a script
    # silently stops working there.
    # Comments are stripped first: the script's own header lists these
    # constructs to say it avoids them, and matching that would be absurd.
    local hits
    hits="$(sed 's/#.*//' "$SCRIPT" \
              | grep -cE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+,,\}|local -n')"
    assert_eq "$hits" "0" "uses no associative arrays, mapfile, \${var,,} or local -n"
}

test_no_hardcoded_home() {
    describe "portability: no hardcoded home directories" || return 0
    local hits
    hits="$(cat "$SCRIPT" "$ROOT/install.sh" | grep -cE '/home/[a-z]+/|/Users/[a-z]+/')"
    assert_eq "$hits" "0" "paths are derived, never written literally"
}

# --- Runner -----------------------------------------------------------------

main() {
    printf '%supdate-anything test suite%s\n' "$BOLD" "$RESET"
    printf '%s%s%s\n' "$DIM" "$ROOT" "$RESET"

    test_version
    test_help
    test_unknown_flag_rejected
    test_check_only_mutates_nothing
    test_skip_flag_suppresses_manager
    test_refuses_to_run_as_root
    test_second_instance_refused
    test_lock_released_on_exit
    test_exit_zero_on_success
    test_exit_nonzero_on_failure
    test_log_written
    test_snapshot_before_changes
    test_config_is_honoured
    test_bash32_compatible
    test_no_hardcoded_home

    printf '\n  %s%d passed%s' "$GREEN" "$PASSED" "$RESET"
    [ "$FAILED" -gt 0 ] && printf ', %s%d failed%s' "$RED" "$FAILED" "$RESET"
    printf '\n\n'

    [ "$FAILED" -eq 0 ]
}

trap drop_sandbox EXIT
main "$@"
