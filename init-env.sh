#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: ./init-env.sh [--check]

Install the host dependencies required to build Bun.

  --check  Check the current environment without installing anything.
  --help   Show this help.

Linux and macOS use scripts/bootstrap.sh. Windows uses Visual Studio 2022,
winget, and Scoop as described in docs/project/building-windows.mdx.
After installation, run `source ./setenv.bun` in the current Bash shell.
EOF
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --check)
    check_only=1
    shift
    ;;
  "")
    check_only=0
    ;;
  *)
    echo "error: unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if (($# != 0)); then
  echo "error: unexpected arguments: $*" >&2
  exit 2
fi

kernel="$(uname -s)"
case "$kernel" in
  Linux)
    host_os=linux
    ;;
  Darwin)
    host_os=darwin
    ;;
  MINGW*|MSYS*|CYGWIN*)
    host_os=windows
    ;;
  *)
    echo "error: unsupported operating system: $kernel" >&2
    exit 1
    ;;
esac

source "$repo_root/setenv.bun" --quiet

check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    check_failed=1
  fi
}

scoop_llvm_path() {
  local scoop_root="${SCOOP:-$HOME/scoop}"
  if command -v cygpath >/dev/null 2>&1 && [[ "$scoop_root" =~ ^[A-Za-z]:\\ ]]; then
    scoop_root="$(cygpath -u "$scoop_root")"
  fi
  printf '%s/apps/llvm/current/bin/clang-cl.exe\n' "$scoop_root"
}

check_environment() {
  check_failed=0

  for command_name in bun cargo rustc cmake ninja node go perl ruby; do
    check_command "$command_name"
  done

  if [[ "$host_os" == windows ]]; then
    check_command pwsh
    check_command nasm

    vswhere='/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
    if [[ ! -f "$vswhere" ]]; then
      echo "error: Visual Studio 2022 with Desktop development with C++ was not found" >&2
      check_failed=1
    fi

    # Prefer Scoop's pinned LLVM even when a machine-wide LLVM has an older
    # PATH position. Bun's tool discovery likewise skips incompatible versions.
    scoop_llvm="$(scoop_llvm_path)"
    if [[ -x "$scoop_llvm" ]]; then
      llvm_output="$("$scoop_llvm" --version 2>/dev/null || true)"
    else
      llvm_output="$(clang-cl --version 2>/dev/null || true)"
    fi
  else
    check_command clang
    llvm_output="$(clang --version 2>/dev/null || true)"
  fi

  if [[ ! "$llvm_output" =~ version[[:space:]]+21\.1\.[0-9]+ ]]; then
    echo "error: Bun requires LLVM 21.1.x; the selected compiler reports:" >&2
    printf '%s\n' "${llvm_output:-  (compiler not found)}" >&2
    check_failed=1
  fi

  if ((check_failed)); then
    echo "Environment check failed. Run ./init-env.sh to install missing dependencies." >&2
    return 1
  fi

  echo "Environment is ready for a Bun build ($host_os)."
}

if ((check_only)); then
  check_environment
  exit
fi

if [[ "$host_os" != windows ]]; then
  exec ./scripts/bootstrap.sh
fi

if ! command -v winget >/dev/null 2>&1; then
  echo "error: winget is required to install Windows build dependencies" >&2
  exit 1
fi

vswhere='/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
if [[ ! -f "$vswhere" ]]; then
  winget install --id Microsoft.VisualStudio.2022.Community --exact \
    --override '--wait --passive --add Microsoft.VisualStudio.Workload.NativeDesktop Microsoft.VisualStudio.Component.Git' \
    --accept-package-agreements --accept-source-agreements
fi

if ! command -v pwsh >/dev/null 2>&1 && [[ ! -x '/c/Program Files/PowerShell/7/pwsh.exe' ]]; then
  winget install --id Microsoft.PowerShell --exact \
    --accept-package-agreements --accept-source-agreements
fi

if ! command -v scoop >/dev/null 2>&1; then
  echo "error: Scoop is required for the remaining Windows dependencies" >&2
  echo "Install Scoop once, then rerun this script:" >&2
  echo "  powershell -NoProfile -Command \"irm https://get.scoop.sh | iex\"" >&2
  exit 1
fi

scoop install nodejs-lts go rustup nasm ruby perl ccache
# Keep this exact pin synchronized with scripts/build/tools.ts.
scoop install llvm@21.1.8

if ! command -v bun >/dev/null 2>&1; then
  scoop install bun
fi

source "$repo_root/setenv.bun" --quiet

cat <<'EOF'

Windows dependencies were installed. Load the environment, then run:

  source ./setenv.bun
  ./init-env.sh --check
  ./comp.sh
EOF
