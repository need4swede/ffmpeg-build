# Libdav1d

`Libdav1d` is a local binary target (`dist/release/xcframework/Libdav1d.xcframework`,
gitignored like the FFmpeg frameworks), built by `scripts/build-libdav1d.sh`
from a dav1d source tree:

```sh
scripts/build-libdav1d.sh /path/to/dav1d-1.5.4              # assembly (default)
scripts/build-libdav1d.sh /path/to/dav1d-1.5.4 --disable-asm --output /tmp/c-only
```

Slices: `tvos-arm64_arm64e`, `tvos-arm64_x86_64-simulator`, `ios-arm64`,
`ios-arm64_x86_64-simulator`; static archives, minimum OS 13.0, the same
`Libdav1d` module map as before. The script prints each slice's `_neon`
symbol count (0 means C only). It needs Xcode, meson, ninja and nasm. A
source tarball can come from `brew fetch --build-from-source dav1d`.

## Why

Until 2026-11-02 the package pinned the mpvkit `libdav1d-build` 1.4.3 release.
Every slice of that binary was C only: its 51 archive members are all `.c.o`,
with no `src/arm/64/*.S` objects and no `_neon` symbols, so Trident's AV1
software decode ran dav1d's C fallback. FFmpeg's own libraries here do have
NEON. On an M4 Pro, the same dav1d 1.5.4 source built with and without
assembly decoded synthetic 4K AV1 clips 1.7–2.4× faster with assembly
(film-grain clips gained most). Device numbers are recorded in Neptune's
`docs/trident/capabilities/av1-software-decode.md`.

## Compatibility

FFmpeg 8.0.1 here was compiled against dav1d 1.4.3 headers. dav1d 1.5.4 has
the same API version (7.0.0) and soname major; the public header diff is
comments and an OS/2 export macro, and every struct size and field offset
FFmpeg uses (`Dav1dSettings`, `Dav1dPicture`, `Dav1dData`, allocator, logger,
sequence/frame headers, film grain, HDR metadata) is identical. Both
libraries are static, so a dav1d swap needs no FFmpeg rebuild.

dav1d is bit-exact across its C and assembly paths (checked on six 4K clips,
grain included, by MD5 of decoded output), and Trident pins the decoded
output of its AV1 fixtures, so a rebuild or upgrade that changed pixels
fails `SoftwareVideoDecodeTests`.

To return to the previous binary, restore the `url:`/`checksum:` target for
`https://github.com/mpvkit/libdav1d-build/releases/download/1.4.3/Libdav1d.xcframework.zip`
(checksum `eccfe37da9418e350bc6c1566890fa5b9585fbb87b8ceb664de77800ef17fe04`).
