#!/bin/bash

# 剪贴板历史工具构建脚本

set -e

echo "======================================"
echo "开始构建剪贴板历史工具"
echo "======================================"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 项目配置
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="剪贴板历史"
BUNDLE_ID="com.clipboard.history"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# 清理旧的构建
echo -e "${YELLOW}清理旧的构建文件...${NC}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 创建应用包结构
echo -e "${YELLOW}创建应用包结构...${NC}"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 编译 Swift 代码
echo -e "${YELLOW}编译 Swift 源代码...${NC}"

# 自动检测 SDK 路径（显式指定 macosx，避免拿到不匹配的 SDK）
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)

# 使用与 SDK 同一套 DeveloperDir/Toolchain 的 swiftc，避免 “SDK 与编译器版本不匹配”
SWIFTC=$(xcrun --sdk macosx --find swiftc)
echo -e "${YELLOW}使用 SDK: ${SDK_PATH}${NC}"
echo -e "${YELLOW}使用 swiftc: ${SWIFTC}${NC}"

HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "arm64" ]; then
    echo -e "${RED}错误: 当前仅支持 Apple Silicon (arm64) 的 macOS（检测到: ${HOST_ARCH}）${NC}"
    echo -e "${YELLOW}请在 arm64 Mac 上构建/运行；不再支持 Intel x86_64 或 Rosetta 2。${NC}"
    exit 1
fi

# 仅构建 arm64（Apple Silicon）
TARGET_ARM64="arm64-apple-macosx11.0"

SRC_FILES=(
    "$PROJECT_DIR/ClipboardHistory/Sources/ClipboardItem.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/ClipboardManager.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/KeyboardShortcutManager.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/HistoryWindowController.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/SettingsWindowController.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/AppearanceSettings.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/FeatureSettings.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/AppDelegate.swift"
    "$PROJECT_DIR/ClipboardHistory/Sources/main.swift"
)

build_one_arch() {
    local arch="$1"
    local target="$2"
    local out_bin="$3"
    local module_cache="$4"

    mkdir -p "$module_cache"
    mkdir -p "$module_cache/clang"

    echo -e "${YELLOW}→ 编译架构: ${arch} (${target})${NC}"

    "$SWIFTC" -O \
        -sdk "$SDK_PATH" \
        -target "$target" \
        -module-cache-path "$module_cache" \
        -Xcc -fmodules-cache-path="$module_cache/clang" \
        -framework Cocoa \
        -framework Carbon \
        -framework ApplicationServices \
        "${SRC_FILES[@]}" \
        -o "$out_bin"
}

FINAL_BIN="$APP_BUNDLE/Contents/MacOS/ClipboardHistory"
build_one_arch "arm64" "$TARGET_ARM64" "$FINAL_BIN" "$BUILD_DIR/ModuleCache-arm64"

if [ $? -ne 0 ]; then
    echo -e "${RED}编译失败！${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 编译成功${NC}"

# 复制 Info.plist
echo -e "${YELLOW}复制配置文件...${NC}"
cp "$PROJECT_DIR/ClipboardHistory/Info.plist" "$APP_BUNDLE/Contents/"

# 创建图标（使用系统图标）
echo -e "${YELLOW}创建应用图标...${NC}"
# 创建一个简单的图标（可选：用户可以替换为自定义图标）
# 这里我们使用系统默认图标
# 用户可以自己添加 AppIcon.icns 文件到 Resources 目录

# 设置可执行权限
chmod +x "$APP_BUNDLE/Contents/MacOS/ClipboardHistory"

# 代码签名（可选，但建议）
echo -e "${YELLOW}代码签名...${NC}"
if command -v codesign &> /dev/null; then
    # 使用临时签名（适用于开发测试）
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
    echo -e "${GREEN}✓ 已完成临时签名${NC}"
else
    echo -e "${YELLOW}⚠ 未找到 codesign，跳过签名步骤${NC}"
fi

echo ""
echo -e "${GREEN}======================================"
echo "构建完成！"
echo "======================================"
echo ""
echo -e "应用位置: ${YELLOW}$APP_BUNDLE${NC}"
echo ""
echo "使用方法："
echo "1. 双击打开 '$APP_NAME.app'"
echo "2. 首次运行需要授予辅助功能权限："
echo "   系统设置 -> 隐私与安全性 -> 辅助功能 -> 添加应用"
echo "3. 使用快捷键 ⌘⌥V 唤起剪贴板历史"
echo ""
echo -e "${GREEN}提示：${NC}可以将应用拖动到「应用程序」文件夹中安装"
echo ""
