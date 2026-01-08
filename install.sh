#!/bin/bash

# 剪贴板历史工具 - 快速安装脚本

set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

clear

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════╗"
echo "║     剪贴板历史工具 - 快速安装脚本       ║"
echo "║           版本: 1.0.0                     ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# 检查构建产物
if [ ! -f "build/剪贴板历史-1.0.0.dmg" ]; then
    echo -e "${RED}错误: 找不到安装包 build/剪贴板历史-1.0.0.dmg${NC}"
    echo -e "${YELLOW}请先运行 ./build.sh 和 ./package.sh 构建项目${NC}"
    exit 1
fi

if [ ! -d "build/剪贴板历史.app" ]; then
    echo -e "${RED}错误: 找不到应用 build/剪贴板历史.app${NC}"
    echo -e "${YELLOW}请先运行 ./build.sh 构建项目${NC}"
    exit 1
fi

echo -e "${GREEN}✓ 发现构建产物${NC}"
echo ""

# 显示选项
echo "请选择安装方式："
echo ""
echo "  ${YELLOW}1${NC}) 打开 DMG 安装包（推荐）"
echo "  ${YELLOW}2${NC}) 直接复制到应用程序文件夹"
echo "  ${YELLOW}3${NC}) 仅运行应用（不安装）"
echo "  ${YELLOW}4${NC}) 显示安装说明"
echo "  ${YELLOW}5${NC}) 退出"
echo ""
read -p "请输入选项 (1-5): " choice

case $choice in
    1)
        echo ""
        echo -e "${YELLOW}正在打开 DMG 安装包...${NC}"
        open "build/剪贴板历史-1.0.0.dmg"
        echo ""
        echo -e "${GREEN}请按照以下步骤操作：${NC}"
        echo "  1. 将「剪贴板历史.app」拖动到「应用程序」文件夹"
        echo "  2. 等待复制完成"
        echo "  3. 打开「应用程序」文件夹"
        echo "  4. 右键点击「剪贴板历史」，选择「打开」"
        echo "  5. 授予辅助功能权限"
        echo ""
        echo -e "${BLUE}提示: 查看「README.md」了解如何授予权限${NC}"
        ;;
    2)
        echo ""
        echo -e "${YELLOW}正在复制应用到「应用程序」文件夹...${NC}"
        if [ -d "/Applications/剪贴板历史.app" ]; then
            echo -e "${YELLOW}警告: 应用程序文件夹中已存在旧版本${NC}"
            read -p "是否覆盖? (y/n): " confirm
            if [ "$confirm" != "y" ]; then
                echo "已取消"
                exit 0
            fi
            rm -rf "/Applications/剪贴板历史.app"
        fi
        
        cp -R "build/剪贴板历史.app" "/Applications/"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ 安装成功！${NC}"
            echo ""
            echo -e "${YELLOW}下一步：${NC}"
            echo "  1. 打开「应用程序」文件夹"
            echo "  2. 右键点击「剪贴板历史」，选择「打开」"
            echo "  3. 授予辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）"
            echo ""
            read -p "是否现在打开应用? (y/n): " run_app
            if [ "$run_app" = "y" ]; then
                open "/Applications/剪贴板历史.app"
                echo -e "${GREEN}✓ 应用已启动${NC}"
            fi
        else
            echo -e "${RED}✗ 安装失败${NC}"
            exit 1
        fi
        ;;
    3)
        echo ""
        echo -e "${YELLOW}正在启动应用...${NC}"
        open "build/剪贴板历史.app"
        echo -e "${GREEN}✓ 应用已启动${NC}"
        echo ""
        echo -e "${YELLOW}注意: 应用未安装到系统，仅作为测试运行${NC}"
        echo -e "${BLUE}提示: 应用会出现在状态栏，按 ⌘⌥V 测试功能${NC}"
        ;;
    4)
        echo ""
        echo -e "${BLUE}════════════════ 安装说明 ════════════════${NC}"
        echo ""
        echo -e "${YELLOW}步骤 1: 安装应用${NC}"
        echo "  方式A: 双击 DMG 文件，拖动到「应用程序」文件夹"
        echo "  方式B: 运行此脚本选择选项 2"
        echo ""
        echo -e "${YELLOW}步骤 2: 首次运行${NC}"
        echo "  右键点击应用，选择「打开」"
        echo "  （macOS 安全限制，首次需要右键打开）"
        echo ""
        echo -e "${YELLOW}步骤 3: 授予辅助功能权限（必需）${NC}"
        echo "  1. 打开「系统设置」"
        echo "  2. 进入「隐私与安全性」"
        echo "  3. 点击「辅助功能」"
        echo "  4. 点击 🔒 解锁（输入密码）"
        echo "  5. 点击「+」添加「剪贴板历史」"
        echo "  6. 勾选应用 ✅"
        echo ""
        echo -e "${YELLOW}步骤 4: 开始使用${NC}"
        echo "  • 应用会在状态栏显示图标"
        echo "  • 按 ⌘⌥V 打开剪贴板历史"
        echo "  • 复制任何内容会自动记录"
        echo ""
        echo -e "${BLUE}详细说明请查看「README.md」${NC}"
        echo ""
        ;;
    5)
        echo "已退出"
        exit 0
        ;;
    *)
        echo -e "${RED}无效选项${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo -e "${GREEN}感谢使用剪贴板历史工具！${NC}"
echo -e "${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo "📚 查看文档："
echo "  • 项目说明: cat README.md"
echo ""
echo "🔧 重新构建："
echo "  • 构建应用: ./build.sh"
echo "  • 打包 DMG: ./package.sh"
echo ""
