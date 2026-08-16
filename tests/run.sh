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

# --- Selection and output ----------------------------------------------------

test_only_restricts_to_listed() {
    describe "selection: --only updates nothing else" || return 0
    local home
    home="$(new_sandbox flatpak npm cargo)"; mkdir -p "$home/tmp"

    run_in "$home" --check --yes --only flatpak >/dev/null 2>&1

    local calls; calls="$(calls_in "$home")"
    assert_contains "$calls" "flatpak" "the selected manager runs"
    assert_absent_from "$calls" "npm" "an unlisted manager does not"
    assert_absent_from "$calls" "cargo" "nor another one"
    drop_sandbox
}

test_only_accepts_a_list() {
    describe "selection: --only takes several managers" || return 0
    local home
    home="$(new_sandbox flatpak npm cargo)"; mkdir -p "$home/tmp"

    run_in "$home" --check --yes --only flatpak,cargo >/dev/null 2>&1

    local calls; calls="$(calls_in "$home")"
    assert_contains "$calls" "flatpak" "the first listed manager runs"
    assert_contains "$calls" "cargo" "the second one too"
    assert_absent_from "$calls" "npm" "and nothing outside the list"
    drop_sandbox
}

test_only_beats_no_flag() {
    describe "selection: --only wins over --no-<manager>" || return 0
    local home
    home="$(new_sandbox flatpak npm)"; mkdir -p "$home/tmp"

    # Contradictory on purpose: the result must not depend on parse order.
    run_in "$home" --check --yes --only flatpak --no-flatpak >/dev/null 2>&1
    assert_absent_from "$(calls_in "$home")" "npm" "the unlisted manager stays out"
    drop_sandbox
}

test_quiet_silences_progress_not_problems() {
    describe "output: --quiet keeps warnings, drops progress" || return 0
    local home out
    home="$(new_sandbox)"; mkdir -p "$home/tmp"

    out="$(run_in "$home" --check --yes --quiet 2>&1)"
    assert_absent_from "$out" "Checking internet" "progress messages are gone"

    # No manager at all is a warning, and a warning must survive --quiet.
    assert_contains "$out" "No supported package manager" "warnings still get through"
    drop_sandbox
}

test_quiet_still_logs() {
    describe "output: --quiet still writes the log" || return 0
    local home
    home="$(new_sandbox flatpak)"; mkdir -p "$home/tmp"

    run_in "$home" --check --yes --quiet >/dev/null 2>&1

    local logged
    logged="$(cat "$home/.local/share/update-anything/logs/"*.log 2>/dev/null)"
    assert_contains "$logged" "INFO" "the file keeps the detail the terminal did not show"
    drop_sandbox
}

test_parallel_runs_all_user_space_managers() {
    describe "parallel: every user-space manager still runs" || return 0
    local home
    home="$(new_sandbox cargo npm pipx)"; mkdir -p "$home/tmp"

    run_in "$home" --yes >/dev/null 2>&1

    # Concurrency must not lose a manager, and each writes to its own file
    # before the output is replayed, so nothing should go missing.
    local calls; calls="$(calls_in "$home")"
    assert_contains "$calls" "cargo" "cargo ran"
    assert_contains "$calls" "npm" "npm ran"
    assert_contains "$calls" "pipx" "pipx ran"
    drop_sandbox
}

test_parallel_failure_is_reported() {
    describe "parallel: a failure inside a subshell still surfaces" || return 0
    local home rc
    home="$(new_sandbox cargo npm)"; mkdir -p "$home/tmp"

    # A subshell cannot append to FAILED_STEPS in the parent, so the status
    # travels back through a file. If that breaks, this exits 0.
    # Reports something to update, then fails the update itself. A stub that
    # failed the "outdated" query instead would make step_npm return early with
    # "up to date" and never reach the failure path at all.
    cat > "$home/bin/npm" <<'EOF'
#!/bin/sh
case "$*" in
  *update*) exit 4 ;;
  *outdated*) echo "/usr/lib/node_modules/example:example@1.0.0:example@2.0.0"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$home/bin/npm"

    run_in "$home" --yes >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "the exit status reflects a parallel step failing"
    else
        fail "a failure inside the parallel block was swallowed (exit $rc)"
    fi
    drop_sandbox
}

test_no_parallel_still_works() {
    describe "parallel: --no-parallel runs them sequentially" || return 0
    local home
    home="$(new_sandbox cargo npm)"; mkdir -p "$home/tmp"

    run_in "$home" --yes --no-parallel >/dev/null 2>&1

    local calls; calls="$(calls_in "$home")"
    assert_contains "$calls" "cargo" "cargo still ran"
    assert_contains "$calls" "npm" "npm still ran"
    drop_sandbox
}

test_no_parallel_is_not_a_manager() {
    describe "parallel: --no-parallel is not read as a manager name" || return 0
    local home
    home="$(new_sandbox flatpak)"; mkdir -p "$home/tmp"

    # --no-* is a catch-all, so ordering in the case statement decides whether
    # this flag works or silently adds "parallel" to the skip list.
    run_in "$home" --check --yes --no-parallel >/dev/null 2>&1
    assert_contains "$(calls_in "$home")" "flatpak" "unrelated managers are unaffected"
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

# A stub whose "outdated" list is long enough to be folded. Everything else
# about it matches the generic stub: silent, exits 0.
long_output_brew() {
    cat > "$1/bin/brew" <<'EOF'
#!/bin/sh
if [ "$1" = "outdated" ]; then
    i=1
    while [ "$i" -le 100 ]; do echo "package-$i 1.0 -> 2.0"; i=$((i + 1)); done
fi
exit 0
EOF
    chmod +x "$1/bin/brew"
}

test_long_preview_is_folded() {
    describe "output: a long pending list is folded, not dumped" || return 0
    local home out
    home="$(new_sandbox brew)"; mkdir -p "$home/tmp"
    long_output_brew "$home"

    out="$(run_in "$home" --check --yes 2>&1)"
    assert_contains "$out" "package-1 " "the start of the list is shown"
    assert_contains "$out" "and 80 more" "the rest is folded into a count"
    assert_absent_from "$out" "package-100 " "the tail never reaches the terminal"
    drop_sandbox
}

test_full_flag_restores_the_list() {
    describe "output: --full prints every line" || return 0
    local home out
    home="$(new_sandbox brew)"; mkdir -p "$home/tmp"
    long_output_brew "$home"

    out="$(run_in "$home" --check --yes --full 2>&1)"
    assert_contains "$out" "package-100 " "the whole list is printed"
    assert_absent_from "$out" "more (full list in the log" "nothing is folded away"
    drop_sandbox
}

test_folded_list_is_complete_in_the_log() {
    describe "output: folding never loses a line from the log" || return 0
    local home log
    home="$(new_sandbox brew)"; mkdir -p "$home/tmp"
    long_output_brew "$home"

    run_in "$home" --check --yes >/dev/null 2>&1
    log="$(find "$home/.local/share/update-anything/logs" -name 'update-*.log' | head -1)"
    assert_contains "$(cat "$log" 2>/dev/null)" "package-100 1.0 -> 2.0" \
        "the line the terminal folded away is still on disk"
    drop_sandbox
}

test_config_only_list_is_honoured() {
    describe "state: ONLY_LIST set in the config restricts the run" || return 0
    local home
    home="$(new_sandbox flatpak npm)"; mkdir -p "$home/tmp" "$home/.config/update-anything"
    # Exactly the form config.example documents, spacing included: the list is
    # matched as " name ", so a config that drops the spaces silently matches
    # nothing. That is worth a test rather than a comment.
    printf 'ONLY_LIST=" flatpak "\n' > "$home/.config/update-anything/config"

    run_in "$home" --check --yes >/dev/null 2>&1
    local calls; calls="$(calls_in "$home")"
    assert_contains "$calls" "flatpak" "the manager named in the config runs"
    assert_absent_from "$calls" "npm" "everything else is left alone"
    drop_sandbox
}

test_config_quiet_is_honoured() {
    describe "state: QUIET set in the config silences progress" || return 0
    local home out
    home="$(new_sandbox)"; mkdir -p "$home/tmp" "$home/.config/update-anything"
    printf 'QUIET=1\n' > "$home/.config/update-anything/config"

    out="$(run_in "$home" --check --yes 2>&1)"
    assert_absent_from "$out" "Checking internet" "progress is gone without any flag"
    assert_contains "$out" "No supported package manager" "warnings still get through"
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
    test_only_restricts_to_listed
    test_only_accepts_a_list
    test_only_beats_no_flag
    test_quiet_silences_progress_not_problems
    test_quiet_still_logs
    test_parallel_runs_all_user_space_managers
    test_parallel_failure_is_reported
    test_no_parallel_still_works
    test_no_parallel_is_not_a_manager
    test_log_written
    test_snapshot_before_changes
    test_config_is_honoured
    test_long_preview_is_folded
    test_full_flag_restores_the_list
    test_folded_list_is_complete_in_the_log
    test_config_only_list_is_honoured
    test_config_quiet_is_honoured
    test_bash32_compatible
    test_no_hardcoded_home

    printf '\n  %s%d passed%s' "$GREEN" "$PASSED" "$RESET"
    [ "$FAILED" -gt 0 ] && printf ', %s%d failed%s' "$RED" "$FAILED" "$RESET"
    printf '\n\n'

    [ "$FAILED" -eq 0 ]
}

trap drop_sandbox EXIT
main "$@"
