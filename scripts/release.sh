#!/usr/bin/env bash

set -euo pipefail

TARGET="aarch64-apple-darwin"
SKIP_TAURI_BUILD="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Builds a full production release for Bike Potato.

Usage:
  ./scripts/release.sh [--target <rust-target>] [--skip-tauri-build]

Examples:
  ./scripts/release.sh
  ./scripts/release.sh --target x86_64-apple-darwin
  ./scripts/release.sh --skip-tauri-build
EOF
      exit 0
      ;;
    --skip-tauri-build)
      SKIP_TAURI_BUILD="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Target cannot be empty." >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command mix
require_command cargo

if ! cargo tauri --version >/dev/null 2>&1; then
  echo "Missing cargo-tauri CLI. Install with: cargo install tauri-cli" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELIXIR_DIR="$ROOT_DIR/src-elixir"
TAURI_DIR="$ROOT_DIR/src-tauri"
LOGO_SVG="$ELIXIR_DIR/priv/static/images/logo.svg"
ICON_DIR="$TAURI_DIR/icons"
ICON_FILES=(
  "32x32.png"
  "128x128.png"
  "128x128@2x.png"
  "icon.icns"
  "icon.ico"
)

BACKEND_RELEASE_NAME="lost_green_desktop"
BURRITO_OUTPUT="$ELIXIR_DIR/burrito_out/lost_green_desktop_macos"
SIDECAR_PATH="$TAURI_DIR/lost_green_backend-$TARGET"

if [[ ! -f "$LOGO_SVG" ]]; then
  echo "Expected icon source not found: $LOGO_SVG" >&2
  exit 1
fi

contains_icon_file() {
  local file="$1"
  for icon in "${ICON_FILES[@]}"; do
    if [[ "$icon" == "$file" ]]; then
      return 0
    fi
  done
  return 1
}

echo "==> Building backend release ($BACKEND_RELEASE_NAME)"
pushd "$ELIXIR_DIR" >/dev/null

if [[ -d "$HOME/Library/Application Support/.burrito" ]]; then
  find "$HOME/Library/Application Support/.burrito" \
    -maxdepth 1 \
    -type d \
    -name "${BACKEND_RELEASE_NAME}_erts-*" \
    -exec rm -rf {} +
fi

mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release "$BACKEND_RELEASE_NAME" --overwrite --path burrito_out
popd >/dev/null

if [[ ! -f "$BURRITO_OUTPUT" ]]; then
  echo "Expected Burrito output not found: $BURRITO_OUTPUT" >&2
  exit 1
fi

echo "==> Preparing sidecar: $SIDECAR_PATH"
cp -f "$BURRITO_OUTPUT" "$SIDECAR_PATH"
chmod +x "$SIDECAR_PATH"

if [[ "$SKIP_TAURI_BUILD" == "true" ]]; then
  echo "==> Skipping Tauri build (--skip-tauri-build)"
else
  echo "==> Building Tauri bundle for target: $TARGET"
  pushd "$TAURI_DIR" >/dev/null

  echo "==> Regenerating Tauri icons from: $LOGO_SVG"
  cargo tauri icon "$LOGO_SVG"

  echo "==> Pruning icons to configured bundle set"
  for path in "$ICON_DIR"/*; do
    file="$(basename "$path")"
    if ! contains_icon_file "$file"; then
      rm -rf "$path"
    fi
  done

  cargo tauri build --target "$TARGET"
  popd >/dev/null
  echo "Tauri bundle output: $TAURI_DIR/target/$TARGET/release/bundle"
fi

echo "==> Release complete"