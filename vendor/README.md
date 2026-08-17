# Vendored binaries

These binaries are bundled into WeChatExporter releases so the app does not
depend on a separate `wx-cli` GitHub repository at build time.

| Path | Platform | Notes |
|------|----------|-------|
| `macos/wx-cli` | macOS arm64 | wx-cli 0.7.5, MIT — see below |
| `windows/wx.exe` | Windows x64 | Previously shipped in WeChatExporter v2.6.2 (jackwener/wx-cli upstream is DMCA-unavailable) |
| `macos/ffmpeg` | macOS arm64 | Minimal static build, FFmpeg 8.0.1 + LAME 3.100 — see below |
| `macos/ffprobe` | macOS arm64 | Built alongside ffmpeg by the same script |

`scripts/bundle_wx_cli.sh` and `windows/scripts/bundle_wx_cli.ps1` copy from here first.
`build_app.sh` copies `macos/ffmpeg` and `macos/ffprobe` into `Contents/Resources/`.

## wx-cli (macOS)

| | |
|---|---|
| Version | **0.7.5** — `wx-cli --version` reports `0.7.5 (4c57cf7 2026-08-17)` |
| Source | https://github.com/Sheldon1001/wx-cli — commit [`4c57cf7`](https://github.com/Sheldon1001/wx-cli/commit/4c57cf7), tag `v0.7.5` |
| Upstream | Fork of [pandorafuture/wx-cli](https://github.com/pandorafuture/wx-cli); v0.7.5 = upstream v0.7.4 plus the version-allowlist change below |
| Licence | **MIT** (same as this project) |
| Provenance | Built by GitHub Actions from the tagged commit — [`release.yml`](https://github.com/Sheldon1001/wx-cli/blob/main/.github/workflows/release.yml), `cargo build --release --target aarch64-apple-darwin` |
| SHA-256 | `5c8e61fd580e533ff13eacc5d67df5a4475f6502f26aba24750e2e0e80ffd622` |

### Verifying it

```bash
shasum -a 256 vendor/macos/wx-cli
# must match the SHA-256 above, which is also the asset published at
# https://github.com/Sheldon1001/wx-cli/releases/tag/v0.7.5
```

To rebuild from source instead: check out `v0.7.5` and push a tag, or run
`cargo build --release --target aarch64-apple-darwin` on a current stable Rust
toolchain. Note that `libsqlite3-sys 0.38` needs a recent stable rustc — the
Homebrew rust that happens to be on a given machine may be too old.

### The fork's one change

Upstream gates LLDB key extraction on `EXTRACTION_VERSION_PREFIXES`, which stops at
WeChat 4.1.8. The encryption parameters (PBKDF2-HMAC-SHA512, 256K iterations) are
identical through 4.1.11 and the same `CCKeyDerivationPBKDF` breakpoint works on all
of them, so the fork extends the list to `4.1.7 … 4.1.11` and derives the
"unsupported version" error text from it. Unit tests in
`crates/wx-keychain/src/process.rs` cover the allowlist.

**This is why `ci.yml` greps the binary for `4.1.11`.** Replacing `macos/wx-cli` with a
stock upstream build would silently drop support for WeChat 4.1.9–4.1.11, and the
failure only shows up when a user on one of those versions tries to extract a key.

> Binaries shipped before v2.15.2 reported `0.7.2 (b31a416)` but contained the extended
> allowlist, which `b31a416` does not have — they were built from an uncommitted local
> edit and could not be reproduced from any public commit. That is what this section
> exists to prevent; keep it accurate when the binary is replaced.

## ffmpeg / ffprobe (macOS)

`wx-cli` shells out to ffmpeg to transcode WeChat voice messages (SILK → MP3)
and to decode WXGF animated stickers. Bundling it means users get playable
voice without installing anything. When it is missing, `wx-cli` degrades
gracefully and exports raw `.silk` files instead — nothing crashes.

**Both binaries are required.** `wx-cli` reads `FFMPEG_PATH` *and* `FFPROBE_PATH`;
it uses ffprobe (`-count_frames -select_streams v:0 -show_entries stream=nb_read_frames`)
to count the frames in a WXGF's HEVC stream and decide whether to emit a static
PNG or an animated GIF. Ship ffmpeg without ffprobe and animated stickers stay
broken. `WxCliService.childEnvironment()` injects both.

**Rebuild it with `scripts/build_ffmpeg_minimal.sh`.** That script pins the
exact versions and configure flags, downloads the sources, and self-tests the
result. It is also what satisfies the LGPL relinking obligation below.

| | |
|---|---|
| FFmpeg | 8.0.1 — https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz |
| LAME | 3.100 — https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz |
| Licence | **LGPL v2.1** — built *without* `--enable-gpl` and *without* `--enable-version3` |
| Size | ~2.7 MB ffmpeg + ~2.5 MB ffprobe (`--disable-everything` plus only the components listed in the script) |
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
