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
# LOG-SAFE-1. The session log lives on a FAT card and can go unwritable (a bad
# cluster chain, a full card, or the FAT32 4 GiB per-file ceiling). stdout and
# stderr here are inherited from the launcher and point at that file. Under
# set -e a failed echo would abort this script and the game would never start,
# so probe both once and fall back to /dev/null, then never let a log write
# decide whether a game launches.
leaf_log_probe() {
    # A real byte, not a zero-length write: a 0-byte write can succeed without
    # touching the device and would not detect EIO/EFBIG. The subshell ignores
    # SIGXFSZ: at the FAT32 ceiling the kernel raises it and its default action
    # would kill this shell before the write could fail with EFBIG.
    ( trap '' XFSZ; printf '\n' ) 2>/dev/null
}
leaf_log_probe >/dev/null 2>&1 || true
if ! leaf_log_probe; then
    exec >/dev/null
fi
if ! leaf_log_probe >&2; then
    exec 2>/dev/null
fi

log() { ( trap '' XFSZ; printf '%s\n' "$*" ) 2>/dev/null || true; }

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if [ -f "$SELF_DIR/../../launcher/env.sh" ]; then
    . "$SELF_DIR/../../launcher/env.sh"
elif [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    . "$UMRK_ENV_FILE"
fi

if [ "$#" -lt 1 ]; then
    log "usage: launch.sh <rom-path>"
    exit 64
fi

ROM_PATH="$1"
if [ ! -f "$ROM_PATH" ]; then
    log "PPSSPP ROM does not exist: $ROM_PATH"
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

# Seed the default control mapping on first run so the Loong Gamepad controls
# work out of the box.
CONTROLS="$STATE_ROOT/config/ppsspp/PSP/SYSTEM/controls.ini"
if [ ! -f "$CONTROLS" ] && [ -f "$SELF_DIR/defaults/controls.ini" ]; then
    cp "$SELF_DIR/defaults/controls.ini" "$CONTROLS"
fi

# Correct the original shipped Square/Triangle pair once, but only while both
# entries still exactly match that old default. Any user remap is left alone.
CONTROL_MIGRATIONS="$STATE_ROOT/.umrk-migrations"
CONTROL_FACE_FIX="$CONTROL_MIGRATIONS/controls-square-triangle-v1"
if [ ! -e "$CONTROL_FACE_FIX" ]; then
    mkdir -p "$CONTROL_MIGRATIONS"
    if [ -f "$CONTROLS" ] &&
       grep -q '^Square = 1-29,10-191$' "$CONTROLS" &&
       grep -q '^Triangle = 1-47,10-188$' "$CONTROLS"; then
        CONTROLS_NEW="$CONTROLS.umrk-new"
        sed \
            -e 's/^Square = 1-29,10-191$/Square = 1-29,10-188/' \
            -e 's/^Triangle = 1-47,10-188$/Triangle = 1-47,10-191/' \
            "$CONTROLS" >"$CONTROLS_NEW"
        mv "$CONTROLS_NEW" "$CONTROLS"
    fi
    : >"$CONTROL_FACE_FIX"
fi

# Correct the original analog-up mapping once. The other stick directions use
# SDL axis-direction keycodes 4000..4002; 190 is BTN_EAST, not Y-axis negative.
# Only change the exact shipped value so a user remap remains untouched.
CONTROL_ANALOG_UP_FIX="$CONTROL_MIGRATIONS/controls-analog-up-v1"
if [ ! -e "$CONTROL_ANALOG_UP_FIX" ]; then
    mkdir -p "$CONTROL_MIGRATIONS"
    if [ -f "$CONTROLS" ] &&
       grep -q '^An.Up = 1-37,10-190$' "$CONTROLS"; then
        CONTROLS_NEW="$CONTROLS.umrk-new"
        sed \
            -e 's/^An.Up = 1-37,10-190$/An.Up = 1-37,10-4003/' \
            "$CONTROLS" >"$CONTROLS_NEW"
        mv "$CONTROLS_NEW" "$CONTROLS"
    fi
    : >"$CONTROL_ANALOG_UP_FIX"
fi

# Wireless controllers take the first player slots, so a Jawaka launch can hand
# PPSSPP the calibrated built-in pad as pad 1, 2 or 3 rather than pad 0. The
# original mapping only bound pad 0 (device id 10), which left every slot but
# the first dead. Bind each PSP control across pads 0-3 (10-13) so whichever
# roster slot a player holds drives the single-player PSP controls. Emulator
# functions (fast-forward, rewind, pause) stay on pad 0 deliberately.
# Only rewrite a mapping whose every PSP control still matches the shipped
# single-pad default; one user remap leaves the whole file alone.
CONTROL_MULTIPAD_FIX="$CONTROL_MIGRATIONS/controls-multipad-v1"
if [ ! -e "$CONTROL_MULTIPAD_FIX" ]; then
    mkdir -p "$CONTROL_MIGRATIONS"
    CONTROLS_PRISTINE=0
    if [ -f "$CONTROLS" ]; then
        CONTROLS_PRISTINE=1
        for shipped in \
            'Up = 1-19,10-19' \
            'Down = 1-20,10-20' \
            'Left = 1-21,10-21' \
            'Right = 1-22,10-22' \
            'Circle = 1-52,10-190' \
            'Cross = 1-54,10-189' \
            'Square = 1-29,10-188' \
            'Triangle = 1-47,10-191' \
            'Start = 1-62,10-197' \
            'Select = 1-66,10-196' \
            'L = 10-193' \
            'R = 10-192' \
            'An.Up = 1-37,10-4003' \
            'An.Down = 1-39,10-4002' \
            'An.Left = 1-38,10-4001' \
            'An.Right = 1-40,10-4000'; do
            if ! grep -qxF "$shipped" "$CONTROLS"; then
                CONTROLS_PRISTINE=0
                break
            fi
        done
    fi
    if [ "$CONTROLS_PRISTINE" = 1 ]; then
        CONTROLS_NEW="$CONTROLS.umrk-new"
        if awk '
            BEGIN {
                split("Up Down Left Right Circle Cross Square Triangle " \
                      "Start Select L R An.Up An.Down An.Left An.Right", k, " ")
                for (i in k) psp[k[i]] = 1
            }
            {
                split($0, parts, " = ")
                if (!(parts[1] in psp)) { print; next }
                n = split(parts[2], toks, ",")
                out = ""
                for (i = 1; i <= n; i++) {
                    out = out (out == "" ? "" : ",") toks[i]
                    if (toks[i] ~ /^10-/) {
                        code = substr(toks[i], 4)
                        out = out ",11-" code ",12-" code ",13-" code
                    }
                }
                print parts[1] " = " out
            }' "$CONTROLS" >"$CONTROLS_NEW"; then
            mv "$CONTROLS_NEW" "$CONTROLS"
        else
            rm -f "$CONTROLS_NEW"
        fi
    fi
    : >"$CONTROL_MULTIPAD_FIX"
fi

PPSSPP_INI="$STATE_ROOT/config/ppsspp/PSP/SYSTEM/ppsspp.ini"
PRESET="${PPSSPP_PRESET:-balanced}"
case "$PRESET" in
    balanced|performance) ;;
    *)
        log "unsupported PPSSPP_PRESET: $PRESET"
        exit 64
        ;;
esac
if [ ! -f "$PPSSPP_INI" ] && [ -f "$SELF_DIR/defaults/ppsspp-$PRESET.ini" ]; then
    cp "$SELF_DIR/defaults/ppsspp-$PRESET.ini" "$PPSSPP_INI"
fi

# Follow Leaf's UI language. PPSSPP ships the translations in bin/assets/lang
# already, so selecting one is all that is needed -- but the value of this key
# is the ini FILENAME STEM in that directory, not a locale code, which is why
# "zh_CN" appears nowhere in the binary. An absent JAWAKA_LANGUAGE means PPSSPP
# was started outside Jawaka, so leave the config alone entirely.
#
# The shipped defaults carry only [CPU] and [Graphics], so on a first run the
# section has to be created rather than edited.
#
# Nothing here may abort the launch: a language preference is not worth failing
# a game over, so every step is guarded and the original file survives intact.
if [ -n "${JAWAKA_LANGUAGE:-}" ] && [ -f "$PPSSPP_INI" ]; then
    PPSSPP_LANG="en_US"
    if [ -f "$SELF_DIR/bin/assets/lang/$JAWAKA_LANGUAGE.ini" ]; then
        PPSSPP_LANG="$JAWAKA_LANGUAGE"
    fi

    LANG_MIGRATIONS="$STATE_ROOT/.umrk-migrations"
    LANG_OWNED="$LANG_MIGRATIONS/language-last-written"
    LANG_PREVIOUS=""
    LANG_CLAIMED=0
    if [ -f "$LANG_OWNED" ]; then
        LANG_PREVIOUS="$(cat "$LANG_OWNED" 2>/dev/null || true)"
        LANG_CLAIMED=1
    fi

    LANG_CURRENT="$(awk '
        /^\[/ { general = ($0 ~ /^\[General\][ \t\r]*$/); next }
        general && /^[ \t]*Language[ \t]*=/ {
            sub(/^[ \t]*Language[ \t]*=[ \t]*/, "")
            sub(/[ \t\r]+$/, "")
            print
            exit
        }' "$PPSSPP_INI" 2>/dev/null || true)"

    # Write only while the key still holds what we last wrote. Once the value
    # differs, the user picked a language inside PPSSPP itself and owns it from
    # then on -- the same rule the controls migrations above follow.
    #
    # A populated key is NOT evidence of user intent: PPSSPP rewrites the whole
    # config on exit and always emits Language, defaulted from the locale. So
    # until the marker exists we have never managed this key and claim it,
    # rather than mistaking PPSSPP's own default for somebody's choice -- that
    # mistake locks the key out permanently, because the default is written on
    # the very first run.
    if [ "$LANG_CLAIMED" = 0 ] || [ -z "$LANG_CURRENT" ] ||
       [ "$LANG_CURRENT" = "$LANG_PREVIOUS" ]; then
        if [ "$LANG_CURRENT" != "$PPSSPP_LANG" ]; then
            PPSSPP_INI_NEW="$PPSSPP_INI.umrk-new"
            if awk -v want="$PPSSPP_LANG" '
                BEGIN { general = 0; done = 0 }
                /^\[/ {
                    general = ($0 ~ /^\[General\][ \t\r]*$/)
                    print
                    if (general && !done) { print "Language = " want; done = 1 }
                    next
                }
                general && /^[ \t]*Language[ \t]*=/ { next }
                { print }
                END {
                    if (!done) { print ""; print "[General]"; print "Language = " want }
                }' "$PPSSPP_INI" >"$PPSSPP_INI_NEW" 2>/dev/null &&
               [ -s "$PPSSPP_INI_NEW" ] &&
               grep -q "^Language = $PPSSPP_LANG\$" "$PPSSPP_INI_NEW"; then
                mv "$PPSSPP_INI_NEW" "$PPSSPP_INI"
            else
                rm -f "$PPSSPP_INI_NEW"
            fi
        fi
        mkdir -p "$LANG_MIGRATIONS" 2>/dev/null || true
        printf '%s\n' "$PPSSPP_LANG" >"$LANG_OWNED" 2>/dev/null || true
    fi
fi

# This build links SDL2_ttf but has no fontconfig, so PPSSPP has no way of its
# own to find a font covering CJK and draws those glyphs as squares -- including
# the endonyms in its own language list. Hand it the Droid Sans Fallback the
# release already ships (colon-separated, most preferred first).
if [ -z "${PPSSPP_FALLBACK_FONTS:-}" ]; then
    export PPSSPP_FALLBACK_FONTS="$PLATFORM_ROOT/assets/pkg/chinese-fallback-font.ttf"
fi

export HOME="$STATE_ROOT/home"
export XDG_CONFIG_HOME="$STATE_ROOT/config"
export XDG_DATA_HOME="$STATE_ROOT/data"
export XDG_CACHE_HOME="$STATE_ROOT/cache"
INHERITED_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export SDL_VIDEODRIVER="${PPSSPP_SDL_VIDEODRIVER:-kmsdrm}"

# A Jawaka launch already exports the full controller roster in player order
# (wireless pads first, calibrated virtual Loong last) and hands the child a
# private /dev/input holding exactly those devices, so the inherited value is
# authoritative -- overwriting it here would throw away every paired
# controller and leave only the built-in pad. Fall back to the calibrated
# virtual event only when PPSSPP was started outside Jawaka and no ordered
# list exists, which keeps direct invocation working.
if [ -z "${SDL_JOYSTICK_DEVICE:-}" ] && [ -n "${JAWAKA_INPUT_VIRTUAL_EVENT:-}" ]; then
    export SDL_JOYSTICK_DEVICE="$JAWAKA_INPUT_VIRTUAL_EVENT"
fi

BACKEND="${PPSSPP_BACKEND:-vulkan}"
ROTATION_MODE="${PPSSPP_ROTATION_MODE:-}"
VULKAN_ROOT="${PPSSPP_VULKAN_ROOT:-$PLATFORM_ROOT/runtime/graphics/vulkan/rk3566-g52-g29p1}"
ICD_PATH="$VULKAN_ROOT/share/vulkan/icd.d/rk_vk_g29.json"
DRIVER_PATH="$VULKAN_ROOT/lib/libmali.so.1"

case "$BACKEND" in
    vulkan)
        ROTATION_MODE="${ROTATION_MODE:-native}"
        if [ ! -f "$DRIVER_PATH" ] || [ ! -f "$ICD_PATH" ]; then
            log "PPSSPP Vulkan runtime is incomplete: $VULKAN_ROOT"
            log "Select the PPSSPP GLES core or restage the MLP1 graphics runtime."
            exit 69
        fi
        case "${JAWAKA_DIRECT_DRM:-0}" in
            1|true|yes|TRUE|YES) ;;
            *)
                case "${PPSSPP_ALLOW_NO_DIRECT_DRM:-0}" in
                    1|true|yes|TRUE|YES) ;;
                    *)
                        log "PPSSPP Vulkan requires Jawaka's direct-DRM handoff."
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
                    log "PPSSPP's optional DRM rotation shim is unavailable."
                    log "Install the PortMaster Pak or set PPSSPP_DRM_ROTATE_SHIM explicitly."
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
                log "unsupported Vulkan PPSSPP_ROTATION_MODE: $ROTATION_MODE"
                exit 64
                ;;
        esac
        ;;
    gles)
        ROTATION_MODE="${ROTATION_MODE:-gles}"
        if [ "$ROTATION_MODE" != "gles" ]; then
            log "GLES requires PPSSPP_ROTATION_MODE=gles"
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
        log "unsupported PPSSPP_BACKEND: $BACKEND"
        exit 64
        ;;
esac

# LOG-SAFE-1. The PPSSPP log lives on the same FAT card as the session log, so
# this redirect gets the same treatment: prove the file can take a real byte,
# then either log there or log nowhere, but never fail the launch on it.
if leaf_log_probe >>"$LOG_ROOT/ppsspp.log"; then
    exec >>"$LOG_ROOT/ppsspp.log" 2>&1
else
    exec >/dev/null 2>&1
fi
{
    printf '%s\n' "=== UMRK PPSSPP launch ==="
    printf 'version=%s backend=%s rotation=%s preset=%s direct_drm=%s\n' \
        "v1.20.4" "$BACKEND" "$ROTATION_MODE" "$PRESET" "${JAWAKA_DIRECT_DRM:-0}"
    printf 'state=%s\n' "$STATE_ROOT"
    printf 'input=%s\n' "${SDL_JOYSTICK_DEVICE:-direct}"
    if [ "$BACKEND" = "vulkan" ]; then
        printf 'vulkan_root=%s icd=%s\n' "$VULKAN_ROOT" "$ICD_PATH"
    fi
} || true

exec "$SELF_DIR/bin/PPSSPPSDL" --fullscreen "--graphics=$BACKEND" "$ROM_PATH"
EOF
    chmod 755 "$path"

    cat >"$OUTPUT_DIR/launch-gles.sh" <<'EOF'
#!/bin/sh
set -eu
# LOG-SAFE-1. The session log lives on a FAT card and can go unwritable (a bad
# cluster chain, a full card, or the FAT32 4 GiB per-file ceiling). stdout and
# stderr here are inherited from the launcher and point at that file. Under
# set -e a failed echo would abort this script and the game would never start,
# so probe both once and fall back to /dev/null, then never let a log write
# decide whether a game launches.
leaf_log_probe() {
    # A real byte, not a zero-length write: a 0-byte write can succeed without
    # touching the device and would not detect EIO/EFBIG. The subshell ignores
    # SIGXFSZ: at the FAT32 ceiling the kernel raises it and its default action
    # would kill this shell before the write could fail with EFBIG.
    ( trap '' XFSZ; printf '\n' ) 2>/dev/null
}
leaf_log_probe >/dev/null 2>&1 || true
if ! leaf_log_probe; then
    exec >/dev/null
fi
if ! leaf_log_probe >&2; then
    exec 2>/dev/null
fi

log() { ( trap '' XFSZ; printf '%s\n' "$*" ) 2>/dev/null || true; }
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
existing user remaps are preserved.
EOF

    find "$OUTPUT_DIR" -maxdepth 3 -type f | sort
}

main "$@"
