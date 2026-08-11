#!/usr/bin/env bash
#
# Copyright (C) 2026 Enzo
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

# update-anything.sh - safe, auto-detecting full-system updater for any
#   Unix (Linux, macOS, FreeBSD, OpenBSD). Detects the OS and every package
#   manager actually installed, then updates only those. Nothing is assumed
#   present; nothing is hardcoded as "the" package manager for an OS.
#
# Written against bash 3.2 syntax on purpose (macOS ships bash 3.2 by
# default) -- no associative arrays, no ${var,,}, no mapfile, no local -n.
#
# Design principles (see --help):
#   - never partial-upgrade a system package manager
#   - never force through a package manager's own destructive prompts
#     (package replacement, removal, conflicting files) -- only this
#     script's own confirmations are skippable with --yes
#   - one manager failing does not abort the others
#   - destructive extras (orphan removal, cache cleanup, firmware) are
#     opt-in flags only
#   - a snapshot of installed packages is written before touching anything
#   - portable: mkdir-based locking (no flock), POSIX df, curl-based
#     connectivity check -- works the same on Linux, macOS and BSD

# Every step_* function is dispatched by name -- run_updates calls
# "step_${mgr}" for each detected manager -- and cleanup runs from a trap.
# ShellCheck can see neither, so without this it reports all of them as dead
# code: SC2329 in newer releases, SC2317 in older ones, hence both.
# Must precede the first command to apply to the whole file.
# shellcheck disable=SC2329,SC2317

set -uo pipefail

# --- Constants --------------------------------------------------------------

readonly SCRIPT_NAME="update-anything"
readonly VERSION="1.1.0"
readonly STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/${SCRIPT_NAME}"
readonly LOG_DIR="${STATE_DIR}/logs"
readonly SNAPSHOT_DIR="${STATE_DIR}/pkg-snapshots"
readonly LOCK_DIR="${TMPDIR:-/tmp}/${SCRIPT_NAME}.lock"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly TIMESTAMP
readonly LOG_FILE="${LOG_DIR}/update-${TIMESTAMP}.log"

# Created immediately, before argument parsing: log()/info()/etc. append to
# LOG_FILE unconditionally, including on early exits like --help/--version,
# so the directory must exist before any of those can possibly run.
mkdir -p "$LOG_DIR" "$SNAPSHOT_DIR"

readonly MIN_FREE_MB_WARN=2048
readonly MIN_FREE_MB_ABORT=500
readonly LOG_RETENTION_DAYS=30

# --- Options ------------------------------------------------------------------

ASSUME_YES=0
CHECK_ONLY=0
DO_CLEAN=0
DO_ORPHANS=0
DO_FIRMWARE=0
DO_NOTIFY=0
DO_SNAPSHOT=0
DO_DEEP_CLEAN=0
DO_INHIBIT_SLEEP=0
DO_AUDIT=0
QUIET=0
NO_PARALLEL=0
SKIP_LIST=" "
ONLY_LIST=""

# Managers that need no elevation and touch entirely separate trees, so they
# can run concurrently. System managers are deliberately absent: they share a
# package database and a sudo ticket, and running two of them at once is the
# corruption this script exists to avoid.
readonly PARALLEL_SAFE=" cargo npm pipx uv pnpm bun "

# Per-step wall-clock timings, "label=seconds", filled by run_step. A plain
# array rather than an associative one, which bash 3.2 does not have.
STEP_TIMINGS=()

# Sourced as real shell code -- same trust model as hooks.d/ or your own
# shell rc files (your permissions, your call), not a restricted key=value
# parser. Meant for setting your own personal defaults, e.g.:
#   DO_NOTIFY=1
#   UPDATE_ANYTHING_WEBHOOK_URL="https://..."
# CLI flags parsed afterwards always take priority over this file.
readonly CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/${SCRIPT_NAME}/config"
load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}
load_config

FAILED_STEPS=()
MANAGERS=()
OS_KERNEL="" # uname -s: Linux, Darwin, FreeBSD, OpenBSD, NetBSD
OS_FAMILY="" # distro id on Linux (arch, debian, fedora, ...), or macos/freebsd/openbsd/netbsd

# --- Colors / logging -----------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_BOLD=""
  C_RESET=""
fi

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE"
}

# --quiet silences progress but never warnings or errors, and never the log:
# a cron job should be silent when it worked and loud when it did not, while
# still leaving a full record on disk.
info() {
  [[ "$QUIET" -eq 0 ]] && echo "${C_BLUE}[*]${C_RESET} $*"
  log "INFO" "$*"
}
success() {
  [[ "$QUIET" -eq 0 ]] && echo "${C_GREEN}[OK]${C_RESET} $*"
  log "OK" "$*"
}
warn() {
  echo "${C_YELLOW}[!]${C_RESET} $*"
  log "WARN" "$*"
}
error() {
  echo "${C_RED}[ERROR]${C_RESET} $*" >&2
  log "ERROR" "$*"
}
section() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo
    echo "${C_BOLD}== $* ==${C_RESET}"
  fi
  log "SECTION" "$*"
}

confirm() {
  local prompt="$1"
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local reply
  read -r -p "${C_YELLOW}?${C_RESET} ${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

is_skipped() {
  # --only, when given, is authoritative: anything outside it is skipped
  # regardless of --no-*. Checked first so the two can be combined without the
  # result depending on which was parsed last.
  if [[ -n "$ONLY_LIST" ]]; then
    case "$ONLY_LIST" in
    *" $1 "*) ;;
    *) return 0 ;;
    esac
  fi
  case "$SKIP_LIST" in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# Packages each manager has been told to hold back, using that manager's own
# mechanism. This only reports them: reimplementing holds here would mean
# either duplicating state the manager already owns, or overriding a decision
# the user deliberately recorded. Neither is this script's business -- but
# silently upgrading around a hold, with no indication it exists, is how you
# end up wondering why a package never moves.
#
# Deselected managers are not consulted at all: --no-flatpak has to mean the
# script does not touch flatpak, not that it merely declines to upgrade it.
report_holds() {
  local found=0 held=""

  if ! is_skipped pacman && command -v pacman >/dev/null 2>&1 && [[ -r /etc/pacman.conf ]]; then
    held=$(sed -n 's/^[[:space:]]*IgnorePkg[[:space:]]*=[[:space:]]*//p' /etc/pacman.conf | tr '\n' ' ')
    [[ -n "$held" ]] && {
      info "pacman holds (IgnorePkg): $held"
      found=1
    }
  fi

  if ! is_skipped apt && command -v apt-mark >/dev/null 2>&1; then
    held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
    [[ -n "$held" ]] && {
      info "apt holds (apt-mark hold): $held"
      found=1
    }
  fi

  if ! is_skipped dnf && command -v dnf >/dev/null 2>&1; then
    held=$(dnf versionlock list 2>/dev/null | grep -v '^Last metadata' | tr '\n' ' ')
    [[ -n "$held" ]] && {
      info "dnf holds (versionlock): $held"
      found=1
    }
  fi

  if ! is_skipped brew && command -v brew >/dev/null 2>&1; then
    held=$(brew list --pinned 2>/dev/null | tr '\n' ' ')
    [[ -n "$held" ]] && {
      info "Homebrew holds (brew pin): $held"
      found=1
    }
  fi

  if ! is_skipped flatpak && command -v flatpak >/dev/null 2>&1; then
    held=$(flatpak mask 2>/dev/null | grep -v '^$' | tr '\n' ' ')
    [[ -n "$held" ]] && {
      info "Flatpak holds (flatpak mask): $held"
      found=1
    }
  fi

  if [[ "$found" -eq 1 ]]; then
    info "These are held by your package managers and will not be upgraded."
    info "To release one, use that manager's own command (e.g. 'sudo apt-mark unhold <pkg>')."
  fi
}

notify_user() {
  [[ "$DO_NOTIFY" -eq 1 ]] || return 0
  local title="$1" message="$2"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$message" 2>/dev/null
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null
  fi
}

# Runs user-supplied scripts from ~/.config/update-anything/hooks.d/<stage>/.
# These execute as the invoking user (never elevated by this script), same
# trust model as shell rc files or pacman hooks: whatever the user placed
# there, under their own $HOME, with their own permissions.
run_hooks() {
  local stage="$1"
  local hook_dir="${XDG_CONFIG_HOME:-$HOME/.config}/${SCRIPT_NAME}/hooks.d/${stage}"
  [[ -d "$hook_dir" ]] || return 0
  local hook
  for hook in "$hook_dir"/*; do
    [[ -e "$hook" ]] || continue
    if [[ -x "$hook" ]]; then
      run_step "hook: $(basename "$hook")" "$hook"
    else
      warn "Hook not executable, skipping: $hook (chmod +x to enable it)"
    fi
  done
}

# Opt-in via UPDATE_ANYTHING_WEBHOOK_URL (Discord/Slack-compatible payload
# shape). Never called unless the user has explicitly set that variable --
# this sends the hostname and update status to an external URL.
send_webhook() {
  local url="${UPDATE_ANYTHING_WEBHOOK_URL:-}"
  [[ -z "$url" ]] && return 0
  command -v curl >/dev/null 2>&1 || {
    warn "UPDATE_ANYTHING_WEBHOOK_URL is set but curl is not installed, skipping webhook."
    return 0
  }

  local status="all package managers updated successfully"
  [[ "${#FAILED_STEPS[@]}" -gt 0 ]] && status="completed with issues in: ${FAILED_STEPS[*]}"
  local host status_json
  host=$(hostname 2>/dev/null || echo "unknown")
  status_json=$(printf '%s' "$status" | sed 's/\\/\\\\/g; s/"/\\"/g')
  local payload
  payload=$(printf '{"content":"update-anything on %s: %s"}' "$host" "$status_json")
  curl -fsS --max-time 10 -H "Content-Type: application/json" -X POST -d "$payload" "$url" >/dev/null 2>&1 ||
    warn "Webhook notification failed to send."
}

# --- Cleanup / locking (portable: mkdir is atomic on every POSIX filesystem) --

cleanup() {
  local ec=$?
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  rmdir "$LOCK_DIR" 2>/dev/null
  if [[ "${#FAILED_STEPS[@]}" -gt 0 ]]; then
    echo
    warn "Steps that failed or were skipped due to errors: ${FAILED_STEPS[*]}"
  fi
  info "Full log: $LOG_FILE"
  exit "$ec"
}
trap cleanup EXIT
trap 'error "Interrupted."; exit 130' INT TERM

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    error "Another instance of ${SCRIPT_NAME} is already running (lock: $LOCK_DIR)."
    error "If you're sure that's wrong, remove it: rmdir '$LOCK_DIR'"
    exit 1
  fi
}

# --- Pre-flight checks -----------------------------------------------------------

detect_os() {
  OS_KERNEL="$(uname -s)"
  case "$OS_KERNEL" in
  Linux)
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      OS_FAMILY="$(. /etc/os-release && echo "$ID")"
    else
      OS_FAMILY="linux"
    fi
    ;;
  Darwin) OS_FAMILY="macos" ;;
  FreeBSD) OS_FAMILY="freebsd" ;;
  OpenBSD) OS_FAMILY="openbsd" ;;
  NetBSD) OS_FAMILY="netbsd" ;;
  *) OS_FAMILY="unknown" ;;
  esac
  info "Detected: ${OS_KERNEL} (${OS_FAMILY})"
}

require_not_root() {
  if [[ "$EUID" -eq 0 ]]; then
    error "Do not run this script as root/with sudo. It calls sudo itself only"
    error "where a given package manager needs it, and refuses to run user-space"
    error "managers (AUR helpers, Homebrew, cargo, npm, pipx) as root."
    exit 1
  fi
}

check_internet() {
  info "Checking internet connectivity..."
  local ok=1
  if command -v curl >/dev/null 2>&1; then
    curl -sI --max-time 5 https://1.1.1.1 >/dev/null 2>&1 && ok=0
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=5 --spider https://1.1.1.1 2>/dev/null && ok=0
  else
    (exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null && ok=0
    exec 3>&- 2>/dev/null || true
  fi
  if [[ "$ok" -ne 0 ]]; then
    error "No internet connectivity detected. Aborting."
    exit 1
  fi
  success "Internet OK."
}

check_disk_space() {
  info "Checking free disk space..."
  # -Pk: POSIX output format, forced kilobyte blocks. Works identically on
  # GNU coreutils, macOS/BSD df -- unlike GNU-only 'df --output=avail'.
  local free_kb free_mb
  free_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  free_mb=$((free_kb / 1024))
  if [[ "$free_mb" -lt "$MIN_FREE_MB_ABORT" ]]; then
    error "Only ${free_mb}MB free on /. Refusing to start (risk of a corrupted"
    error "transaction if the disk fills up mid-upgrade). Free up space first."
    exit 1
  elif [[ "$free_mb" -lt "$MIN_FREE_MB_WARN" ]]; then
    warn "Only ${free_mb}MB free on /. Proceeding, but consider cleaning up soon."
  else
    success "Disk space OK (${free_mb}MB free on /)."
  fi
}

check_battery() {
  local capacity="" discharging=0

  if [[ "$OS_KERNEL" == "Linux" ]]; then
    local bat
    for bat in /sys/class/power_supply/BAT*; do
      [[ -d "$bat" ]] || continue
      capacity=$(cat "${bat}/capacity" 2>/dev/null || true)
      [[ "$(cat "${bat}/status" 2>/dev/null || true)" == "Discharging" ]] && discharging=1
      break
    done
  elif [[ "$OS_KERNEL" == "Darwin" ]] && command -v pmset >/dev/null 2>&1; then
    local batt_line
    batt_line=$(pmset -g batt 2>/dev/null || true)
    capacity=$(echo "$batt_line" | grep -o '[0-9]\{1,3\}%' | head -1 | tr -d '%')
    echo "$batt_line" | grep -qi "discharging" && discharging=1
  fi

  # No battery found (desktop, or unreadable on an unsupported OS): nothing
  # to warn about, skip silently rather than assuming a laptop.
  [[ -z "$capacity" ]] && return 0
  [[ "$discharging" -eq 0 ]] && return 0

  if [[ "$capacity" -lt 10 ]]; then
    error "Battery at ${capacity}% and discharging. Plug in before updating:"
    error "a power loss mid-transaction (pacman/apt/dnf/...) can corrupt the package DB."
    exit 1
  elif [[ "$capacity" -lt 20 ]]; then
    warn "Battery at ${capacity}% and discharging. Consider plugging in before a large update."
  fi
}

check_metered_connection() {
  # Only reliably detectable via NetworkManager (Linux). No honest
  # equivalent check is added for macOS: SSID-based hotspot guessing is a
  # guess, not a verification, so it's left out rather than faked.
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli -t -f GENERAL.METERED dev show 2>/dev/null | grep -qi 'yes' || return 0
  warn "Metered connection detected (e.g. mobile hotspot)."
  confirm "Continue downloading updates over this connection?" || exit 0
}

check_pacman_lock() {
  command -v pacman >/dev/null 2>&1 || return 0
  local lock=/var/lib/pacman/db.lck
  [[ -e "$lock" ]] || return 0
  if pgrep -x pacman >/dev/null 2>&1; then
    error "pacman is already running elsewhere. Aborting to avoid db corruption."
    exit 1
  fi
  error "Stale pacman lock file found: $lock (no pacman process is running)."
  error "This script will not remove it automatically. If you're sure no other"
  error "package manager is running, remove it yourself: sudo rm '$lock'"
  exit 1
}

SUDO_KEEPALIVE_PID=""
warm_sudo() {
  command -v sudo >/dev/null 2>&1 || return 0
  info "Requesting sudo credentials upfront (needed by some package managers)..."
  if ! sudo -v; then
    error "Could not obtain sudo credentials."
    exit 1
  fi
  # Sleeps in one-second steps rather than one 60-second step. Killing the
  # subshell does not kill a sleep already running inside it, so a single long
  # sleep was left orphaned and outlived the script by up to a minute; and the
  # parent-liveness check only ran once a minute, so a killed script kept its
  # keepalive alive for just as long. Both windows are now a second.
  (while true; do
    sudo -n true 2>/dev/null || exit 0
    _elapsed=0
    while [ "$_elapsed" -lt 60 ]; do
      sleep 1
      kill -0 "$$" 2>/dev/null || exit 0
      _elapsed=$((_elapsed + 1))
    done
  done) &
  SUDO_KEEPALIVE_PID=$!
}

snapshot_packages() {
  mkdir -p "$SNAPSHOT_DIR"
  local snap="${SNAPSHOT_DIR}/pkglist-${TIMESTAMP}.txt"
  {
    command -v pacman >/dev/null 2>&1 && pacman -Q
    command -v dpkg >/dev/null 2>&1 && dpkg -l
    command -v rpm >/dev/null 2>&1 && rpm -qa
    command -v brew >/dev/null 2>&1 && brew list --versions
    command -v pkg >/dev/null 2>&1 && pkg info 2>/dev/null
  } >"$snap" 2>/dev/null
  info "Installed-package snapshot saved: $snap"

  # Silent retention purge: without this, daily use turns
  # ~/.local/share/update-anything/ into hundreds of stale files after a
  # few months. Scoped strictly to our own log/snapshot dirs.
  find "$LOG_DIR" "$SNAPSHOT_DIR" -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
}

# Deliberately just a diff between two package-list snapshots -- NOT a real
# downgrade/rollback executor. Generating an actually-correct downgrade
# command per package (right cached version, right syntax per package
# manager) is a project of its own, not a 10-line function; promising that
# here would be overselling what this does.
show_rollback_diff() {
  local snaps current previous
  # ls -t, not find: sorting by mtime portably is exactly what find cannot do
  # here. -printf is GNU-only and absent on macOS and the BSDs, which this
  # script supports. Snapshot names are generated by this script and contain
  # only digits and dashes, so the filename hazard SC2012 warns about does not
  # arise.
  # shellcheck disable=SC2012
  snaps=$(ls -t "$SNAPSHOT_DIR"/pkglist-*.txt 2>/dev/null | head -n 2)
  current=$(echo "$snaps" | sed -n '1p')
  previous=$(echo "$snaps" | sed -n '2p')

  if [[ -z "$previous" ]]; then
    error "Not enough snapshot history to show a diff (need at least 2 runs)."
    exit 1
  fi

  info "Package differences between the previous snapshot and the most recent one:"
  info "  previous: $previous"
  info "  current:  $current"
  diff -u "$previous" "$current" || true
  exit 0
}

# --- Step runner --------------------------------------------------------------

run_step() {
  local label="$1"
  shift
  section "$label"
  log "CMD" "$*"

  local started ended rc
  started=$(date +%s)

  if "$@" 2>&1 | tee -a "$LOG_FILE"; then
    rc=0
  else
    rc=1
  fi

  ended=$(date +%s)
  STEP_TIMINGS+=("${label}=$((ended - started))")

  if [[ "$rc" -eq 0 ]]; then
    success "$label done."
    return 0
  fi
  error "$label failed (see log). Continuing with remaining steps."
  FAILED_STEPS+=("$label")
  return 1
}

# --- System package manager steps (one per manager, all opt-out via --no-X) ---

step_pacman() {
  info "Checking for official-repo updates (non-destructive check)..."
  local pending="" have_preview=0 official_up_to_date=0
  if command -v checkupdates >/dev/null 2>&1; then
    have_preview=1
    pending=$(checkupdates 2>/dev/null || true)
    if [[ -z "$pending" ]]; then
      success "System is up to date (official repos)."
      official_up_to_date=1
    else
      echo "$pending"
    fi
  else
    warn "checkupdates not found (install 'pacman-contrib' for a pre-upgrade preview)."
    warn "Proceeding without a preview; pacman -Syu will show what it plans to do."
  fi

  if [[ "$official_up_to_date" -eq 0 ]]; then
    if [[ "$CHECK_ONLY" -eq 0 ]]; then
      local prompt="Sync and upgrade official-repo packages with 'sudo pacman -Syu'?"
      [[ "$have_preview" -eq 1 ]] && prompt="Apply the $(wc -l <<<"$pending") pacman update(s) above with 'sudo pacman -Syu'?"
      if confirm "$prompt"; then
        run_step "pacman -Syu" sudo pacman -Syu
      else
        warn "Skipped pacman upgrade by user choice."
      fi
    fi
  fi

  # AUR is checked independently of the official-repo decision above, so
  # declining one never silently skips the other.
  local helper=""
  for h in yay paru pikaur trizen aurman pamac; do
    command -v "$h" >/dev/null 2>&1 && {
      helper="$h"
      break
    }
  done
  [[ -z "$helper" ]] && return 0

  info "Checking AUR updates via $helper..."
  local aur_pending=""
  case "$helper" in
  yay) aur_pending=$(yay -Qua 2>/dev/null || true) ;;
  paru) aur_pending=$(paru -Qua 2>/dev/null || true) ;;
  esac
  if [[ -n "$aur_pending" ]]; then
    echo "$aur_pending"
  elif [[ "$helper" == "yay" || "$helper" == "paru" ]]; then
    success "AUR is up to date."
    return 0
  fi

  [[ "$CHECK_ONLY" -eq 1 ]] && return 0
  confirm "Apply AUR updates with '$helper -Sua' (runs as your user, never root)?" || {
    warn "Skipped AUR upgrade by user choice."
    return 0
  }
  case "$helper" in
  yay | paru) run_step "AUR ($helper)" "$helper" -Sua ;;
  *) run_step "AUR ($helper)" "$helper" -Syu ;;
  esac
}

step_apt() {
  info "Checking apt updates..."
  run_step "apt-get update" sudo apt-get update
  local pending
  pending=$(apt list --upgradable 2>/dev/null | tail -n +2 || true)
  if [[ -z "$pending" ]]; then
    success "System is up to date (apt)."
    return 0
  fi
  echo "$pending"
  [[ "$CHECK_ONLY" -eq 1 ]] && return 0
  # full-upgrade (not plain upgrade): lets apt add/remove packages when
  # required to resolve dependencies, same rationale as pacman -Syu vs
  # partial upgrades. --noconfirm is never passed: apt's own removal/
  # conflict prompts stay interactive.
  confirm "Apply the apt update(s) above with 'sudo apt-get full-upgrade'?" || {
    warn "Skipped apt upgrade by user choice."
    return 0
  }
  run_step "apt-get full-upgrade" sudo apt-get full-upgrade
}

step_dnf() {
  info "Checking dnf updates..."
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    run_step "dnf check-update" sudo dnf check-update
    return 0
  }
  confirm "Check and apply dnf updates ('sudo dnf upgrade')?" || {
    warn "Skipped dnf upgrade by user choice."
    return 0
  }
  run_step "dnf upgrade" sudo dnf upgrade
}

step_yum() {
  command -v dnf >/dev/null 2>&1 && return 0 # dnf supersedes yum, avoid running both
  info "Checking yum updates..."
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    run_step "yum check-update" sudo yum check-update
    return 0
  }
  confirm "Check and apply yum updates ('sudo yum update')?" || {
    warn "Skipped yum upgrade by user choice."
    return 0
  }
  run_step "yum update" sudo yum update
}

step_zypper() {
  info "Checking zypper updates..."
  run_step "zypper refresh" sudo zypper refresh
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    sudo zypper list-updates
    return 0
  }
  # 'zypper update' (not 'dup'): stays within the current repo/version
  # stream. 'dup' can jump distribution versions and is opt-in territory,
  # not something a routine updater should do silently.
  confirm "Apply updates with 'sudo zypper update'?" || {
    warn "Skipped zypper upgrade by user choice."
    return 0
  }
  run_step "zypper update" sudo zypper update
}

step_apk() {
  info "Checking apk (Alpine) updates..."
  run_step "apk update" sudo apk update
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    apk version -l '<' 2>/dev/null
    return 0
  }
  confirm "Apply updates with 'sudo apk upgrade'?" || {
    warn "Skipped apk upgrade by user choice."
    return 0
  }
  run_step "apk upgrade" sudo apk upgrade
}

step_brew() {
  info "Checking Homebrew/Linuxbrew updates..."
  run_step "brew update" brew update
  local outdated
  outdated=$(brew outdated 2>/dev/null || true)
  if [[ -z "$outdated" ]]; then
    success "Homebrew is up to date."
    return 0
  fi
  echo "$outdated"
  [[ "$CHECK_ONLY" -eq 1 ]] && return 0
  confirm "Upgrade the Homebrew packages listed above?" || {
    warn "Skipped brew upgrade by user choice."
    return 0
  }
  run_step "brew upgrade" brew upgrade
}

step_macports() {
  info "Checking MacPorts updates..."
  run_step "port selfupdate" sudo port selfupdate
  local outdated
  outdated=$(port outdated 2>/dev/null || true)
  if [[ -z "$outdated" || "$outdated" == *"No installed ports"* ]]; then
    success "MacPorts is up to date."
    return 0
  fi
  echo "$outdated"
  [[ "$CHECK_ONLY" -eq 1 ]] && return 0
  confirm "Upgrade outdated MacPorts packages?" || {
    warn "Skipped MacPorts upgrade by user choice."
    return 0
  }
  run_step "port upgrade outdated" sudo port upgrade outdated
}

step_pkg() {
  info "Checking FreeBSD pkg updates..."
  run_step "pkg update" sudo pkg update
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    sudo pkg upgrade -n
    return 0
  }
  confirm "Apply updates with 'sudo pkg upgrade'?" || {
    warn "Skipped pkg upgrade by user choice."
    return 0
  }
  run_step "pkg upgrade" sudo pkg upgrade
}

step_pkg_add() {
  info "Checking OpenBSD package updates..."
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    info "OpenBSD has no dry-run listing; use --yes to update."
    return 0
  }
  confirm "Apply updates with 'doas pkg_add -u' (falls back to sudo)?" || {
    warn "Skipped pkg_add upgrade by user choice."
    return 0
  }
  if command -v doas >/dev/null 2>&1; then
    run_step "pkg_add -u" doas pkg_add -u
  else
    run_step "pkg_add -u" sudo pkg_add -u
  fi
}

# --- Universal (cross-distro) managers, identical logic on every OS -----------

step_flatpak() {
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    info "flatpak: $(flatpak remote-ls --updates 2>/dev/null | wc -l) update(s) pending."
    return 0
  }
  run_step "Flatpak update" flatpak update -y
}

step_snap() {
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    info "snap: run 'snap refresh --list' manually to preview."
    return 0
  }
  run_step "Snap refresh" sudo snap refresh
}

step_nix() {
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    info "nix: preview not cheap to compute; use --yes to update."
    return 0
  }
  if command -v home-manager >/dev/null 2>&1; then
    run_step "Nix (home-manager)" home-manager switch
  else
    run_step "Nix channel update" nix-channel --update
    run_step "Nix env upgrade" nix-env -u '*'
  fi
}

step_cargo() {
  if command -v rustup >/dev/null 2>&1; then
    run_step "rustup update" rustup update
  fi
  if cargo install --list 2>/dev/null | grep -q .; then
    if command -v cargo-install-update >/dev/null 2>&1; then
      [[ "$CHECK_ONLY" -eq 1 ]] && return 0
      # cargo-install-update auto-detects cargo-binstall and uses it as a
      # backend when present, fetching prebuilt binaries instead of
      # recompiling from source -- no separate step needed for it.
      command -v cargo-binstall >/dev/null 2>&1 && info "cargo-binstall detected: updates will use prebuilt binaries where available."
      run_step "cargo install-update" cargo install-update -a
    else
      info "cargo has user-installed binaries but 'cargo-install-update' is not installed."
      info "Install it with: cargo install cargo-update"
    fi
  fi
}

step_uv() {
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    info "uv: no outdated-only listing for tools; use --yes to upgrade all."
    return 0
  }
  run_step "uv tool upgrade --all" uv tool upgrade --all
}

step_pnpm() {
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    pnpm outdated -g 2>/dev/null || true
    return 0
  }
  run_step "pnpm update -g" pnpm update -g
}

step_bun() {
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    info "bun: no outdated-only listing for global packages; use --yes to update."
    return 0
  }
  run_step "bun update -g" bun update -g
}

step_npm() {
  local outdated
  outdated=$(npm outdated -g --parseable 2>/dev/null || true)
  if [[ -z "$outdated" ]]; then
    success "Global npm packages are up to date."
    return 0
  fi
  npm outdated -g || true
  [[ "$CHECK_ONLY" -eq 1 ]] && return 0
  confirm "Update outdated global npm packages listed above?" || {
    warn "Skipped npm global upgrade by user choice."
    return 0
  }
  run_step "npm -g update" npm update -g
}

step_pipx() {
  [[ "$CHECK_ONLY" -eq 1 ]] && {
    info "pipx: run 'pipx list --outdated' manually to preview."
    return 0
  }
  run_step "pipx upgrade-all" pipx upgrade-all
}

# --- Registration: detection is fully separate from execution -----------------
#
# Add a package manager in exactly one place: register it here (guarded by
# whatever command -v / OS check makes sense) and define its step_<name>
# function above. run_updates() below never needs to change.

register_managers() {
  # System package managers - mutually exclusive in practice, but each
  # gets its own presence check so nothing is assumed from OS_FAMILY alone.
  command -v pacman >/dev/null 2>&1 && MANAGERS+=("pacman")
  command -v apt-get >/dev/null 2>&1 && MANAGERS+=("apt")
  command -v dnf >/dev/null 2>&1 && MANAGERS+=("dnf")
  command -v yum >/dev/null 2>&1 && MANAGERS+=("yum")
  command -v zypper >/dev/null 2>&1 && MANAGERS+=("zypper")
  command -v apk >/dev/null 2>&1 && MANAGERS+=("apk")
  command -v brew >/dev/null 2>&1 && MANAGERS+=("brew")
  command -v port >/dev/null 2>&1 && [[ "$OS_FAMILY" == "macos" ]] && MANAGERS+=("macports")
  command -v pkg >/dev/null 2>&1 && [[ "$OS_FAMILY" == "freebsd" ]] && MANAGERS+=("pkg")
  command -v pkg_add >/dev/null 2>&1 && [[ "$OS_FAMILY" == "openbsd" ]] && MANAGERS+=("pkg_add")

  # Universal / cross-distro managers
  command -v flatpak >/dev/null 2>&1 && MANAGERS+=("flatpak")
  command -v snap >/dev/null 2>&1 && MANAGERS+=("snap")
  { command -v nix-channel >/dev/null 2>&1 || command -v home-manager >/dev/null 2>&1; } && MANAGERS+=("nix")
  command -v cargo >/dev/null 2>&1 && MANAGERS+=("cargo")
  command -v npm >/dev/null 2>&1 && MANAGERS+=("npm")
  command -v pipx >/dev/null 2>&1 && MANAGERS+=("pipx")
  command -v uv >/dev/null 2>&1 && MANAGERS+=("uv")
  command -v pnpm >/dev/null 2>&1 && MANAGERS+=("pnpm")
  command -v bun >/dev/null 2>&1 && MANAGERS+=("bun")
}

run_updates() {
  if [[ "${#MANAGERS[@]}" -eq 0 ]]; then
    warn "No supported package manager found on this system."
    return
  fi

  local mgr
  local -a deferred=()

  # System managers run first, one at a time, in order. They share a package
  # database and a sudo ticket, and their prompts need a terminal to
  # themselves -- interleaving two of those is exactly the corruption this
  # script is written to avoid.
  for mgr in "${MANAGERS[@]}"; do
    if is_skipped "$mgr"; then
      info "Skipping $mgr (deselected)."
      continue
    fi
    declare -f "step_${mgr}" >/dev/null || continue

    case "$PARALLEL_SAFE" in
    *" $mgr "*)
      deferred+=("$mgr")
      continue
      ;;
    esac
    "step_${mgr}"
  done

  [[ "${#deferred[@]}" -eq 0 ]] && return 0

  # One left, or parallelism disabled: nothing to gain from the machinery.
  if [[ "${#deferred[@]}" -eq 1 || "$NO_PARALLEL" -eq 1 ]]; then
    for mgr in "${deferred[@]}"; do
      "step_${mgr}"
    done
    return 0
  fi

  section "User-space managers (${deferred[*]}) in parallel"
  info "These need no elevation and touch separate trees, so they run together."

  # Each writes to its own file rather than the shared terminal: concurrent
  # writers would interleave mid-line and make every failure unreadable. The
  # output is replayed in a fixed order afterwards, so a run stays diffable.
  local tmpdir
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME}-par.XXXXXX") || {
    warn "Could not create a temporary directory; running user-space managers sequentially."
    for mgr in "${deferred[@]}"; do
      "step_${mgr}"
    done
    return 0
  }

  local started ended
  started=$(date +%s)

  for mgr in "${deferred[@]}"; do
    ("step_${mgr}" >"${tmpdir}/${mgr}.out" 2>&1; echo "$?" >"${tmpdir}/${mgr}.rc") &
  done
  wait

  ended=$(date +%s)

  for mgr in "${deferred[@]}"; do
    section "$mgr"
    [[ -s "${tmpdir}/${mgr}.out" ]] && cat "${tmpdir}/${mgr}.out"
    cat "${tmpdir}/${mgr}.out" >>"$LOG_FILE" 2>/dev/null

    # A step that failed inside a subshell cannot append to FAILED_STEPS in
    # this one, so its status is carried back through a file instead.
    if [[ "$(cat "${tmpdir}/${mgr}.rc" 2>/dev/null || echo 1)" -ne 0 ]]; then
      case " ${FAILED_STEPS[*]:-} " in
      *" $mgr "*) ;;
      *) FAILED_STEPS+=("$mgr") ;;
      esac
    fi
  done

  rm -rf "$tmpdir"
  STEP_TIMINGS+=("user-space (parallel)=$((ended - started))")
  success "User-space managers finished in $((ended - started))s."
}

# --- Post-update checks (Linux/Arch-specific bits are self-guarded) -----------

check_pacnew() {
  command -v pacman >/dev/null 2>&1 || return 0
  local pacnew_files
  pacnew_files=$(find /etc -name '*.pacnew' 2>/dev/null || true)
  if [[ -n "$pacnew_files" ]]; then
    warn "New .pacnew config files were created. Review and merge them manually"
    warn "(e.g. with 'pacdiff'). This script will not auto-merge configs:"
    echo "$pacnew_files"
  else
    success "No pending .pacnew files."
  fi
}

check_reboot_needed() {
  [[ "$OS_KERNEL" == "Linux" ]] || return 0
  local running_kernel
  running_kernel="$(uname -r)"
  if [[ ! -d "/usr/lib/modules/${running_kernel}" && ! -d "/lib/modules/${running_kernel}" ]]; then
    warn "The running kernel's module directory for ${running_kernel} no longer exists."
    warn "A kernel update was applied. Reboot required to switch to the new kernel."
  fi
  [[ -f /var/run/reboot-required ]] && warn "/var/run/reboot-required exists (Debian/Ubuntu flag). Reboot recommended."
}

check_services_to_restart() {
  command -v needrestart >/dev/null 2>&1 || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  section "Services using outdated libraries"
  local services
  services=$(sudo needrestart -b 2>/dev/null | awk -F': ' '/^NEEDRESTART-SVC/{print $2}')
  if [[ -z "$services" ]]; then
    success "No services need a restart."
    return 0
  fi
  warn "The following services are still using outdated libraries in memory:"
  echo "$services"
  confirm "Restart these services now?" || {
    warn "Skipped service restarts by user choice."
    return 0
  }
  local svc
  for svc in $services; do
    run_step "Restart $svc" sudo systemctl restart "$svc"
  done
}

# --- Opt-in / risky extras -----------------------------------------------------

# Tries exactly one snapshot tool, first match wins -- same "one detected
# tool, not all of them" pattern as the AUR helper selection above. Each
# tool still asks for confirmation: timeshift in particular can take
# several minutes and real disk space depending on its backend, so this is
# never silent even under --snapshot.
step_system_snapshot() {
  [[ "$DO_SNAPSHOT" -eq 1 ]] || return 0
  section "System snapshot"
  if command -v snapper >/dev/null 2>&1; then
    confirm "Create a snapper snapshot before updating?" &&
      run_step "Snapper snapshot" sudo snapper create --description "pre-update-anything-${TIMESTAMP}"
  elif command -v timeshift >/dev/null 2>&1; then
    confirm "Create a Timeshift snapshot before updating? (can take a while and use real disk space)" &&
      run_step "Timeshift snapshot" sudo timeshift --create --comments "pre-update-anything" --scripted
  elif command -v bectl >/dev/null 2>&1; then
    confirm "Create a FreeBSD boot environment before updating?" &&
      run_step "bectl boot environment" sudo bectl create "pre-update-anything-${TIMESTAMP}"
  elif command -v zfs >/dev/null 2>&1 && command -v findmnt >/dev/null 2>&1 && [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == "zfs" ]]; then
    local root_dataset
    root_dataset=$(findmnt -no SOURCE / 2>/dev/null)
    confirm "Create a ZFS snapshot of ${root_dataset} before updating?" &&
      run_step "ZFS snapshot" sudo zfs snapshot "${root_dataset}@pre-update-anything-${TIMESTAMP}"
  elif [[ "$OS_KERNEL" == "Darwin" ]] && command -v tmutil >/dev/null 2>&1; then
    confirm "Create a local APFS snapshot before updating?" &&
      run_step "APFS snapshot" tmutil snapshot
  else
    warn "--snapshot requested but no supported snapshot tool found (snapper, timeshift, bectl, zfs-on-root, tmutil)."
  fi
}

step_deep_clean() {
  [[ "$DO_DEEP_CLEAN" -eq 1 ]] || return 0
  section "Deep clean (dev environments & containers)"
  local found=0
  if command -v flatpak >/dev/null 2>&1; then
    found=1
    confirm "Remove unused Flatpak runtimes ('flatpak remove --unused')?" &&
      run_step "Flatpak unused" flatpak remove --unused -y
  fi
  if command -v docker >/dev/null 2>&1; then
    found=1
    confirm "Prune dangling Docker images ('docker image prune')?" &&
      run_step "Docker prune" docker image prune -f
  fi
  if command -v podman >/dev/null 2>&1; then
    found=1
    confirm "Prune dangling Podman images ('podman image prune')?" &&
      run_step "Podman prune" podman image prune -f
  fi
  if command -v cargo-cache >/dev/null 2>&1; then
    found=1
    confirm "Clean cargo git/registry source caches ('cargo cache')?" &&
      run_step "Cargo cache" cargo cache --remove-dir git-db,registry-sources
  fi
  if command -v go >/dev/null 2>&1; then
    found=1
    confirm "Clean Go build/module cache ('go clean -cache -modcache')?" &&
      run_step "Go cache" go clean -cache -modcache
  fi
  [[ "$found" -eq 0 ]] && warn "--deep-clean requested but none of flatpak/docker/podman/cargo-cache/go were found."
}

step_audit() {
  [[ "$DO_AUDIT" -eq 1 ]] || return 0
  section "Security audit"
  local found=0
  if command -v arch-audit >/dev/null 2>&1; then
    found=1
    run_step "arch-audit" arch-audit
  fi
  # cargo-audit/npm audit are project-level tools (they need a Cargo.lock
  # or package-lock.json in the current directory), not system-wide
  # scanners -- so they're only run when that context actually exists,
  # never faked as a global check.
  if command -v cargo-audit >/dev/null 2>&1 && [[ -f Cargo.lock ]]; then
    found=1
    run_step "cargo audit" cargo audit
  fi
  if [[ "$found" -eq 0 ]]; then
    warn "--audit requested but no applicable audit tool found here."
    warn "arch-audit needs Arch Linux; cargo-audit needs to be run from"
    warn "inside a Rust project directory with a Cargo.lock -- neither is"
    warn "assumed, so nothing was run rather than running something wrong."
  fi
}

step_cache_clean() {
  [[ "$DO_CLEAN" -eq 1 ]] || return 0
  if command -v paccache >/dev/null 2>&1; then
    confirm "Clean pacman cache, keeping the 2 most recent versions of each package?" && run_step "paccache cleanup" sudo paccache -rk2
  elif command -v apt-get >/dev/null 2>&1; then
    confirm "Clean apt cache ('sudo apt-get autoclean')?" && run_step "apt-get autoclean" sudo apt-get autoclean
  elif command -v dnf >/dev/null 2>&1; then
    confirm "Clean dnf cache ('sudo dnf clean packages')?" && run_step "dnf clean" sudo dnf clean packages
  elif command -v brew >/dev/null 2>&1; then
    confirm "Clean Homebrew cache ('brew cleanup')?" && run_step "brew cleanup" brew cleanup
  else
    warn "--clean requested but no supported cache-cleaner found for this system."
  fi
}

step_orphans() {
  [[ "$DO_ORPHANS" -eq 1 ]] || return 0
  if command -v pacman >/dev/null 2>&1; then
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)
    [[ -z "$orphans" ]] && {
      success "No orphaned packages."
      return 0
    }
    echo "$orphans"
    # $orphans is a newline-separated package list and must word-split into
    # separate arguments; quoting it would hand pacman one argument containing
    # every package name.
    # shellcheck disable=SC2086
    confirm "Remove the orphaned packages listed above ('sudo pacman -Rns')?" && run_step "Remove orphans" sudo pacman -Rns $orphans
  elif command -v apt-get >/dev/null 2>&1; then
    confirm "Remove unused packages ('sudo apt-get autoremove')?" && run_step "apt-get autoremove" sudo apt-get autoremove
  elif command -v dnf >/dev/null 2>&1; then
    confirm "Remove unused packages ('sudo dnf autoremove')?" && run_step "dnf autoremove" sudo dnf autoremove
  else
    warn "--orphans requested but no supported orphan-cleaner found for this system."
  fi
}

step_firmware() {
  [[ "$DO_FIRMWARE" -eq 1 ]] || return 0
  command -v fwupdmgr >/dev/null 2>&1 || {
    warn "--firmware requested but fwupdmgr is not installed, skipping."
    return 0
  }
  run_step "fwupdmgr refresh" fwupdmgr refresh --force
  local updates
  updates=$(fwupdmgr get-updates 2>&1 || true)
  echo "$updates"
  echo "$updates" | grep -qi "No updates" && {
    success "No firmware updates available."
    return 0
  }
  confirm "Apply the firmware update(s) above? Do NOT power off during flashing." || {
    warn "Skipped firmware update by user choice."
    return 0
  }
  run_step "fwupdmgr update" fwupdmgr update
}

# --- CLI ------------------------------------------------------------------------

usage() {
  cat <<EOF
${C_BOLD}update-anything.sh${C_RESET} - safe, all-OS, all-package-manager updater

Usage: $(basename "$0") [options]

Auto-detects and updates whatever is actually installed (Linux, macOS,
FreeBSD, OpenBSD): pacman+AUR, apt, dnf, yum, zypper, apk, Homebrew,
MacPorts, FreeBSD pkg, OpenBSD pkg_add, Flatpak, Snap, Nix, cargo
(+ cargo-binstall), uv, pnpm, bun, npm globals, pipx. A manager that isn't
installed is silently skipped -- none of this is assumed present ahead of
time.

Options:
  -y, --yes         Skip this script's own confirmation prompts (package
                     managers' OWN destructive prompts are never
                     auto-answered).
  -c, --check       Dry run: only show what is pending, change nothing.
  --clean           Also clean the package cache, with confirmation.
  --orphans         Also remove orphaned packages, with confirmation.
  --firmware        Also check/apply firmware updates via fwupdmgr.
  --snapshot        Also create a system-level snapshot before updating
                     (snapper/timeshift/bectl/zfs/tmutil, whichever is
                     found first), with confirmation.
  --deep-clean      Also prune dev/container caches after updating
                     (flatpak unused runtimes, docker/podman dangling
                     images, cargo-cache, go build/module cache), each
                     with its own confirmation.
  --inhibit-sleep   Prevent the system from sleeping while this runs
                     (systemd-inhibit on Linux, caffeinate on macOS).
  --audit           Also run installed vulnerability-audit tools
                     (arch-audit; cargo audit only if a Cargo.lock is
                     present in the current directory) before updating.
  --rollback        Show a diff between the last two package snapshots and
                     exit. NOT an automatic downgrade -- just shows what
                     changed, so you know what to look at.
  --notify          Send a desktop notification when done (notify-send on
                     Linux, osascript on macOS).
  --no-<manager>    Skip one manager by name, e.g. --no-snap --no-brew.
  --only <manager>  Update only these, ignoring everything else. Repeatable
                     and comma-separated: --only flatpak,cargo. Takes
                     precedence over --no-<manager>.
  -q, --quiet       Print only warnings and errors. The log is unaffected,
                     so a cron job stays silent when it worked and speaks up
                     when it did not.
  --no-parallel     Run user-space managers one at a time. They are run
                     concurrently by default, since none of them need root
                     or share state; use this if you want readable live
                     output instead.
  -h, --help        Show this help.
  -v, --version     Show version and exit.

Exit status:
  0   every requested step succeeded (including --check/--help/--version)
  1   a step failed, or a pre-flight check refused to start
  130 interrupted

Held packages:
  Packages held back through your package manager's own mechanism
  (pacman IgnorePkg, apt-mark hold, dnf versionlock, brew pin, flatpak mask)
  are reported before updating, so a package that never moves is visible
  rather than mysterious. This script never overrides a hold, and never
  adds one -- use the manager's own command for that.

Config file:
  ~/.config/update-anything/config, if present, is sourced as shell code
  before CLI flags are parsed (so flags always override it). Use it to set
  your own defaults, e.g. DO_NOTIFY=1 or UPDATE_ANYTHING_WEBHOOK_URL=...
  Same trust model as hooks.d/ or your shell rc files.

Hooks:
  Executable scripts placed in
    ~/.config/update-anything/hooks.d/pre-update/
    ~/.config/update-anything/hooks.d/post-update/
  run in filename order, as your user (never elevated by this script).
  Useful for stopping heavy containers before updating, restarting a
  service after, or committing a dotfiles repo. Non-executable files in
  those directories are skipped with a warning, not silently run.

Webhook:
  Set UPDATE_ANYTHING_WEBHOOK_URL to a Discord/Slack-compatible webhook URL
  to get a one-line status message (hostname + outcome) at the end of the
  run. Unset by default -- nothing is ever sent anywhere unless you set it.

Safety notes:
  - Never run as root; sudo is invoked internally only where needed.
  - Never partial-upgrades a system package manager.
  - Never passes --noconfirm/-y to the underlying package manager: its own
    prompts about replacing/removing packages always stay interactive.
  - Aborts before touching anything if offline, disk is nearly full, battery
    is below 10% and discharging, or a pacman lock file suggests another
    instance is already running.
  - Writes a full log and an installed-package snapshot before updating,
    auto-purged after ${LOG_RETENTION_DAYS} days:
      Logs:      $LOG_DIR
      Snapshots: $SNAPSHOT_DIR
  - Orphan removal, cache cleanup, firmware updates, system snapshots and
    deep-clean are all opt-in only.
EOF
}

# Saved before the parsing loop consumes "$@" via shift, so --inhibit-sleep
# can re-exec this same script with the exact same arguments.
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
  -y | --yes) ASSUME_YES=1 ;;
  -c | --check) CHECK_ONLY=1 ;;
  --clean) DO_CLEAN=1 ;;
  --orphans) DO_ORPHANS=1 ;;
  --firmware) DO_FIRMWARE=1 ;;
  --snapshot) DO_SNAPSHOT=1 ;;
  --deep-clean) DO_DEEP_CLEAN=1 ;;
  --inhibit-sleep) DO_INHIBIT_SLEEP=1 ;;
  --audit) DO_AUDIT=1 ;;
  --rollback) show_rollback_diff ;;
  --notify) DO_NOTIFY=1 ;;
  -q | --quiet) QUIET=1 ;;
  --no-parallel) NO_PARALLEL=1 ;;
  --only)
    [[ -n "${2:-}" ]] || {
      error "--only needs a manager name, e.g. --only flatpak"
      exit 1
    }
    # Repeatable and comma-separated both work: --only a --only b, or --only a,b
    ONLY_LIST="${ONLY_LIST:- }$(printf '%s' "$2" | tr ',' ' ') "
    shift
    ;;
  # Must come after --no-parallel, or that flag would be read as a manager
  # named "parallel" and silently do nothing.
  --no-*) SKIP_LIST="${SKIP_LIST}${1#--no-} " ;;
  -h | --help)
    usage
    exit 0
    ;;
  -v | --version)
    echo "${SCRIPT_NAME} v${VERSION}"
    exit 0
    ;;
  *)
    error "Unknown option: $1"
    usage
    exit 1
    ;;
  esac
  shift
done

# Self-re-exec under a sleep inhibitor, once. UA_INHIBITED guards against
# looping forever once the child re-parses the same --inhibit-sleep flag.
# Placed before acquire_lock: exec replaces this process image entirely, so
# the lock is only ever acquired once, in whichever process actually
# continues past this point.
if [[ "$DO_INHIBIT_SLEEP" -eq 1 && "${UA_INHIBITED:-0}" -ne 1 ]]; then
  export UA_INHIBITED=1
  if command -v systemd-inhibit >/dev/null 2>&1; then
    exec systemd-inhibit --why="System update in progress" --who="$SCRIPT_NAME" "$0" "${ORIGINAL_ARGS[@]}"
  elif command -v caffeinate >/dev/null 2>&1; then
    exec caffeinate -i "$0" "${ORIGINAL_ARGS[@]}"
  else
    warn "--inhibit-sleep requested but neither systemd-inhibit nor caffeinate is installed."
  fi
fi

# --- Main -------------------------------------------------------------------

detect_os
require_not_root
acquire_lock

section "Pre-flight checks"
check_internet
[[ "$CHECK_ONLY" -eq 0 ]] && check_metered_connection
check_disk_space
[[ "$CHECK_ONLY" -eq 0 ]] && check_battery
check_pacman_lock
register_managers
info "Detected package managers: ${MANAGERS[*]:-none}"
[[ -n "$ONLY_LIST" ]] && info "Restricted to:${ONLY_LIST}(--only)"
report_holds
[[ "$CHECK_ONLY" -eq 0 ]] && warm_sudo
snapshot_packages

if [[ "$CHECK_ONLY" -eq 0 ]]; then
  run_hooks pre-update
  step_system_snapshot
fi
step_audit

run_updates

if [[ "$CHECK_ONLY" -eq 0 ]]; then
  section "Post-update checks"
  check_pacnew
  check_reboot_needed
  check_services_to_restart
  step_cache_clean
  step_orphans
  step_firmware
  step_deep_clean
  run_hooks post-update
fi

section "Summary"

# Where the time actually went. Sorted longest first, because the only reason
# to read this is to find out what to skip next time.
if [[ "${#STEP_TIMINGS[@]}" -gt 0 && "$QUIET" -eq 0 ]]; then
  printf '%s\n' "${STEP_TIMINGS[@]}" \
    | awk -F= '$2 >= 1 { printf "%6ds  %s\n", $2, $1 }' \
    | sort -rn \
    | head -10
  echo
fi

if [[ "${#FAILED_STEPS[@]}" -eq 0 ]]; then
  success "All requested steps completed."
  notify_user "System update" "All package managers updated successfully."
else
  warn "Completed with issues in: ${FAILED_STEPS[*]}"
  notify_user "System update" "Completed with issues: ${FAILED_STEPS[*]}"
fi

if [[ "$CHECK_ONLY" -eq 0 ]]; then
  send_webhook
fi

# The exit status is the contract for anything scripting this: zero only when
# every requested step succeeded, 1 when any of them failed.
#
# It has to be set explicitly. The EXIT trap propagates $?, so whatever ran
# last decided the status: `[[ "$CHECK_ONLY" -eq 0 ]] && send_webhook` returned
# false under --check and made a clean run exit 1, while a run with failed steps
# ended on a successful send_webhook and exited 0 — reporting success for a
# failed update, which is the worse half of the same bug.
if [[ "${#FAILED_STEPS[@]}" -gt 0 ]]; then
  exit 1
fi
exit 0
