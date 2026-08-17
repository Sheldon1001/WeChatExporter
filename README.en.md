# WeChatExporter

[![Release](https://img.shields.io/github/v/release/Sheldon1001/WeChatExporter?label=release)](https://github.com/Sheldon1001/WeChatExporter/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Native desktop app to export **your own** WeChat chat history locally. No cloud upload, no key exfiltration.

**中文文档:** [README.md](README.md)

## Download

Get the latest build from **[GitHub Releases](https://github.com/Sheldon1001/WeChatExporter/releases/latest)**:

| Platform | File | Notes |
|----------|------|-------|
| macOS (Apple Silicon) | `WeChatExporter-macOS-arm64.dmg` | Drag to Applications |
| macOS (alt) | `WeChatExporter-macOS-arm64.zip` | Extract and open `.app` |
| Windows (x64) | `WeChatExporter-Windows-x64.zip` | Self-contained, no .NET install |

![Main UI](docs/screenshots/main-ui.png)

## Features

- GUI: search, multi-select contacts/groups
- Sidebar grouped by chat type (friends / groups / official accounts / other), collapsible, with per-group select-all — macOS
- Bundled wx-cli (no separate CLI install)
- Readiness banner for first-time setup
- Four export modes on macOS (Windows always writes HTML):
  - **By category** (default): text, images, video and voice filed into separate folders
  - **Text only**: txt / json / csv, fastest
  - **Everything**: text plus the raw media files
  - **Web page**: a self-contained `.html` with images, stickers and voice inlined; video and large attachments are linked from a `media/` folder. Split into volumes of 1000 messages with prev/next navigation
- Every export gets its own folder, `<contact>_<timestamp>/`, so repeated exports never overwrite each other; media is filed into 图片 / 视频 / 语音 / 其他 subfolders
- Playable voice messages (macOS): bundled ffmpeg transcodes WeChat's SILK to MP3
- Animated WXGF stickers exported as animated GIF (macOS)
- Live export progress: current chat, stage and media count
- Export TXT / CSV / JSON

## Requirements

### macOS
- macOS 13+, Apple Silicon (arm64)
- WeChat Mac 4.x, logged in
- SIP disabled for key capture

### Windows
- Windows 10/11 x64
- WeChat PC 4.x, logged in
- Run as Administrator recommended for first setup

## Quick Start

1. Download the release for your platform
2. Open the app
3. Click **Prepare Data** (first time only)
4. Select chats and click **Export**

## Build from Source

```bash
# macOS
./build_app.sh
bash scripts/create_dmg.sh

# Windows
cd windows && ./build.ps1
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please use issue templates for bugs and feature requests.

## Disclaimer

For personal backup of **your own** data only. WeChat schema may change; compatibility not guaranteed.

## License

MIT

### Third-party binaries

Release packages bundle prebuilt binaries whose licences are independent of this project's MIT licence:

| Component | Purpose | Licence |
|---|---|---|
| `wx-cli` (macOS) / `wx.exe` (Windows) | WeChat database decryption and export | see [vendor/README.md](vendor/README.md) |
| `ffmpeg` / `ffprobe` (macOS) | SILK → MP3 voice, WXGF sticker decoding | **LGPL v2.1** |

ffmpeg is a minimal static build (FFmpeg 8.0.1 + LAME 3.100) configured **without GPL**, invoked as a
separate subprocess and never linked in. Rebuild or relink it (LGPL v2.1 §6) with
`bash scripts/build_ffmpeg_minimal.sh`; the licence text ships at
`WeChatExporter.app/Contents/Resources/ffmpeg-COPYING.LGPLv2.1`.
