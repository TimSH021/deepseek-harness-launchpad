#!/usr/bin/env bash
# Linux / macOS 启动入口：确保控制服务在跑，然后打开启动页
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${LAUNCHER_PORT:-4899}"
URL="http://127.0.0.1:${PORT}/"

command -v curl >/dev/null 2>&1 && page_up() { curl -fsS -m 2 "$URL" >/dev/null 2>&1; } \
  || page_up() { wget -q --timeout=2 -O /dev/null "$URL" 2>/dev/null; }

if page_up; then
  xdg-open "$URL" 2>/dev/null || open "$URL" 2>/dev/null || echo "已就绪: $URL"
  exit 0
fi

NODE_BIN="$(command -v node || true)"
[ -z "$NODE_BIN" ] && for c in /usr/local/bin/node /usr/bin/node "$HOME"/.nvm/versions/node/*/bin/node; do
  [ -x "$c" ] && NODE_BIN="$c" && break
done
if [ -z "$NODE_BIN" ]; then
  echo "未找到 node，请先安装 Node.js（dsh 也依赖它）" >&2
  exit 1
fi

nohup "$NODE_BIN" "$DIR/server.js" >> "$DIR/state-server.log" 2>&1 &
disown

for _ in $(seq 1 40); do
  if page_up; then break; fi
  sleep 0.25
done

xdg-open "$URL" 2>/dev/null || open "$URL" 2>/dev/null || echo "已就绪: $URL"
