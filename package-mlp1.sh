#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$ROOT_DIR/workdir/mlp1}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/ppsspp}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-$ROOT_DIR/output/mlp1/build}"

PPSSPP_VERSION="${PPSSPP_VERSION:-v1.20.3}"
PPSSPP_BINARY="${PPSSPP_BINARY:-$BUILD_OUTPUT_DIR/PPSSPPSDL_MLP1}"
PPSSPP_ASSETS_DIR="${PPSSPP_ASSETS_DIR:-$BUILD_OUTPUT_DIR/assets}"
PPSSPP_RUNTIME_LIB_DIR="${PPSSPP_RUNTIME_LIB_DIR:-$BUILD_OUTPUT_DIR/lib}"

write_launch_script() {
    local path="$OUTPUT_DIR/launch.sh"
    cat >"$path" <<'EOF'
#!/bin/sh
set -eu

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -f "$SELF_DIR/../../launcher/env.sh" ]; then
    . "$SELF_DIR/../../launcher/env.sh"
elif [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    . "$UMRK_ENV_FILE"
fi

if [ "$#" -lt 1 ]; then
    echo "usage: launch.sh <rom-path>" >&2
    exit 64
fi

ROM_PATH="$1"
STATE_ROOT="${UMRK_PLATFORM_PATH:-${SYSTEM_PATH:-$SELF_DIR/../..}}/state/ppsspp"
LOG_ROOT="${LOGS_PATH:-$STATE_ROOT/logs}"

mkdir -p \
    "$STATE_ROOT/home" \
    "$STATE_ROOT/config" \
    "$STATE_ROOT/config/ppsspp/PSP/SYSTEM" \
    "$STATE_ROOT/data" \
    "$STATE_ROOT/data/ppsspp" \
    "$STATE_ROOT/cache" \
    "$LOG_ROOT"

export HOME="$STATE_ROOT/home"
export XDG_CONFIG_HOME="$STATE_ROOT/config"
export XDG_DATA_HOME="$STATE_ROOT/data"
export XDG_CACHE_HOME="$STATE_ROOT/cache"
export LD_LIBRARY_PATH="$SELF_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SDL_VIDEODRIVER="${PPSSPP_SDL_VIDEODRIVER:-kmsdrm}"
export SDL_KMSDRM_REQUIRE_DRM_MASTER="${SDL_KMSDRM_REQUIRE_DRM_MASTER:-0}"
export DISPLAY_ROTATION="${PPSSPP_DISPLAY_ROTATION:-${DISPLAY_ROTATION:-270}}"

exec "$SELF_DIR/bin/PPSSPPSDL" "$ROM_PATH" >>"$LOG_ROOT/ppsspp.log" 2>&1
EOF
    chmod 755 "$path"
}

write_manifest() {
    cat >"$OUTPUT_DIR/manifest.json" <<EOF
{
  "id": "ppsspp",
  "name": "PPSSPP",
  "platform": "mlp1",
  "kind": "standalone-emulator",
  "source_repo": "hrydgard/ppsspp",
  "ppsspp_version": "$PPSSPP_VERSION",
  "toolchain": "UMRK mlp1-toolchain",
  "patch_set": "common + a30/display-rotation + flip",
  "default_sdl_video_driver": "kmsdrm",
  "default_display_rotation": 270,
  "entrypoint": "launch.sh",
  "binary": "bin/PPSSPPSDL"
}
EOF
}

main() {
    if [ ! -x "$PPSSPP_BINARY" ]; then
        echo "missing PPSSPP binary: $PPSSPP_BINARY" >&2
        echo "run: make build-mlp1" >&2
        exit 1
    fi
    if [ ! -d "$PPSSPP_ASSETS_DIR" ]; then
        echo "missing PPSSPP assets: $PPSSPP_ASSETS_DIR" >&2
        echo "run: make build-mlp1" >&2
        exit 1
    fi

    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/lib"

    cp -f "$PPSSPP_BINARY" "$OUTPUT_DIR/bin/PPSSPPSDL"
    chmod 755 "$OUTPUT_DIR/bin/PPSSPPSDL"
    cp -R "$PPSSPP_ASSETS_DIR" "$OUTPUT_DIR/bin/assets"
    if [ -d "$PPSSPP_RUNTIME_LIB_DIR" ]; then
        find "$PPSSPP_RUNTIME_LIB_DIR" -maxdepth 1 -type f -print0 |
            while IFS= read -r -d '' lib; do
                cp -f "$lib" "$OUTPUT_DIR/lib/$(basename "$lib")"
                chmod 755 "$OUTPUT_DIR/lib/$(basename "$lib")"
            done
    fi

    write_launch_script
    write_manifest

    cat >"$OUTPUT_DIR/README.txt" <<EOF
PPSSPP standalone payload for UMRK MLP1.

Launch through Jawaka with a PSP .chd, .iso, .cso, or .pbp file.
The binary is built from PPSSPP source with the UMRK MLP1 toolchain.
The launch wrapper defaults to SDL KMSDRM and DISPLAY_ROTATION=270 for the
MLP1 portrait panel. Override with PPSSPP_SDL_VIDEODRIVER or
PPSSPP_DISPLAY_ROTATION when testing another display path.
The launch wrapper stores PPSSPP HOME/XDG state under the Leaf platform state
directory on the SD card.
EOF

    find "$OUTPUT_DIR" -maxdepth 3 -type f | sort
}

main "$@"
