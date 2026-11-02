#!/bin/bash
# 打包 MenuBarMijia.app。
#
# 架构：
#   本机默认只编当前 CPU（Intel → x86_64，Apple Silicon → arm64）。
#   Intel 安装包：MACOS_ARCHS=x86_64 MAKE_DMG=1 bash scripts/build_app.sh
#   通用二进制：REQUIRE_UNIVERSAL=1 bash scripts/build_app.sh
#   显式指定：MACOS_ARCHS="arm64 x86_64"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# scripts/check.sh installs the shared pre-commit hook; keeping one owner avoids a stale link.

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo 1.0.0)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
# 留空 =优先使用本机钥匙串中的 "MenuBarMijia Release Signing" 固定签名证书（支持应用内自更新），
# 找不到时退回本机临时 ad-hoc 签名；发布或 CI 可显式传入：
#   MACOS_SIGNING_IDENTITY  codesign 身份名称（CI secret 导入后自动填）
#   MACOS_CERT_SHA1         该证书的 SHA-1（40 位十六进制），会写进 Info.plist 供更新校验钉住
# SIGN_IDENTITY 为旧调用方式（scripts/release.sh）保留。
DEFAULT_RELEASE_SIGN_IDENTITY="MenuBarMijia Release Signing"
if [ -z "${MACOS_SIGNING_IDENTITY:-}" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEFAULT_RELEASE_SIGN_IDENTITY\""; then
        SIGN_IDENTITY="$DEFAULT_RELEASE_SIGN_IDENTITY"
    else
        SIGN_IDENTITY="-"
    fi
else
    SIGN_IDENTITY="${MACOS_SIGNING_IDENTITY:-${SIGN_IDENTITY:--}}"
fi
MACOS_CERT_SHA1="$(printf '%s' "${MACOS_CERT_SHA1:-}" | tr 'A-F' 'a-f')"
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$MACOS_CERT_SHA1" ]; then
    MACOS_CERT_SHA1="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -v id="$SIGN_IDENTITY" 'index($0, id) { print $2; exit }' \
        | tr 'A-F' 'a-f' || true)"
fi
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$MACOS_CERT_SHA1" ]; then
    MACOS_CERT_SHA1="$(security find-certificate -c "$SIGN_IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha1 2>/dev/null \
        | sed 's/^.*=//' \
        | tr -d ':' \
        | tr 'A-F' 'a-f' || true)"
fi
if [ "$SIGN_IDENTITY" != "-" ] && [ -z "$MACOS_CERT_SHA1" ]; then
    echo "❌ 无法确定签名证书 SHA-1，已停止打包；应用内更新必须钉住签名身份。" >&2
    exit 1
fi
if [ -n "$MACOS_CERT_SHA1" ] && ! printf '%s' "$MACOS_CERT_SHA1" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "❌ MACOS_CERT_SHA1 必须是 40 位十六进制证书 SHA-1" >&2
    exit 1
fi

# Intel Mac 与 Apple Silicon 都能打包：
#   本机默认只编当前 CPU（Intel → x86_64，Apple Silicon → arm64），避免交叉编译失败把整包打断。
#   发布 / CI 设 REQUIRE_UNIVERSAL=1，必须产出 arm64 + x86_64 通用二进制。
#   也可显式指定：MACOS_ARCHS="x86_64" 或 MACOS_ARCHS="arm64 x86_64"。
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64|x86_64) ;;
    *) HOST_ARCH="x86_64" ;;
esac
if [ "${REQUIRE_UNIVERSAL:-0}" = "1" ]; then
    MACOS_ARCHS="${MACOS_ARCHS:-arm64 x86_64}"
else
    MACOS_ARCHS="${MACOS_ARCHS:-$HOST_ARCH}"
fi
REQUESTED_ARCHS=""
for arch in $MACOS_ARCHS; do
    case "$arch" in
        arm64|x86_64)
            if ! printf '%s' " $REQUESTED_ARCHS " | grep -q " $arch "; then
                REQUESTED_ARCHS="${REQUESTED_ARCHS:+$REQUESTED_ARCHS }$arch"
            fi
            ;;
        *)
            echo "❌ 不支持的 MACOS_ARCHS 值：$arch（仅 arm64 / x86_64）" >&2
            exit 1
            ;;
    esac
done
[ -n "$REQUESTED_ARCHS" ] || { echo "❌ MACOS_ARCHS 为空" >&2; exit 1; }

binary_covers_archs() {
    local binary="$1"
    local needed="$2"
    local have arch
    have="$(lipo -archs "$binary" 2>/dev/null || true)"
    for arch in $needed; do
        printf '%s' "$have" | grep -qw "$arch" || return 1
    done
    return 0
}

BUILT_BINS=""
BUILT_ARCHS=""
RESOURCE_BUNDLE=""
for arch in $REQUESTED_ARCHS; do
    echo "▶ 正在编译 MenuBarMijiaApp $VERSION (Release $arch, macOS ${MACOSX_DEPLOYMENT_TARGET}+)..."
    if ! swift build -c release --product MenuBarMijiaApp --arch "$arch"; then
        if [ "${REQUIRE_UNIVERSAL:-0}" = "1" ]; then
            echo "❌ REQUIRE_UNIVERSAL=1：$arch 编译失败，已中止发布打包" >&2
            exit 1
        fi
        echo "⚠️ $arch 编译失败，继续尝试其余架构"
        continue
    fi
    arch_bin="$(swift build -c release --product MenuBarMijiaApp --arch "$arch" --show-bin-path)/MenuBarMijiaApp"
    if ! binary_covers_archs "$arch_bin" "$arch"; then
        echo "⚠️ $arch 产物未包含该切片（当前：$(lipo -archs "$arch_bin" 2>/dev/null || echo 未知)），跳过" >&2
        if [ "${REQUIRE_UNIVERSAL:-0}" = "1" ]; then
            exit 1
        fi
        continue
    fi
    BUILT_BINS="${BUILT_BINS:+$BUILT_BINS }$arch_bin"
    BUILT_ARCHS="${BUILT_ARCHS:+$BUILT_ARCHS }$arch"
    if [ -z "$RESOURCE_BUNDLE" ]; then
        candidate="$(dirname "$arch_bin")/MenuBarMijia_MijiaCore.bundle"
        [ -d "$candidate" ] && RESOURCE_BUNDLE="$candidate"
    fi
done
if [ -z "$BUILT_ARCHS" ]; then
    echo "❌ 没有成功编译任何 macOS 架构（请求：${REQUESTED_ARCHS}）" >&2
    exit 1
fi
if [ "${REQUIRE_UNIVERSAL:-0}" = "1" ] && { ! printf '%s' "$BUILT_ARCHS" | grep -qw "arm64" || ! printf '%s' "$BUILT_ARCHS" | grep -qw "x86_64"; }; then
    echo "❌ REQUIRE_UNIVERSAL=1：发布二进制缺少通用架构支持（当前：${BUILT_ARCHS}，期望：arm64 + x86_64）" >&2
    exit 1
fi

FAT_BIN="$ROOT/.build/MenuBarMijiaApp-macos"
mkdir -p "$ROOT/.build"
# shellcheck disable=SC2086
if [ "$(printf '%s' "$BUILT_BINS" | wc -w | tr -d ' ')" = "1" ]; then
    cp $BUILT_BINS "$FAT_BIN"
else
    # shellcheck disable=SC2086
    lipo -create $BUILT_BINS -output "$FAT_BIN"
fi
chmod +x "$FAT_BIN"
BIN_PATH="$FAT_BIN"
ARCHS="$(lipo -archs "$BIN_PATH" 2>/dev/null || true)"
echo "✅ 已生成安装包二进制（${ARCHS}）"
APP_DIR="$ROOT/MenuBarMijia.app"
rm -rf "$ROOT/米家控制中心.app" "$ROOT/MenuMijia.app"  # 清理旧名字产物

WAS_RUNNING=0
if pgrep -x MenuBarMijiaApp >/dev/null 2>&1; then
    WAS_RUNNING=1
    killall MenuBarMijiaApp 2>/dev/null || true
    sleep 0.5
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$ROOT/Resources/AppIcon/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/AppIcon/AppIcon-Dark.icns" "$APP_DIR/Contents/Resources/AppIcon-Dark.icns"
cp "$ROOT/Resources/AppIcon/AppIcon-Light.icns" "$APP_DIR/Contents/Resources/AppIcon-Light.icns"
cp "$ROOT/Resources/AppIcon/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
if [ -z "$RESOURCE_BUNDLE" ] || [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "❌ 缺少本地化资源包 MenuBarMijia_MijiaCore.bundle" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/MenuBarMijia_MijiaCore.bundle"

GO2RTC_CACHED="$HOME/Library/Application Support/MenuBarMijia/bin/go2rtc"
GO2RTC_ARCHS="$(lipo -archs "$GO2RTC_CACHED" 2>/dev/null || true)"
if [ ! -x "$GO2RTC_CACHED" ] || ! binary_covers_archs "$GO2RTC_CACHED" "$BUILT_ARCHS"; then
    echo "▶ 正在准备 go2rtc ($BUILT_ARCHS, v1.9.15)..."
    GO2RTC_TMP="$(mktemp -d)"
    GO2RTC_ARM64_SHA256="d0cf858a71803dce2377423bc830639137ee96c335f88e9912e7f7898374266d"
    GO2RTC_AMD64_SHA256="7ca6075421b824eebe0383d20bd42a6f6a7ec7591a60931d42290f1d375169b9"
    GO2RTC_ARM64_OK=0
    GO2RTC_AMD64_OK=0
    if curl -fsSL --retry 2 --max-time 45 "https://github.com/AlexxIT/go2rtc/releases/download/v1.9.15/go2rtc_mac_arm64.zip" -o "$GO2RTC_TMP/arm64.zip" \
        && [ "$(shasum -a 256 "$GO2RTC_TMP/arm64.zip" | awk '{print $1}')" = "$GO2RTC_ARM64_SHA256" ]; then
        mkdir -p "$GO2RTC_TMP/arm64"
        ditto -x -k "$GO2RTC_TMP/arm64.zip" "$GO2RTC_TMP/arm64"
        GO2RTC_ARM64_OK=1
    fi
    if curl -fsSL --retry 2 --max-time 45 "https://github.com/AlexxIT/go2rtc/releases/download/v1.9.15/go2rtc_mac_amd64.zip" -o "$GO2RTC_TMP/amd64.zip" \
        && [ "$(shasum -a 256 "$GO2RTC_TMP/amd64.zip" | awk '{print $1}')" = "$GO2RTC_AMD64_SHA256" ]; then
        mkdir -p "$GO2RTC_TMP/amd64"
        ditto -x -k "$GO2RTC_TMP/amd64.zip" "$GO2RTC_TMP/amd64"
        GO2RTC_AMD64_OK=1
    fi
    mkdir -p "$(dirname "$GO2RTC_CACHED")"
    if [ "$GO2RTC_ARM64_OK" = "1" ] && [ "$GO2RTC_AMD64_OK" = "1" ]; then
        lipo -create "$GO2RTC_TMP/arm64/go2rtc" "$GO2RTC_TMP/amd64/go2rtc" -output "$GO2RTC_CACHED"
        chmod 755 "$GO2RTC_CACHED"
        GO2RTC_ARCHS="$(lipo -archs "$GO2RTC_CACHED" 2>/dev/null || true)"
        echo "✅ 已合成为通用架构 go2rtc ($GO2RTC_ARCHS)"
    elif [ "$GO2RTC_AMD64_OK" = "1" ] && printf '%s' "$BUILT_ARCHS" | grep -qw "x86_64" && ! printf '%s' "$BUILT_ARCHS" | grep -qw "arm64"; then
        cp "$GO2RTC_TMP/amd64/go2rtc" "$GO2RTC_CACHED"
        chmod 755 "$GO2RTC_CACHED"
        echo "✅ 已写入 Intel (x86_64) go2rtc"
    elif [ "$GO2RTC_ARM64_OK" = "1" ] && printf '%s' "$BUILT_ARCHS" | grep -qw "arm64" && ! printf '%s' "$BUILT_ARCHS" | grep -qw "x86_64"; then
        cp "$GO2RTC_TMP/arm64/go2rtc" "$GO2RTC_CACHED"
        chmod 755 "$GO2RTC_CACHED"
        echo "✅ 已写入 Apple Silicon (arm64) go2rtc"
    else
        echo "⚠️ 未能下载与当前架构匹配的 go2rtc（运行时首次打开摄像机将按需自动补齐）"
    fi
    rm -rf "$GO2RTC_TMP"
fi
if [ -x "$GO2RTC_CACHED" ]; then
    GO2RTC_ARCHS="$(lipo -archs "$GO2RTC_CACHED" 2>/dev/null || true)"
    if binary_covers_archs "$GO2RTC_CACHED" "$BUILT_ARCHS"; then
        mkdir -p "$APP_DIR/Contents/Resources/bin"
        cp "$GO2RTC_CACHED" "$APP_DIR/Contents/Resources/bin/go2rtc"
        chmod +x "$APP_DIR/Contents/Resources/bin/go2rtc"
    else
        echo "ℹ️ 本机缓存的 go2rtc（${GO2RTC_ARCHS:-未知}）未覆盖安装包架构 ${BUILT_ARCHS}，跳过打入（本机运行仍可直接使用缓存或 Homebrew 路径）"
    fi
fi

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"
chmod +x "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"
strip -S -x "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"
SYMBOL_TABLE=""
for arch in $BUILT_ARCHS; do
    if ! arch_syms="$(nm -arch "$arch" -ap "$APP_DIR/Contents/MacOS/MenuBarMijiaApp")"; then
        echo "❌ 无法读取 MenuBarMijiaApp $arch 符号表，不能确认发布包是否泄露本机路径。" >&2
        exit 1
    fi
    SYMBOL_TABLE="${SYMBOL_TABLE}${arch_syms}"$'\n'
done
LEAKED_SYMBOLS="$(printf '%s\n' "$SYMBOL_TABLE" | grep "/Users/" || true)"
if [ -n "$LEAKED_SYMBOLS" ]; then
    echo "❌ MenuBarMijiaApp 符号表中仍残留本地编译路径 (/Users/)！"
    printf '%s\n' "$LEAKED_SYMBOLS" | head -n 5 >&2
    exit 1
fi
if grep -aq "/Users/" "$APP_DIR/Contents/MacOS/MenuBarMijiaApp"; then
    echo "❌ MenuBarMijiaApp 二进制中仍残留本地编译路径 (/Users/)！" >&2
    grep -aob "/Users/" "$APP_DIR/Contents/MacOS/MenuBarMijiaApp" | head -n 5 >&2
    exit 1
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>MenuBarMijia</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>MenuBarMijiaApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.jryang1997.MenuBarMijia</string>
    <!-- #57 External URL Scheme: menumijia://toggle?device=…, scene?name=…, ask?text=…
         App Intents themselves need Metadata.appintents, which Xcode's
         appintentsmetadataprocessor emits; SwiftPM does not produce the compiler's const-value
         side outputs, so Shortcuts discovery may require an Xcode-project build. The URL Scheme
         and in-app execution are unaffected. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.jryang1997.MenuBarMijia.external</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>menumijia</string>
            </array>
        </dict>
    </array>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MenuBarMijia</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>用于局域网自动发现并实时连接 Home Assistant 及电视等智能家居设备。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_home-assistant._tcp</string>
    </array>
    <key>NSMicrophoneUsageDescription</key>
    <string>用于通过语音指令直接控制米家智能家居设备。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>用于将您的中文语音指令实时识别为智能家居控制动作。</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

mkdir -p "$APP_DIR/Contents/Resources/zh-Hans.lproj"
cat > "$APP_DIR/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS_ZH'
"NSLocalNetworkUsageDescription" = "用于局域网自动发现并实时连接 Home Assistant 及电视等智能家居设备。";
"NSMicrophoneUsageDescription" = "用于通过语音指令直接控制米家智能家居设备。";
"NSSpeechRecognitionUsageDescription" = "用于将您的语音指令实时识别为智能家居控制动作。";
STRINGS_ZH

mkdir -p "$APP_DIR/Contents/Resources/en.lproj"
cat > "$APP_DIR/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS_EN'
"NSLocalNetworkUsageDescription" = "Used to automatically discover and connect to Home Assistant and smart TVs on your local network.";
"NSMicrophoneUsageDescription" = "Used to control your Xiaomi Home smart devices with voice commands.";
"NSSpeechRecognitionUsageDescription" = "Used to transcribe your voice commands into smart home actions in real time.";
STRINGS_EN

# SwiftPM executable targets emit const values through Xcode but do not run the app metadata
# extraction phase. Build those values with Xcode, then process them before signing the bundle.
APP_INTENTS_MODULE="MenuBarMijiaApp"
APP_INTENTS_BUNDLE_ID="com.jryang1997.MenuBarMijia"
APP_INTENTS_DEPLOYMENT_TARGET="14.0"

# Xcode writes `extract.actionsdata` directly into `--output`; accept either that layout or a
# nested Metadata.appintents so both the processor and xcodebuild outputs can be harvested.
app_intents_bundle_dir() {
    local candidate="$1"
    if [ -f "$candidate/extract.actionsdata" ]; then
        printf '%s\n' "$candidate"
    elif [ -f "$candidate/Metadata.appintents/extract.actionsdata" ]; then
        printf '%s\n' "$candidate/Metadata.appintents"
    fi
}

generate_app_intents_metadata_via_xcode() {
    # Xcode's build graph requests const values itself and runs ExtractAppIntentsMetadata per target.
    local derived="$ROOT/.build/appintents-derived"
    command -v xcodebuild >/dev/null 2>&1 || return 1
    rm -rf "$derived"
    mkdir -p "$derived"

    # SwiftPM exposes one scheme per product; consult the list instead of assuming a name.
    local listing name
    local -a candidates=()
    listing="$(xcodebuild -list -json -derivedDataPath "$derived" 2>/dev/null || true)"
    while IFS= read -r name; do
        [ -n "$name" ] && candidates+=("$name")
    done < <(printf '%s' "$listing" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    candidates+=("$APP_INTENTS_MODULE")

    local built=0 scheme
    # macOS ships bash 3.2, where expanding an empty array under `set -u` is an error.
    for scheme in "${candidates[@]+"${candidates[@]}"}"; do
        case "$scheme" in
        *"$APP_INTENTS_MODULE"*) ;;
        *) continue ;;
        esac
        if xcodebuild \
            -scheme "$scheme" \
            -destination "platform=macOS,arch=${HOST_ARCH}" \
            ARCHS="$HOST_ARCH" \
            ONLY_ACTIVE_ARCH=YES \
            -configuration Release \
            -derivedDataPath "$derived" \
            build >"$ROOT/.build/appintents-build.log" 2>&1; then
            built=1
            break
        fi
    done
    if [ "$built" = "0" ]; then
        echo "   （xcodebuild 未能构建含 $APP_INTENTS_MODULE 的 scheme；可用 xcodebuild -list 查看）" >&2
        tail -n 40 "$ROOT/.build/appintents-build.log" >&2
        return 1
    fi

    local bundle
    bundle="$(app_intents_bundle_dir "$derived/Build/Products/Release/$APP_INTENTS_MODULE.appintents")"
    if [ -z "$bundle" ]; then
        local developer_dir toolchain sdk_root xcode_version
        developer_dir="$(xcode-select -p)"
        toolchain="$developer_dir/Toolchains/XcodeDefault.xctoolchain"
        sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
        xcode_version="$(xcodebuild -version | awk '/Build/ {print $3; exit}')"
        find "$derived" -path "*/${APP_INTENTS_MODULE}*.build/*" -name '*.swiftconstvalues' > "$derived/constvals.txt"
        find "$ROOT/Sources/$APP_INTENTS_MODULE" -name '*.swift' > "$derived/sources.txt"
        if [ ! -s "$derived/constvals.txt" ]; then
            echo "❌ Xcode 构建未产生 ${APP_INTENTS_MODULE} 的 swiftconstvalues，构建日志：$ROOT/.build/appintents-build.log" >&2
            find "$derived" -name '*.swiftconstvalues' >&2
            return 1
        fi
        "$toolchain/usr/bin/appintentsmetadataprocessor" \
            --toolchain-dir "$toolchain" \
            --module-name "$APP_INTENTS_MODULE" \
            --sdk-root "$sdk_root" \
            --xcode-version "$xcode_version" \
            --platform-family macOS \
            --deployment-target "$APP_INTENTS_DEPLOYMENT_TARGET" \
            --bundle-identifier "$APP_INTENTS_BUNDLE_ID" \
            --output "$derived/metadata" \
            --target-triple "$(uname -m)-apple-macos${APP_INTENTS_DEPLOYMENT_TARGET}" \
            --binary-file "$derived/Build/Products/Release/$APP_INTENTS_MODULE" \
            --source-file-list "$derived/sources.txt" \
            --swift-const-vals-list "$derived/constvals.txt" \
            --force --compile-time-extraction --no-app-shortcuts-localization || return 1
        bundle="$(app_intents_bundle_dir "$derived/metadata")"
        [ -n "$bundle" ] || return 1
    fi
    rm -rf "$APP_DIR/Contents/Resources/Metadata.appintents"
    cp -R "$bundle" "$APP_DIR/Contents/Resources/Metadata.appintents"
    rm -rf "$derived"
    return 0
}

generate_app_intents_metadata() {
    local resources="$APP_DIR/Contents/Resources/Metadata.appintents"
    rm -rf "$resources"

    if [ ! -f "$resources/extract.actionsdata" ]; then
        echo "ℹ️ 生成 App Intents 元数据（xcodebuild ExtractAppIntentsMetadata）..."
        if ! generate_app_intents_metadata_via_xcode; then
            echo "❌ 无法生成 App Intents 元数据（Metadata.appintents）。" >&2
            echo "   缺了它，快捷指令 / Siri / Spotlight 看不到任何动作，属于 #57 的交付缺失，已中止打包。" >&2
            echo "   排查：xcode-select -p 必须指向完整 Xcode；xcodebuild -list 应列出 ${APP_INTENTS_MODULE}。" >&2
            echo "   （若仅本机自用且只安装了 Command Line Tools，可运行 SKIP_APP_INTENTS=1 bash scripts/build_app.sh 跳过）" >&2
            exit 1
        fi
    fi

    if [ ! -f "$resources/extract.actionsdata" ]; then
        echo "❌ 元数据目录缺少 extract.actionsdata，动作不会被系统注册，已中止打包。" >&2
        exit 1
    fi

    echo "🧩 已嵌入 App Intents 元数据：$(du -h "$resources/extract.actionsdata" | awk '{print $1}') extract.actionsdata（快捷指令 / Siri 可发现）"
}
if [ "${SKIP_APP_INTENTS:-0}" = "1" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    rm -rf "$APP_DIR/Contents/Resources/Metadata.appintents"
    echo "⚠️ 已跳过 App Intents 元数据生成（SKIP_APP_INTENTS=1，仅限本机 ad-hoc 自用）"
else
    generate_app_intents_metadata
fi

if [ -n "$MACOS_CERT_SHA1" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    /usr/libexec/PlistBuddy -c "Delete :MijiaCodeSignCertSHA1" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :MijiaCodeSignCertSHA1 string $MACOS_CERT_SHA1" "$APP_DIR/Contents/Info.plist"
    echo "🔏 已钉住代码签名证书 SHA-1：$MACOS_CERT_SHA1"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "⚠️ 未设置 MACOS_SIGNING_IDENTITY：使用 ad-hoc 签名，仅适合本机运行，应用内更新已禁用；发布包必须用固定证书签名。"
    if [ -f "$APP_DIR/Contents/Resources/bin/go2rtc" ]; then
        codesign --force --sign - "$APP_DIR/Contents/Resources/bin/go2rtc"
    fi
    codesign --force --sign - "$APP_DIR"
else
    # 正式签名：开启 Hardened Runtime（苹果公证的前提），并声明麦克风权限。
    # 只有 Apple 签发的证书才向苹果申请时间戳；自签名证书没有 Apple 信任链，申请会失败。
    CODESIGN_ARGS=(--force --options runtime)
    if security find-certificate -c "$SIGN_IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null \
        | grep -q "Apple"; then
        CODESIGN_ARGS+=(--timestamp)
    fi
    if [ -f "$APP_DIR/Contents/Resources/bin/go2rtc" ]; then
        codesign "${CODESIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/Resources/bin/go2rtc"
    fi
    codesign "${CODESIGN_ARGS[@]}" \
        --entitlements "$ROOT/scripts/MenuBarMijia.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
echo "✅ 已打包完成：${APP_DIR}（架构：${ARCHS}）"

if [ "${MAKE_DMG:-0}" = "1" ]; then
    DIST="$ROOT/dist"
    rm -rf "$DIST/stage"
    mkdir -p "$DIST/stage"
    cp -R "$APP_DIR" "$DIST/stage/"
    ln -s /Applications "$DIST/stage/Applications"
    if printf '%s' "$BUILT_ARCHS" | grep -qw "arm64" && printf '%s' "$BUILT_ARCHS" | grep -qw "x86_64"; then
        DMG_NAME="MenuBarMijia-$VERSION.dmg"
    elif printf '%s' "$BUILT_ARCHS" | grep -qw "x86_64"; then
        DMG_NAME="MenuBarMijia-$VERSION-x86_64.dmg"
    else
        DMG_NAME="MenuBarMijia-$VERSION-arm64.dmg"
    fi
    DMG="$DIST/$DMG_NAME"
    echo "▶ 正在制作 DMG（${DMG_NAME}，架构：${ARCHS}）..."
    hdiutil create -volname "MenuBarMijia $VERSION" -srcfolder "$DIST/stage" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$DIST/stage"
    (cd "$DIST" && shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256")
    echo "✅ 已生成 Intel/当前架构安装包：$DMG"
fi

if [ "$WAS_RUNNING" = "1" ]; then
    open "$APP_DIR"
    echo "🔄 已自动重启 MenuBarMijia.app"
fi
