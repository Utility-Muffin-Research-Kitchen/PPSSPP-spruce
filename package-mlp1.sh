#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$ROOT_DIR/workdir/mlp1}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/ppsspp}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-$ROOT_DIR/output/mlp1/build}"

PPSSPP_VERSION="${PPSSPP_VERSION:-v1.20.4}"
MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-perf}"
if [ -f "$ROOT_DIR/../mlp1-toolchain/flags/mlp1-build-flags.env" ]; then
    . "$ROOT_DIR/../mlp1-toolchain/flags/mlp1-build-flags.env"
else
    UMRK_MLP1_TARGET_SOC="rk3566"
    UMRK_MLP1_TARGET_CPU="cortex-a55"
    UMRK_MLP1_PROFILE_CFLAGS="-O3 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_CXXFLAGS="-O3 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_LDFLAGS="-Wl,--gc-sections"
fi
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
if [ ! -f "$ROM_PATH" ]; then
    echo "PPSSPP ROM does not exist: $ROM_PATH" >&2
    exit 66
fi

PLATFORM_ROOT="${UMRK_PLATFORM_PATH:-${SYSTEM_PATH:-$SELF_DIR/../..}}"
if [ -n "${USERDATA_PATH:-}" ]; then
    STATE_ROOT="$USERDATA_PATH/ppsspp"
elif [ -n "${SDCARD_PATH:-}" ]; then
    STATE_ROOT="$SDCARD_PATH/.userdata/${PLATFORM:-mlp1}/ppsspp"
else
    STATE_ROOT="$SELF_DIR/.userdata/ppsspp"
fi
LOG_ROOT="${LOGS_PATH:-$STATE_ROOT/logs}"
OLD_STATE_ROOT="$PLATFORM_ROOT/state/ppsspp"

# The first UMRK PPSSPP package accidentally kept state below the
# release-managed platform tree. Copy it once when the durable root is absent;
# keep the old copy for rollback.
if [ ! -e "$STATE_ROOT" ] && [ -d "$OLD_STATE_ROOT" ]; then
    mkdir -p "$(dirname "$STATE_ROOT")"
    cp -R "$OLD_STATE_ROOT" "$STATE_ROOT"
    mkdir -p "$STATE_ROOT/.umrk-migrations"
    : >"$STATE_ROOT/.umrk-migrations/platform-state-to-userdata-v1"
fi

mkdir -p \
    "$STATE_ROOT/home" \
    "$STATE_ROOT/config" \
    "$STATE_ROOT/config/ppsspp/PSP/SYSTEM" \
    "$STATE_ROOT/data" \
    "$STATE_ROOT/data/ppsspp" \
    "$STATE_ROOT/cache" \
    "$LOG_ROOT"

# Seed the default control mapping on first run so the Loong Gamepad shoulder
# buttons (L1/R1) work out of the box. Never clobber a user's own remap.
CONTROLS="$STATE_ROOT/config/ppsspp/PSP/SYSTEM/controls.ini"
if [ ! -f "$CONTROLS" ] && [ -f "$SELF_DIR/defaults/controls.ini" ]; then
    cp "$SELF_DIR/defaults/controls.ini" "$CONTROLS"
fi

PPSSPP_INI="$STATE_ROOT/config/ppsspp/PSP/SYSTEM/ppsspp.ini"
PRESET="${PPSSPP_PRESET:-balanced}"
case "$PRESET" in
    balanced|performance) ;;
    *)
        echo "unsupported PPSSPP_PRESET: $PRESET" >&2
        exit 64
        ;;
esac
if [ ! -f "$PPSSPP_INI" ] && [ -f "$SELF_DIR/defaults/ppsspp-$PRESET.ini" ]; then
    cp "$SELF_DIR/defaults/ppsspp-$PRESET.ini" "$PPSSPP_INI"
fi

export HOME="$STATE_ROOT/home"
export XDG_CONFIG_HOME="$STATE_ROOT/config"
export XDG_DATA_HOME="$STATE_ROOT/data"
export XDG_CACHE_HOME="$STATE_ROOT/cache"
INHERITED_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export SDL_VIDEODRIVER="${PPSSPP_SDL_VIDEODRIVER:-kmsdrm}"

BACKEND="${PPSSPP_BACKEND:-vulkan}"
ROTATION_MODE="${PPSSPP_ROTATION_MODE:-}"
VULKAN_ROOT="${PPSSPP_VULKAN_ROOT:-$PLATFORM_ROOT/runtime/graphics/vulkan/rk3566-g52-g29p1}"
ICD_PATH="$VULKAN_ROOT/share/vulkan/icd.d/rk_vk_g29.json"
DRIVER_PATH="$VULKAN_ROOT/lib/libmali.so.1"

case "$BACKEND" in
    vulkan)
        ROTATION_MODE="${ROTATION_MODE:-native}"
        if [ ! -f "$DRIVER_PATH" ] || [ ! -f "$ICD_PATH" ]; then
            echo "PPSSPP Vulkan runtime is incomplete: $VULKAN_ROOT" >&2
            echo "Select the PPSSPP GLES core or restage the MLP1 graphics runtime." >&2
            exit 69
        fi
        case "${JAWAKA_DIRECT_DRM:-0}" in
            1|true|yes|TRUE|YES) ;;
            *)
                case "${PPSSPP_ALLOW_NO_DIRECT_DRM:-0}" in
                    1|true|yes|TRUE|YES) ;;
                    *)
                        echo "PPSSPP Vulkan requires Jawaka's direct-DRM handoff." >&2
                        exit 75
                        ;;
                esac
                ;;
        esac
        export LD_LIBRARY_PATH="$VULKAN_ROOT/lib:$SELF_DIR/lib${INHERITED_LD_LIBRARY_PATH:+:$INHERITED_LD_LIBRARY_PATH}"
        export VK_ICD_FILENAMES="$ICD_PATH"
        case "${VK_LOADER_LAYERS_DISABLE:-}" in
            *VK_LAYER_window_system_integration*) ;;
            "") export VK_LOADER_LAYERS_DISABLE="VK_LAYER_window_system_integration" ;;
            *) export VK_LOADER_LAYERS_DISABLE="$VK_LOADER_LAYERS_DISABLE,VK_LAYER_window_system_integration" ;;
        esac
        export SDL_KMSDRM_REQUIRE_DRM_MASTER="${SDL_KMSDRM_REQUIRE_DRM_MASTER:-1}"
        case "$ROTATION_MODE" in
            native)
                export DISPLAY_ROTATION="${PPSSPP_DISPLAY_ROTATION:-270}"
                ;;
            rga-shim)
                DRM_ROTATE_SHIM="${PPSSPP_DRM_ROTATE_SHIM:-}"
                if [ -z "$DRM_ROTATE_SHIM" ] &&
                   [ -f "$PLATFORM_ROOT/runtime/graphics/drm-rotate/aarch64/leaf-drm-rotate.so" ]; then
                    DRM_ROTATE_SHIM="$PLATFORM_ROOT/runtime/graphics/drm-rotate/aarch64/leaf-drm-rotate.so"
                fi
                PORTMASTER_DATA_ROOT="${PORTMASTER_MLP1_DATA_DIR:-${USERDATA_PATH:+$USERDATA_PATH/portmaster}}"
                if [ -z "$DRM_ROTATE_SHIM" ] &&
                   [ -n "$PORTMASTER_DATA_ROOT" ] &&
                   [ -f "$PORTMASTER_DATA_ROOT/compat/drm/aarch64/leaf-drm-rotate.so" ]; then
                    DRM_ROTATE_SHIM="$PORTMASTER_DATA_ROOT/compat/drm/aarch64/leaf-drm-rotate.so"
                fi
                if [ ! -f "$DRM_ROTATE_SHIM" ]; then
                    echo "PPSSPP's optional DRM rotation shim is unavailable." >&2
                    echo "Install the PortMaster Pak or set PPSSPP_DRM_ROTATE_SHIM explicitly." >&2
                    exit 69
                fi
                export DISPLAY_ROTATION=0
                export LEAF_DRM_ROTATE="${LEAF_DRM_ROTATE:-270}"
                case ":${LD_PRELOAD:-}:" in
                    *:"$DRM_ROTATE_SHIM":*) ;;
                    *) export LD_PRELOAD="$DRM_ROTATE_SHIM${LD_PRELOAD:+:$LD_PRELOAD}" ;;
                esac
                ;;
            *)
                echo "unsupported Vulkan PPSSPP_ROTATION_MODE: $ROTATION_MODE" >&2
                exit 64
                ;;
        esac
        ;;
    gles)
        ROTATION_MODE="${ROTATION_MODE:-gles}"
        if [ "$ROTATION_MODE" != "gles" ]; then
            echo "GLES requires PPSSPP_ROTATION_MODE=gles" >&2
            exit 64
        fi
        unset VK_ICD_FILENAMES
        if [ -n "$INHERITED_LD_LIBRARY_PATH" ]; then
            export LD_LIBRARY_PATH="$INHERITED_LD_LIBRARY_PATH"
        else
            unset LD_LIBRARY_PATH
        fi
        export SDL_KMSDRM_REQUIRE_DRM_MASTER="${SDL_KMSDRM_REQUIRE_DRM_MASTER:-0}"
        export DISPLAY_ROTATION="${PPSSPP_DISPLAY_ROTATION:-270}"
        ;;
    *)
        echo "unsupported PPSSPP_BACKEND: $BACKEND" >&2
        exit 64
        ;;
esac

{
    printf '%s\n' "=== UMRK PPSSPP launch ==="
    printf 'version=%s backend=%s rotation=%s preset=%s direct_drm=%s\n' \
        "v1.20.4" "$BACKEND" "$ROTATION_MODE" "$PRESET" "${JAWAKA_DIRECT_DRM:-0}"
    printf 'state=%s\n' "$STATE_ROOT"
    if [ "$BACKEND" = "vulkan" ]; then
        printf 'vulkan_root=%s icd=%s\n' "$VULKAN_ROOT" "$ICD_PATH"
    fi
} >>"$LOG_ROOT/ppsspp.log"

exec "$SELF_DIR/bin/PPSSPPSDL" --fullscreen "--graphics=$BACKEND" "$ROM_PATH" \
    >>"$LOG_ROOT/ppsspp.log" 2>&1
EOF
    chmod 755 "$path"

    cat >"$OUTPUT_DIR/launch-gles.sh" <<'EOF'
#!/bin/sh
set -eu
SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PPSSPP_BACKEND=gles
export PPSSPP_ROTATION_MODE=gles
export PPSSPP_SDL_VIDEODRIVER="${PPSSPP_GLES_SDL_VIDEODRIVER:-wayland}"
export PPSSPP_DISPLAY_ROTATION="${PPSSPP_GLES_DISPLAY_ROTATION:-0}"
exec "$SELF_DIR/launch.sh" "$@"
EOF
    chmod 755 "$OUTPUT_DIR/launch-gles.sh"
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
  "target_soc": "$UMRK_MLP1_TARGET_SOC",
  "target_cpu": "$UMRK_MLP1_TARGET_CPU",
  "build_profile": "$MLP1_BUILD_PROFILE",
  "cflags": "$UMRK_MLP1_PROFILE_CFLAGS",
  "cxxflags": "$UMRK_MLP1_PROFILE_CXXFLAGS",
  "ldflags": "$UMRK_MLP1_PROFILE_LDFLAGS",
  "patch_set": "common + mlp1/display-rotation + mlp1/command-line-backend + flip",
  "graphics_backends": ["vulkan-display", "gles"],
  "default_graphics_backend": "vulkan-display",
  "vulkan_runtime": "rk3566-g52-g29p1",
  "rotation_modes": ["native", "rga-shim", "gles"],
  "direct_drm_required_for": ["vulkan-display"],
  "default_sdl_video_driver": "kmsdrm",
  "default_display_rotation": 270,
  "fallback_sdl_video_driver": "wayland",
  "fallback_display_rotation": 0,
  "entrypoint": "launch.sh",
  "fallback_entrypoint": "launch-gles.sh",
  "binary": "bin/PPSSPPSDL",
  "exceptions": []
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

    # Default control mapping seeded on first run (Loong Gamepad L1/R1 fix).
    if [ -f "$ROOT_DIR/config/controls.ini" ]; then
        mkdir -p "$OUTPUT_DIR/defaults"
        cp -f "$ROOT_DIR/config/controls.ini" "$OUTPUT_DIR/defaults/controls.ini"
    fi
    for preset in balanced performance; do
        if [ -f "$ROOT_DIR/config/ppsspp-$preset.ini" ]; then
            mkdir -p "$OUTPUT_DIR/defaults"
            cp -f "$ROOT_DIR/config/ppsspp-$preset.ini" \
                "$OUTPUT_DIR/defaults/ppsspp-$preset.ini"
        fi
    done

    write_launch_script
    write_manifest

    cat >"$OUTPUT_DIR/README.txt" <<EOF
PPSSPP standalone payload for UMRK MLP1.

Launch through Jawaka with a PSP .chd, .iso, .cso, or .pbp file.
The binary is built from PPSSPP source with the UMRK MLP1 toolchain.
The default launch wrapper uses direct-display Vulkan with the shared MLP1 g29
graphics runtime and native PPSSPP portrait-panel rotation. launch-gles.sh is a
composited GLES recovery path. PPSSPP state is durable under USERDATA_PATH.
PPSSPP_PRESET=balanced (default) or performance selects first-run defaults;
existing user configuration is never overwritten.
EOF

    find "$OUTPUT_DIR" -maxdepth 3 -type f | sort
}

main "$@"
