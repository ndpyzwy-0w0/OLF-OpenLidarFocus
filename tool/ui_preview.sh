#!/usr/bin/env bash
# 本地 UI 预览：构建 release web 包 + 起静态服务器 + 打开浏览器。
#
# 为什么不用 `flutter run -d web-server`：那是 DDC 调试包（几百个模块文件 + dwds
# 热重载客户端），在这台只有 Safari 的机器上会长时间白屏（见 UI_DEV.md）。
# release 静态包是单个 main.dart.js + 本地 canvaskit，且不加 Service Worker，
# 改完代码重新构建再刷新就能看到，不会被旧缓存顶住。
#
# 用法：
#   tool/ui_preview.sh                 # 构建 + 起服务，默认端口 8123
#   PORT=9000 tool/ui_preview.sh       # 换端口
#   SKIP_BUILD=1 tool/ui_preview.sh    # 只起服务，不重新构建
#
# 页面里是演示核心 FfCoreDemo（假数据，不连硬件）。它不是第二份控制逻辑，
# 详情见 UI_DEV.md。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PORT="${PORT:-8123}"

command -v flutter >/dev/null 2>&1 || {
  echo "找不到 flutter，先把它加进 PATH" >&2
  exit 1
}

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> 构建 release web 包（约 50 秒）"
  flutter build web --release --pwa-strategy=none
fi

[[ -f "$ROOT/build/web/main.dart.js" ]] || {
  echo "build/web 里没有产物，先构建一次（去掉 SKIP_BUILD）" >&2
  exit 1
}

echo "==> http://127.0.0.1:$PORT/    （Ctrl-C 停止）"
echo "    改完 Dart 代码要重新跑本脚本；静态包没有热重载。"
( sleep 2; open "http://127.0.0.1:$PORT/" ) &
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/build/web"
