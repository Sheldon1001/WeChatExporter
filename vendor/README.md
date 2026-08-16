# Vendored binaries

These binaries are bundled into WeChatExporter releases so the app does not
depend on a separate `wx-cli` GitHub repository at build time.

| Path | Platform | Notes |
|------|----------|-------|
| `macos/wx-cli` | macOS arm64 | Based on pandorafuture/wx-cli 0.7.2; version allowlist extended to WeChat 4.1.7–4.1.11 |
| `windows/wx.exe` | Windows x64 | Previously shipped in WeChatExporter v2.6.2 (jackwener/wx-cli upstream is DMCA-unavailable) |
| `macos/ffmpeg` | macOS arm64 | Minimal static build, FFmpeg 8.0.1 + LAME 3.100 — see below |

`scripts/bundle_wx_cli.sh` and `windows/scripts/bundle_wx_cli.ps1` copy from here first.
`build_app.sh` copies `macos/ffmpeg` into `Contents/Resources/`.

## ffmpeg (macOS)

`wx-cli` shells out to ffmpeg to transcode WeChat voice messages (SILK → MP3)
and to decode WXGF animated stickers. Bundling it means users get playable
voice without installing anything. When it is missing, `wx-cli` degrades
gracefully and exports raw `.silk` files instead — nothing crashes.

**Rebuild it with `scripts/build_ffmpeg_minimal.sh`.** That script pins the
exact versions and configure flags, downloads the sources, and self-tests the
result. It is also what satisfies the LGPL relinking obligation below.

| | |
|---|---|
| FFmpeg | 8.0.1 — https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz |
| LAME | 3.100 — https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz |
| Licence | **LGPL v2.1** — built *without* `--enable-gpl` and *without* `--enable-version3` |
| Size | ~2.7 MB (`--disable-everything` plus only the components listed in the script) |
| Linkage | Static; the only dynamic dependencies are macOS system libraries and frameworks |

### Licensing notes

WeChatExporter itself is MIT-licensed and remains so: ffmpeg is invoked as a
**separate subprocess**, never linked into the application, so no derivative-work
obligation attaches to our own source.

Redistributing the binary does carry obligations, which we meet as follows:

- LGPL v2.1 §6 (static linking) — `scripts/build_ffmpeg_minimal.sh` pins the
  exact upstream versions and configure flags, so anyone can rebuild or relink
  the binary from unmodified upstream sources.
- Licence text — `macos/ffmpeg-COPYING.LGPLv2.1` ships verbatim and is copied
  into `WeChatExporter.app/Contents/Resources/`.
- `libmp3lame` is LGPL and does **not** require `--enable-gpl`. Homebrew's build
  enables GPL only because it also bundles x264, which we deliberately exclude.
  Do not add `--enable-gpl` or `--enable-version3` to the build script.
