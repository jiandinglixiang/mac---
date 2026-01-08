#!/bin/bash

# 剪贴板历史工具打包脚本
# 创建可分发的 DMG 安装包

set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 项目配置
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="剪贴板历史"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="剪贴板历史-1.0.0.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
TEMP_DMG="$BUILD_DIR/temp.dmg"
VOLUME_NAME="剪贴板历史安装器"

echo "======================================"
echo "开始打包剪贴板历史工具"
echo "======================================"

# 检查应用是否已构建
if [ ! -d "$APP_BUNDLE" ]; then
    echo -e "${RED}错误: 找不到应用包，请先运行 build.sh${NC}"
    exit 1
fi

# 清理旧的 DMG
rm -f "$DMG_PATH" "$TEMP_DMG"

# 创建临时目录
TEMP_DIR="$BUILD_DIR/dmg_temp"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# 复制应用到临时目录
echo -e "${YELLOW}准备打包文件...${NC}"
cp -R "$APP_BUNDLE" "$TEMP_DIR/"

# 创建应用程序文件夹的符号链接
ln -s /Applications "$TEMP_DIR/应用程序"

# 创建 README 文件
cat > "$TEMP_DIR/安装说明.txt" << 'EOF'
剪贴板历史工具 - 安装说明
====================================

安装步骤：
1. 将「剪贴板历史.app」拖动到「应用程序」文件夹
2. 打开「应用程序」文件夹，找到「剪贴板历史」
3. 右键点击应用，选择「打开」（首次运行需要）
4. 授予辅助功能权限（重要！）

授予辅助功能权限：
1. 打开「系统设置」
2. 进入「隐私与安全性」
3. 点击「辅助功能」
4. 添加「剪贴板历史」应用并勾选

使用方法：
• 应用启动后会在状态栏显示图标
• 使用快捷键 ⌘⇧V 唤起剪贴板历史窗口
• 支持文本、图片、文件、链接等多种类型
• 可以搜索和过滤历史记录
• 选择项目后按回车或双击即可粘贴

快捷键：
• ⌘⇧V - 显示/隐藏历史窗口
• ↑↓ - 选择项目
• 回车 - 粘贴选中项
• ESC - 关闭窗口
• Delete - 删除选中项

技术支持：
如有问题，请检查：
1. 是否授予了辅助功能权限
2. macOS 版本是否为 11.0 或更高

====================================
版本: 1.0.0
仅支持 macOS 11.0+
EOF

# 计算所需大小
echo -e "${YELLOW}计算磁盘映像大小...${NC}"
SIZE=$(du -sm "$TEMP_DIR" | awk '{print $1}')
SIZE=$((SIZE + 20)) # 添加额外空间

# 创建 DMG
echo -e "${YELLOW}创建磁盘映像...${NC}"
hdiutil create -srcfolder "$TEMP_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${SIZE}m \
    "$TEMP_DMG"

# 挂载 DMG
echo -e "${YELLOW}配置磁盘映像...${NC}"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | egrep '^/dev/' | sed 1q | awk '{print $1}')
MOUNT_POINT="/Volumes/$VOLUME_NAME"

# 等待挂载完成
sleep 2

# 设置窗口属性（如果可能）
if [ -d "$MOUNT_POINT" ]; then
    echo '
    tell application "Finder"
        tell disk "'$VOLUME_NAME'"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {100, 100, 800, 500}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 72
            set position of item "'$APP_NAME'.app" of container window to {150, 200}
            set position of item "应用程序" of container window to {450, 200}
            set position of item "安装说明.txt" of container window to {300, 350}
            close
            open
            update without registering applications
            delay 2
        end tell
    end tell
    ' | osascript || true
fi

# 卸载
sync
hdiutil detach "$DEVICE"

# 转换为压缩的只读 DMG
echo -e "${YELLOW}压缩磁盘映像...${NC}"
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"

# 清理
rm -f "$TEMP_DMG"
rm -rf "$TEMP_DIR"

echo ""
echo -e "${GREEN}======================================"
echo "打包完成！"
echo "======================================"
echo ""
echo -e "安装包位置: ${YELLOW}$DMG_PATH${NC}"
echo -e "文件大小: ${YELLOW}$(du -h "$DMG_PATH" | awk '{print $1}')${NC}"
echo ""
echo "现在可以分发此 DMG 文件给其他用户安装使用！"
echo ""
