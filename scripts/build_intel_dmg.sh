#!/bin/bash
# 打包 Intel CPU（x86_64）可用的 DMG。
#
# 在 Intel Mac 上原生编译；在 Apple Silicon 上交叉编译 x86_64。
# 产物：dist/MenuBarMijia-<version>-x86_64.dmg
#
# 用法：
#   bash scripts/build_intel_dmg.sh
#   SKIP_APP_INTENTS=1 bash scripts/build_intel_dmg.sh   # 仅本机 ad-hoc 自用
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export MACOS_ARCHS="${MACOS_ARCHS:-x86_64}"
export MAKE_DMG="${MAKE_DMG:-1}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
exec bash "$ROOT/scripts/build_app.sh"
