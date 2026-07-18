#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PPSSPP_VERSION="${PPSSPP_VERSION:-v1.20.4}"
WORKDIR="${WORKDIR:-$ROOT_DIR/workdir/mlp1/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/build}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-perf}"

if [ -z "${SYSROOT:-}" ] || [ -z "${CC:-}" ] || [ -z "${CXX:-}" ]; then
    echo "build-mlp1.sh must run inside the UMRK MLP1 toolchain environment." >&2
    echo "Use: make build-mlp1" >&2
    exit 1
fi

CMAKE_TOOLCHAIN_FILE="${CMAKE_TOOLCHAIN_FILE:-/opt/mlp1-toolchain/Toolchain.cmake}"
PKG_CONFIG_EXECUTABLE="${PKG_CONFIG_EXECUTABLE:-$(command -v pkg-config)}"
STRIP="${STRIP:-${CROSS_COMPILE:-aarch64-buildroot-linux-gnu-}strip}"
READELF="${READELF:-${CROSS_COMPILE:-aarch64-buildroot-linux-gnu-}readelf}"

export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

if [ -f /opt/mlp1-toolchain/umrk/mlp1-build-flags.env ]; then
    . /opt/mlp1-toolchain/umrk/mlp1-build-flags.env
else
    UMRK_MLP1_PROFILE_CFLAGS="-O3 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_CXXFLAGS="-O3 -mcpu=cortex-a55 -mtune=cortex-a55 -ffunction-sections -fdata-sections -DNDEBUG"
    UMRK_MLP1_PROFILE_LDFLAGS="-Wl,--gc-sections"
fi

SRC_DIR="$WORKDIR/src/ppsspp-$PPSSPP_VERSION"
BUILD_DIR="$WORKDIR/cmake/ppsspp-$PPSSPP_VERSION"
PATCH_SET_ID="mlp1-v5-vulkan-kmsdrm-display-rotation-cli-backend"
PATCH_MARKER="$SRC_DIR/.umrk-$PATCH_SET_ID-patches-applied"

echo "=== Building PPSSPP $PPSSPP_VERSION for UMRK MLP1 ==="

clone_source() {
    rm -rf "$SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth 1 --branch "$PPSSPP_VERSION" \
        --recurse-submodules --shallow-submodules \
        https://github.com/hrydgard/ppsspp.git "$SRC_DIR"
}

if [ -d "$SRC_DIR/.git" ] && [ ! -f "$PATCH_MARKER" ] &&
    { compgen -G "$SRC_DIR/.umrk-mlp1-*-patches-applied" >/dev/null ||
      compgen -G "$SRC_DIR/.umrk-mlp1-patches*-applied" >/dev/null ||
      compgen -G "$SRC_DIR/.umrk-mlp1-patches-applied" >/dev/null; }; then
    echo "=== PPSSPP patch set changed; refreshing source tree ==="
    rm -rf "$BUILD_DIR"
    clone_source
elif [ ! -d "$SRC_DIR/.git" ]; then
    clone_source
fi

if [ ! -f "$PATCH_MARKER" ]; then
    echo "=== Applying spruce patches ==="
    cd "$SRC_DIR"
    for patch in "$ROOT_DIR"/patches/common/*.py \
                 "$ROOT_DIR"/patches/mlp1/*.py \
                 "$ROOT_DIR"/patches/flip/*.py; do
        [ -f "$patch" ] || continue
        if [ "$(basename "$patch")" = "skip-vulkan-probe.py" ]; then
            echo "Skipped for Vulkan build: ${patch#$ROOT_DIR/patches/}"
            continue
        fi
        python3 "$patch"
        echo "Applied: ${patch#$ROOT_DIR/patches/}"
    done
    touch "$PATCH_MARKER"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ "${FORCE_CONFIGURE:-0}" = "1" ] || [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    cmake "$SRC_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
        -DPKG_CONFIG_EXECUTABLE="$PKG_CONFIG_EXECUTABLE" \
        -DCMAKE_C_FLAGS="$UMRK_MLP1_PROFILE_CFLAGS -fomit-frame-pointer -Wno-error" \
        -DCMAKE_CXX_FLAGS="$UMRK_MLP1_PROFILE_CXXFLAGS -fomit-frame-pointer -Wno-error" \
        -DCMAKE_EXE_LINKER_FLAGS="$UMRK_MLP1_PROFILE_LDFLAGS -static-libstdc++ -static-libgcc" \
        -DUSING_GLES2=ON \
        -DUSING_EGL=ON \
        -DUSING_FBDEV=ON \
        -DVULKAN=ON \
        -DUSE_VULKAN_DISPLAY_KHR=ON \
        -DUSING_X11_VULKAN=OFF \
        -DUSE_WAYLAND_WSI=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DUSE_SYSTEM_LIBPNG=OFF \
        -DUSE_SYSTEM_FFMPEG=OFF \
        -DUSE_DISCORD=OFF \
        -DUSE_MINIUPNPC=OFF \
        -DHEADLESS=OFF \
        -DUNITTEST=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_SDL2_ttf=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_Fontconfig=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_X11=ON

    # The PPSSPP build emits -isystem include paths that the Buildroot GCC
    # wrapper sysroot-prefixes incorrectly. Plain -I keeps the target includes.
    while IFS= read -r file; do
        if grep -q -- '-isystem ' "$file"; then
            sed -i 's|-isystem |-I|g' "$file"
        fi
    done < <(find "$BUILD_DIR" \( -name 'flags.make' -o -name 'build.ninja' \))
fi

make -j"$BUILD_JOBS" PPSSPPSDL

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/lib"

cp -f "$BUILD_DIR/PPSSPPSDL" "$OUTPUT_DIR/PPSSPPSDL_MLP1"
"$STRIP" -s "$OUTPUT_DIR/PPSSPPSDL_MLP1"
cp -R "$SRC_DIR/assets" "$OUTPUT_DIR/assets"

for lib in libSDL2-2.0.so.0 libSDL2_ttf-2.0.so.0; do
    if [ -e "$SYSROOT/usr/lib/$lib" ]; then
        cp -Lf "$SYSROOT/usr/lib/$lib" "$OUTPUT_DIR/lib/$lib"
        chmod 755 "$OUTPUT_DIR/lib/$lib"
    fi
done

"$READELF" -d "$OUTPUT_DIR/PPSSPPSDL_MLP1" >"$OUTPUT_DIR/PPSSPPSDL_MLP1.readelf.txt"

echo "=== Build complete: $OUTPUT_DIR/PPSSPPSDL_MLP1 ==="
