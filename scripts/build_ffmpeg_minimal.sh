#!/bin/bash
# 构建最小化静态 ffmpeg，供 WeChatExporter 随包分发。
#
# 用途：
#   1. 语音：把微信 SILK 解出的 PCM 转成 MP3（wx-cli 内部调用）
#   2. WXGF：解码 HEVC 首帧成 PNG，或用 palettegen/paletteuse 生成动图 GIF
#
# 授权红线：
#   - 不加 --enable-gpl（libmp3lame 是 LGPL，不需要 GPL）
#   - 不加 --enable-version3（保持在 LGPL v2.1）
#   本脚本同时充当 LGPL v2.1 §6 要求的「可重新构建 / 重新链接」凭据。
#
# 用法：
#   bash scripts/build_ffmpeg_minimal.sh          # 构建并安装到 vendor/macos/ffmpeg
#   OUTPUT=/tmp/ffmpeg bash scripts/build_ffmpeg_minimal.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${OUTPUT:-$ROOT/vendor/macos/ffmpeg}"
# ffprobe 与 ffmpeg 一起产出：wx-cli 用它数 WXGF 的帧数，据此决定输出静态 PNG 还是动图 GIF，
# 缺了它动态表情就出不来。放在 ffmpeg 同目录下。
OUTPUT_PROBE="${OUTPUT_PROBE:-$(dirname "$OUTPUT")/ffprobe}"
WORK="${WORK:-$ROOT/.build/ffmpeg-minimal}"

# 版本锁定：升级时同步更新 vendor/README.md
FFMPEG_VERSION="8.0.1"
LAME_VERSION="3.100"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"

PREFIX="$WORK/prefix"
mkdir -p "$WORK" "$PREFIX"

echo "==> 工作目录：$WORK"

# ---------------------------------------------------------------- 下载源码
fetch() {
  local url="$1" file="$2"
  if [[ -f "$WORK/$file" ]]; then
    echo "已存在：$file"
  else
    echo "下载：$url"
    curl -fL --retry 3 -o "$WORK/$file.part" "$url"
    mv "$WORK/$file.part" "$WORK/$file"
  fi
}

fetch "$LAME_URL" "lame-${LAME_VERSION}.tar.gz"
fetch "$FFMPEG_URL" "ffmpeg-${FFMPEG_VERSION}.tar.xz"

# ------------------------------------------------------------ 构建 libmp3lame
if [[ ! -f "$PREFIX/lib/libmp3lame.a" ]]; then
  echo "==> 构建 libmp3lame ${LAME_VERSION}（静态，LGPL）"
  rm -rf "$WORK/lame-${LAME_VERSION}"
  tar -xzf "$WORK/lame-${LAME_VERSION}.tar.gz" -C "$WORK"
  pushd "$WORK/lame-${LAME_VERSION}" >/dev/null
  # lame 3.100 自带的 config.guess 太老，认不出 arm64-apple-darwin
  ./configure \
    --prefix="$PREFIX" \
    --host=aarch64-apple-darwin \
    --enable-static --disable-shared \
    --disable-frontend --disable-decoder --disable-gtktest \
    --disable-dependency-tracking
  make -j"$(sysctl -n hw.ncpu)"
  make install
  popd >/dev/null
else
  echo "==> libmp3lame 已构建，跳过"
fi

# ---------------------------------------------------------------- 构建 ffmpeg
echo "==> 构建 ffmpeg ${FFMPEG_VERSION}（最小化静态，LGPL v2.1）"
rm -rf "$WORK/ffmpeg-${FFMPEG_VERSION}"
tar -xJf "$WORK/ffmpeg-${FFMPEG_VERSION}.tar.xz" -C "$WORK"
pushd "$WORK/ffmpeg-${FFMPEG_VERSION}" >/dev/null

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# lame 不提供 .pc 文件，ffmpeg 用 check_lib 直接找头文件与静态库，须显式给出路径

# 组件清单依据 wx-cli 二进制内还原出的实际调用：
#   语音  -f s16le -ar 24000 -ac 1 -i pipe:0 -b:a 64k -f mp3 pipe:1
#   首帧  -i pipe:0 -frames:v 1 -f image2pipe -vcodec png pipe:1
#   动图  -filter_complex [0:v]split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse
./configure \
  --prefix="$PREFIX" \
  --extra-cflags="-I$PREFIX/include" \
  --extra-ldflags="-L$PREFIX/lib" \
  --disable-everything \
  --disable-autodetect \
  --disable-shared --enable-static \
  --pkg-config-flags=--static \
  --disable-programs --enable-ffmpeg --enable-ffprobe \
  --disable-doc --disable-debug --disable-network --disable-iconv \
  --enable-small \
  --enable-demuxer=pcm_s16le,hevc,image2,image2pipe,mp3,mov,matroska \
  --enable-decoder=pcm_s16le,hevc,mjpeg,png,gif \
  --enable-parser=hevc,mjpeg,png,gif \
  --enable-encoder=libmp3lame,png,gif,mjpeg \
  --enable-muxer=mp3,image2,image2pipe,gif,null \
  --enable-filter=aformat,anull,aresample,atrim,abuffer,abuffersink \
  --enable-filter=buffer,buffersink,copy,format,fps,null,scale,setpts,split,trim \
  --enable-filter=palettegen,paletteuse \
  --enable-protocol=pipe,file \
  --enable-bsf=hevc_mp4toannexb,extract_extradata \
  --enable-libmp3lame \
  --enable-videotoolbox --enable-hwaccel=hevc_videotoolbox

make -j"$(sysctl -n hw.ncpu)"
popd >/dev/null

BUILT="$WORK/ffmpeg-${FFMPEG_VERSION}/ffmpeg"
BUILT_PROBE="$WORK/ffmpeg-${FFMPEG_VERSION}/ffprobe"
[[ -x "$BUILT" ]] || { echo "错误：未生成 ffmpeg 可执行文件" >&2; exit 1; }
[[ -x "$BUILT_PROBE" ]] || { echo "错误：未生成 ffprobe 可执行文件" >&2; exit 1; }

# ------------------------------------------------------------------ 自检
echo "==> 自检"
"$BUILT" -hide_banner -encoders 2>/dev/null | grep -q libmp3lame \
  || { echo "错误：缺少 libmp3lame 编码器" >&2; exit 1; }
"$BUILT" -hide_banner -decoders 2>/dev/null | grep -qw hevc \
  || { echo "错误：缺少 hevc 解码器" >&2; exit 1; }
"$BUILT" -hide_banner -encoders 2>/dev/null | grep -qw gif \
  || { echo "错误：缺少 gif 编码器" >&2; exit 1; }
for f in palettegen paletteuse split scale; do
  "$BUILT" -hide_banner -filters 2>/dev/null | grep -qw "$f" \
    || { echo "错误：缺少 $f 滤镜（WXGF 动图通路需要）" >&2; exit 1; }
done

# 端到端跑一遍语音通路：1 秒静音 PCM → MP3
head -c 48000 /dev/zero | "$BUILT" -hide_banner -loglevel error \
  -f s16le -ar 24000 -ac 1 -i pipe:0 -b:a 64k -f mp3 pipe:1 > "$WORK/selftest.mp3"
[[ -s "$WORK/selftest.mp3" ]] || { echo "错误：语音通路自检失败" >&2; exit 1; }
echo "语音通路自检通过（$(wc -c < "$WORK/selftest.mp3") 字节 MP3）"

# ffprobe 要能数出帧数，wx-cli 靠它区分动图与静图
"$BUILT_PROBE" -hide_banner -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$WORK/selftest.mp3" >/dev/null 2>&1 || true
"$BUILT_PROBE" -hide_banner -version >/dev/null 2>&1 \
  || { echo "错误：ffprobe 无法运行" >&2; exit 1; }
echo "ffprobe 自检通过"

# 确认没有非系统动态库依赖，否则换机即挂
for bin in "$BUILT" "$BUILT_PROBE"; do
  NONSYS="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' \
    | grep -v '^/usr/lib/' | grep -v '^/System/Library/' || true)"
  if [[ -n "$NONSYS" ]]; then
    echo "错误：$(basename "$bin") 存在非系统动态库依赖，静态构建未生效：" >&2
    echo "$NONSYS" >&2
    exit 1
  fi
done
echo "动态库依赖检查通过（仅系统库）"

# ------------------------------------------------------------------ 安装
mkdir -p "$(dirname "$OUTPUT")"
cp "$BUILT" "$OUTPUT"
cp "$BUILT_PROBE" "$OUTPUT_PROBE"
strip -S -x "$OUTPUT" "$OUTPUT_PROBE" 2>/dev/null || true
chmod +x "$OUTPUT" "$OUTPUT_PROBE"

# LGPL 要求随分发提供许可证全文
cp "$WORK/ffmpeg-${FFMPEG_VERSION}/COPYING.LGPLv2.1" "$(dirname "$OUTPUT")/ffmpeg-COPYING.LGPLv2.1"

echo ""
echo "完成：${OUTPUT} （$(du -h "$OUTPUT" | cut -f1)）"
echo "      ${OUTPUT_PROBE} （$(du -h "$OUTPUT_PROBE" | cut -f1)）"
echo "许可证：$(dirname "$OUTPUT")/ffmpeg-COPYING.LGPLv2.1"
