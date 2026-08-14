#!/usr/bin/env bash
# 构建 macOS 原生 App：编译 → 渲染图标 → 组装 .app
set -euo pipefail
cd "$(dirname "$0")/.."

CLANG_FLAGS=(-fobjc-arc -O2 -framework AppKit -framework WebKit -framework ServiceManagement)
OUT="DeepSeek Harness 启动台.app"

echo "[1/4] clang 编译…"
clang "${CLANG_FLAGS[@]}" -o build/launcher-bin macos/main.m

echo "[2/4] 渲染图标…"
mkdir -p build
qlmanage -t -s 1024 -o build macos/icon.svg >/dev/null 2>&1 || { echo "qlmanage 渲染失败"; exit 1; }
mv build/icon.svg.png build/icon-1024.png
rm -rf build/app.iconset && mkdir build/app.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/app.iconset/icon_${s}x${s}.png >/dev/null 2>&1
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/app.iconset/icon_${s}x${s}@2x.png >/dev/null 2>&1
done
iconutil -c icns build/app.iconset -o build/app.icns

echo "[3/4] 组装 ${OUT}…"
rm -rf "${OUT}"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp build/launcher-bin "$OUT/Contents/MacOS/DSH Launcher"
cp shared/index.html "$OUT/Contents/Resources/index.html"
cp build/app.icns "$OUT/Contents/Resources/app.icns"
cp macos/Info.plist "$OUT/Contents/Info.plist"

echo "[4/4] 完成：${OUT}"
echo "自测："
echo "  ./$OUT/Contents/MacOS/DSH\\ Launcher --probe"
echo "  DSH_LAUNCHER_DSH_PORT=4895 ./$OUT/Contents/MacOS/DSH\\ Launcher --selftest"
