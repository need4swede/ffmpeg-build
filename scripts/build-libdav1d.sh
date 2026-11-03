#!/bin/bash
# Build Libdav1d.xcframework (static) for tvOS, tvOS Simulator, iOS and iOS
# Simulator from a dav1d source tree, with ARM64/x86-64 assembly enabled.
#
# Why: the mpvkit libdav1d-build 1.4.3 release this package used to pin has
# no assembly in any slice (every archive member is a .c.o; no *_neon
# symbols), so AV1 software decode ran dav1d's C fallback. dav1d's own
# assembly is the decoder's main performance path.
#
#   scripts/build-libdav1d.sh <dav1d-source-dir> [--disable-asm] [--output <dir>]
#
# Default output: dist/release/xcframework/Libdav1d.xcframework (the path
# Package.swift references). --disable-asm builds the C-only control used
# to attribute version and assembly effects separately.
# Requires: Xcode, meson, ninja, nasm (x86_64 simulator assembly).
set -euo pipefail

SRC=""
ASM=true
OUT="$(cd "$(dirname "$0")/.." && pwd)/dist/release/xcframework"
while [ $# -gt 0 ]; do
    case "$1" in
        --disable-asm) ASM=false ;;
        --output) OUT="$2"; shift ;;
        *) SRC="$1" ;;
    esac
    shift
done
[ -n "$SRC" ] && [ -f "$SRC/meson.build" ] || { echo "usage: $0 <dav1d-source-dir> [--disable-asm] [--output <dir>]" >&2; exit 64; }
SRC="$(cd "$SRC" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/libdav1d.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

MIN=13.0
# slice-id | sdk | platform plist name | "arch:triple ..."
SLICES=(
  "tvos-arm64_arm64e|appletvos|AppleTVOS|arm64:arm64-apple-tvos$MIN arm64e:arm64e-apple-tvos$MIN"
  "tvos-arm64_x86_64-simulator|appletvsimulator|AppleTVSimulator|arm64:arm64-apple-tvos$MIN-simulator x86_64:x86_64-apple-tvos$MIN-simulator"
  "ios-arm64|iphoneos|iPhoneOS|arm64:arm64-apple-ios$MIN"
  "ios-arm64_x86_64-simulator|iphonesimulator|iPhoneSimulator|arm64:arm64-apple-ios$MIN-simulator x86_64:x86_64-apple-ios$MIN-simulator"
)

build_thin() { # sdk arch triple builddir
    local sdk="$1" arch="$2" triple="$3" dir="$4"
    local sysroot cc family cpu
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" -f clang)"
    case "$arch" in
        x86_64) family=x86_64; cpu=x86_64 ;;
        *) family=aarch64; cpu=aarch64 ;;
    esac
    cat > "$dir.cross" <<EOF
[binaries]
c = ['$cc', '-target', '$triple', '-isysroot', '$sysroot']
ar = '$(xcrun --sdk "$sdk" -f ar)'
strip = '$(xcrun --sdk "$sdk" -f strip)'
nasm = '$(command -v nasm || echo nasm)'

[built-in options]
c_args = []
c_link_args = []

[host_machine]
system = 'darwin'
cpu_family = '$family'
cpu = '$cpu'
endian = 'little'
EOF
    meson setup "$dir" "$SRC" --cross-file "$dir.cross" --buildtype release \
        -Ddefault_library=static -Denable_asm="$ASM" -Denable_tools=false \
        -Denable_tests=false -Denable_examples=false >"$dir.log" 2>&1 \
        || { cat "$dir.log"; exit 1; }
    ninja -C "$dir" >>"$dir.log" 2>&1 || { tail -40 "$dir.log"; exit 1; }
}

ARGS=()
for slice in "${SLICES[@]}"; do
    IFS='|' read -r id sdk platform archs <<<"$slice"
    thins=()
    for pair in $archs; do
        arch="${pair%%:*}"; triple="${pair#*:}"
        dir="$WORK/$id-$arch"
        build_thin "$sdk" "$arch" "$triple" "$dir"
        thins+=("$dir/src/libdav1d.a")
    done
    fw="$WORK/$id/Libdav1d.framework"
    mkdir -p "$fw/Headers/dav1d" "$fw/Modules"
    lipo -create "${thins[@]}" -output "$fw/Libdav1d"
    cp "$SRC"/include/dav1d/*.h "$fw/Headers/dav1d/"
    # Older trees generate version.h into the build directory.
    first="$WORK/$id-${archs%%:*}"
    [ -f "$first/include/dav1d/version.h" ] && cp "$first/include/dav1d/version.h" "$fw/Headers/dav1d/"
    printf 'framework module Libdav1d [system] {\n    umbrella "."\n    export *\n}' > "$fw/Modules/module.modulemap"
    version="$(sed -n "s/^ *version: '\([0-9.]*\)'.*/\1/p" "$SRC/meson.build" | head -1)"
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>Libdav1d</string>
<key>CFBundleIdentifier</key><string>com.neptuneplayer.Libdav1d</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Libdav1d</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>MinimumOSVersion</key><string>$MIN</string>
<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
</dict>
</plist>
EOF
    ARGS+=(-framework "$fw")
done

mkdir -p "$OUT"
rm -rf "$OUT/Libdav1d.xcframework"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/Libdav1d.xcframework" >/dev/null

# Prove what was built: assembly symbol count per slice (0 means C only).
for id in tvos-arm64_arm64e ios-arm64; do
    lib="$OUT/Libdav1d.xcframework/$id/Libdav1d.framework/Libdav1d"
    lipo "$lib" -thin arm64 -output "$WORK/check.a"
    echo "$id arm64 neon symbols: $(nm "$WORK/check.a" 2>/dev/null | grep -c '_neon' || true) (asm=$ASM)"
done
echo "Built $OUT/Libdav1d.xcframework from $SRC"
