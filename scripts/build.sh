#!/usr/bin/env bash
#
# 在 macOS 上编译（Xcode 自带的最新 iPhoneOS SDK）：
#   out/MMFontSubstitute.dylib          注入用（TrollFools / Sideloadly / 越狱）
#   out/MMFontSubstitute-rootful.deb    传统越狱 (iOS 14–15, /Library)
#   out/MMFontSubstitute-rootless.deb   无根越狱 (iOS 15+, /var/jb)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME="MMFontSubstitute"
PKG="com.yg.mmfontsubstitute"
VERSION="2.0.0"
MIN_IOS="15.0"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 环境 ----------
command -v xcrun >/dev/null 2>&1 || die "没有 xcrun：需要 macOS + Xcode"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDKVER="$(xcrun --sdk iphoneos --show-sdk-version)"
log "iPhoneOS SDK ${SDKVER}  (${SDK})"

FONT="$ROOT/font/MMFont.ttf"
[ -f "$FONT" ] || die "缺字体：font/MMFont.ttf"
FONT_SIZE=$(wc -c < "$FONT" | tr -d ' ')
log "字体 ${FONT_SIZE} bytes"

rm -rf build out
mkdir -p build out

# ---------- 编译 ----------
CFLAGS=(
  -target "arm64-apple-ios${MIN_IOS}"
  -arch arm64
  -dynamiclib
  -fobjc-arc
  -fblocks
  -O2
  -Wall
  -Wno-unused-parameter
  -Wno-deprecated-declarations
  -isysroot "$SDK"
  -I"$ROOT/src"
)

LIBS=(
  -framework UIKit
  -framework Foundation
  -framework CoreText
  -framework CoreGraphics
)

LDFLAGS=(
  -Wl,-undefined,dynamic_lookup
  -Wl,-sectcreate,__DATA,__mmfont,"$FONT"
)

log "编译 dylib"
clang "${CFLAGS[@]}" "${LDFLAGS[@]}" "${LIBS[@]}" \
  -o "build/${NAME}.dylib" \
  src/MMFontCore.m src/MMFontHooks.m src/MMFontEntry.m

# ---------- 签名 ----------
if command -v ldid >/dev/null 2>&1; then
  log "ldid 签名"
  ldid -S "build/${NAME}.dylib"
elif command -v codesign >/dev/null 2>&1; then
  log "codesign 临时签名"
  codesign --force --sign - "build/${NAME}.dylib" || true
fi

# ---------- 自检 ----------
SIZE=$(wc -c < "build/${NAME}.dylib" | tr -d ' ')
log "dylib ${SIZE} bytes"
[ "$SIZE" -gt 10000000 ] || die "字体没塞进 dylib（体积只有 ${SIZE}）"

log "Mach-O 段检查"
otool -l "build/${NAME}.dylib" | grep -A3 "__mmfont" || die "找不到 __mmfont 段"
file "build/${NAME}.dylib"

if nm -u "build/${NAME}.dylib" 2>/dev/null | grep -q "MSHookFunction"; then
  die "dylib 不该链接 MSHookFunction（运行时 dlsym 才对）"
fi

# ---------- 打 deb ----------
package_deb() {
  local arch="$1"
  local prefix="$2"
  local outfile="$3"
  local root="build/root-${arch}"
  local dl="$root${prefix}/Library/MobileSubstrate/DynamicLibraries"

  rm -rf "$root"
  mkdir -p "$root/DEBIAN" "$dl"
  cp "build/${NAME}.dylib" "$dl/"
  cp "packaging/${NAME}.plist" "$dl/"

  local installed
  installed=$(du -sk "$root" | awk '{print $1}')

  cat > "$root/DEBIAN/control" <<EOF
Package: ${PKG}
Name: MMFontSubstitute
Version: ${VERSION}
Architecture: ${arch}
Description: 全局字体替换：所有 App（包括写死字体的 App）统一使用「渡-果の棉花宝宝加粗改の」，字体内嵌在 dylib 里，无需额外文件。
Maintainer: YG
Author: YG
Section: Tweaks
Depends: mobilesubstrate | ellekit
Installed-Size: ${installed}
EOF

  dpkg-deb --root-owner-group -Zgzip --build "$root" "out/${outfile}"
  log "已生成 out/${outfile}"
}

command -v dpkg-deb >/dev/null 2>&1 || die "没有 dpkg-deb：brew install dpkg"

package_deb "iphoneos-arm"  ""        "MMFontSubstitute-rootful.deb"
package_deb "iphoneos-arm64" "/var/jb" "MMFontSubstitute-rootless.deb"

cp "build/${NAME}.dylib" "out/${NAME}.dylib"
cp "$FONT" "out/MMFont.ttf"

log "产物"
ls -lh out
shasum -a 256 out/* 2>/dev/null || true
