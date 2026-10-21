#!/bin/sh
# Bootstrap for the cache-test harness. Runs on a machine with nothing on it, so it stays
# POSIX sh: no arrays, no [[ ]], no ${var,,}. Its only job is to produce a usable python3 and
# hand over to setup.py, which does the actual onboarding.
#
# Two things have to happen before python3 can be trusted to drive the rest:
#   - bash 4+, because deploy/62,63,66,68 use `mapfile` and macOS ships bash 3.2
#   - python3 itself, which every deploy script already needs for its JSON reads
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
ask() { # ask <question> -> 0 if yes
  printf '    %s [y/N] ' "$1"
  read -r _a || return 1
  case "$_a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# --- platform -------------------------------------------------------------------------
OS=$(uname -s)
case "$OS" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) echo "Unsupported platform: $OS. This harness is bash + linux-x64 only." >&2; exit 1 ;;
esac

PKG=none
for p in brew apt-get dnf pacman zypper; do
  if command -v "$p" >/dev/null 2>&1; then PKG=$p; break; fi
done

# Already root (a container, a VM image build) means sudo is both unnecessary and usually
# absent. Hardcoding `sudo` makes every install fail with "sudo: not found".
SUDO=
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO=sudo
  else SUDO=NEED_ROOT; fi
fi

say "Platform"
note "$OS $(uname -m), package manager: $PKG"

if [ "$PKG" = none ]; then
  note "No supported package manager found. Install python3 (and bash 4+) by hand, then re-run."
fi

# pkg_install <brew-formula> <apt-pkg> <dnf-pkg> <pacman-pkg> -- prints the command, then runs
# it only after the user agrees. sudo is never silent.
pkg_install() {
  if [ "$SUDO" = NEED_ROOT ] && [ "$PKG" != brew ]; then
    note "Installing needs root, and sudo is not available. Install it by hand, then re-run."
    return 1
  fi
  _cmd=
  case "$PKG" in
    brew)    [ -n "$1" ] && _cmd="brew install $1" ;;
    apt-get) [ -n "$2" ] && _cmd="$SUDO apt-get update && $SUDO apt-get install -y $2" ;;
    dnf)     [ -n "$3" ] && _cmd="$SUDO dnf install -y $3" ;;
    pacman)  [ -n "$4" ] && _cmd="$SUDO pacman -S --noconfirm $4" ;;
    zypper)  [ -n "$3" ] && _cmd="$SUDO zypper install -y $3" ;;
  esac
  if [ -z "$_cmd" ]; then
    note "No install command known for $PKG. Install it by hand, then re-run."
    return 1
  fi
  note "will run: $_cmd"
  ask "run it?" || return 1
  sh -c "$_cmd"
}

# --- bash 4+ --------------------------------------------------------------------------
# The shim itself is sh, but the deploy scripts it leads to are bash 4. Catching that here
# beats discovering it as an empty `mapfile` array halfway through collecting an arm.
say "bash"
BASH_BIN=$(command -v bash 2>/dev/null || true)
BASH_MAJOR=0
if [ -n "$BASH_BIN" ]; then
  BASH_MAJOR=$("$BASH_BIN" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)
fi

if [ "$BASH_MAJOR" -ge 4 ]; then
  note "bash $("$BASH_BIN" -c 'echo $BASH_VERSION') at $BASH_BIN"
else
  note "bash ${BASH_MAJOR}.x at ${BASH_BIN:-not found}"
  note "deploy/62,63,66,68 use mapfile, which needs bash 4 or newer."
  # Homebrew installs a modern bash alongside the system 3.2 rather than replacing it.
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$b" ]; then BASH_BIN=$b; BASH_MAJOR=4; note "found a newer bash at $b"; break; fi
  done
  if [ "$BASH_MAJOR" -lt 4 ]; then
    pkg_install bash bash bash bash || true
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
      if [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]; then
        BASH_BIN=$b; BASH_MAJOR=4; break
      fi
    done
  fi
  if [ "$BASH_MAJOR" -lt 4 ]; then
    note "Still on bash 3.x. Onboarding will continue, but the deploy scripts will not run."
  elif [ "${BASH_BIN%/*}" != "/usr/bin" ]; then
    note "Put ${BASH_BIN%/*} ahead of /bin on PATH so the deploy scripts pick it up."
  fi
fi

# --- python3 --------------------------------------------------------------------------
say "python3"
if ! command -v python3 >/dev/null 2>&1; then
  note "not found. Every deploy script needs it, and so does the rest of this setup."
  pkg_install python python3 python3 python || true
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is still missing. Install it and re-run $0." >&2
  exit 1
fi
note "$(python3 --version) at $(command -v python3)"

exec python3 "$HERE/setup.py" "$@"
