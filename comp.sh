#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: ./comp.sh [options]

Build Bun's Rust static library with Cargo, then link the Bun executable.

Options:
  --debug         Build the debug profile (default).
  --release       Build the release profile.
  --cargo-only    Stop after cargo builds bun_bin as a static library.
  -j N, --jobs N  Set Ninja's parallel job count.
  --help          Show this help.

Cargo alone cannot produce bun.exe: src/bun_bin is a staticlib which must be
linked with Bun's C/C++ and JavaScriptCore objects by the native build system.
The script automatically loads environment paths from setenv.bun.
EOF
}

profile=debug
cargo_only=0
ninja_args=()

while (($#)); do
  case "$1" in
    --debug)
      profile=debug
      shift
      ;;
    --release)
      profile=release
      shift
      ;;
    --cargo-only)
      cargo_only=1
      shift
      ;;
    -j|--jobs)
      if (($# < 2)) || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: $1 requires a positive integer" >&2
        exit 2
      fi
      ninja_args+=("-j$2")
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

source "$repo_root/setenv.bun" --quiet

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required to run code generation and the native build" >&2
  echo "Run ./init-env.sh first." >&2
  exit 1
fi

echo "==> Building Rust crates with Cargo ($profile)"
bun scripts/build.ts --profile="$profile" "${ninja_args[@]}" --target=bun-rust

if ((cargo_only)); then
  echo "Cargo stage complete. Bun's Rust output is a static library, not an executable."
  exit 0
fi

echo "==> Linking Bun executable ($profile)"
bun scripts/build.ts --profile="$profile" "${ninja_args[@]}"

exe_suffix=""
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) exe_suffix=".exe" ;;
esac

if [[ "$profile" == debug ]]; then
  output="$repo_root/build/debug/bun-debug$exe_suffix"
else
  output="$repo_root/build/release/bun$exe_suffix"
fi

if [[ ! -f "$output" ]]; then
  echo "error: build completed but the expected executable was not found: $output" >&2
  exit 1
fi

echo "Built executable: $output"
"$output" --revision
