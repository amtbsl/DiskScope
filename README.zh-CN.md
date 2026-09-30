# DiskScope

[English](README.md) · [简体中文](README.zh-CN.md) · [MIT 许可证](LICENSE)

DiskScope 是一款在本机运行的 macOS 磁盘分析与清理应用。通过分层矩形树图查看空间占用，查找大文件和开发缓存，检查应用关联文件，并查看实时系统状态。

使用 Swift、AppKit 和本地 WebKit 界面实现。所有已实现功能直接可用，无需账户或付费许可证。应用没有分析遥测、云端后台或网络服务，扫描和清理均在你的 Mac 上执行。

## 功能介绍

| 类别 | 功能 |
| --- | --- |
| 磁盘扫描 | 扫描主目录、启动卷或指定文件夹；外置卷单独选择扫描 |
| 交互树图 | 单击选择、双击进入目录、面包屑导航、右键操作菜单 |
| 文件浏览 | 在树图、分页列表和大文件视图间切换 |
| 文件搜索 | 搜索当前扫描结果，或通过 Spotlight 搜索主目录和全盘 |
| 开发缓存筛选 | Node.js、Xcode、构建产物、Android、Docker、虚拟机、缓存、AI 模型等 |
| 清理队列 | 检查所选路径，经原生确认后移入 Finder 废纸篓 |
| 应用清理 | 检查已安装应用，选择关联文件，查看卸载残留候选 |
| 系统监控 | CPU、内存、压缩内存、Swap、物理网卡流量、电池和高 CPU 进程，每两秒刷新 |
| 界面外观 | 六种本地主题、统一文件类型配色、可拖动的原生窗口顶部区域 |
| 导出报告 | 导出扫描元数据为 CSV |
| 快捷键 | ⌘F 搜索，⌘Q 退出 |

## 构建与运行

可直接从 [GitHub Releases](https://github.com/amtbsl/DiskScope/releases/latest) 下载 Apple Silicon macOS 版本。打开 DMG 后，将 DiskScope 拖入 Applications；也可以解压 ZIP 使用。发布包采用临时签名，未经过 Apple 公证，首次打开的说明见发布页面。

环境要求：

- macOS 13 或更新版本。
- Xcode Command Line Tools；尚未安装时运行 `xcode-select --install`。
- 运行应用不需要 Electron、Node.js 或 Python。测试需要 Python 3 和 Node.js。

```sh
git clone https://github.com/amtbsl/DiskScope.git
cd DiskScope
zsh scripts/build.sh
open build/DiskScope.app
```

构建面向当前 Mac 的处理器架构。开发和手动验收在 Apple Silicon Mac 上完成，尚未验证 Intel 构建。脚本从源码生成应用图标，并使用本地 ad hoc 签名；构建产物未经 Apple 开发者公证。

安装或更新本地构建的应用时，先退出 DiskScope，再执行：

```sh
zsh scripts/install.sh
open /Applications/DiskScope.app
```

安装脚本将上一版 DiskScope 保留在 `build/` 中，并拒绝替换名称相同但标识不同的应用。

## 使用方法

1. 从 **Scan Home** 或 **Choose Folder** 开始。扫描外置盘时，单独选择对应卷。
2. 单击树图条目查看详情，双击文件夹进入；也可切换到 **List** 或 **Large Files**。
3. 使用搜索和筛选缩小范围。**Current Scan** 查询扫描数据库，**Home / Full Mac** 查询系统 Spotlight 索引。
4. 通过 **Reveal**、**Open**、**Copy Path** 或 **Add to Queue** 检查和整理条目，清理前核对原生确认框中的路径。
5. 在 **Apps** 中检查应用及关联文件。残留候选默认不勾选。
6. 拖动顶部工具栏的空白区域移动窗口。搜索框文字仍可选择，普通界面标签不会因拖动而被框选。

## 权限与统计边界

- 普通文件夹可直接扫描。Mail、部分容器、废纸篓等受保护位置可能需要在 **系统设置 → 隐私与安全 → 完全磁盘访问权限** 中启用已安装的 DiskScope，再退出重开。应用不会自行授予权限。
- 无法访问的路径会计数并显示。跳过某个目录不代表其中没有数据。
- 按已分配块 `st_blocks × 512` 计算文件占用，同时保留逻辑大小。硬链接按 inode 去重，符号链接不跟随。APFS 克隆共享块、快照和可清除空间无法精确逐文件归属，扫描合计可能与磁盘存储条不同。
- 启动卷扫描跳过 `/System/Volumes` 重复挂载、设备节点和外置卷。外置盘需单独扫描。
- 单个后台扫描线程最多保留 200 万条记录，目录深度上限为 256。达到限制会显示 **Partial scan**，可缩小扫描范围继续检查。
- 树图只传递有限层次的内容，省略的小条目归入 **Other**。文件列表每页 400 条，搜索最多返回 500 条。
- Spotlight 搜索依赖系统索引，其目录大小不代表递归内容大小。
- 应用关联文件和残留判断采用启发式规则。共享应用组和残留候选不自动勾选；请先检查路径。自定义目录和部分辅助工具可能无法识别。
- 常规清理通过 Finder 可恢复的废纸篓执行，不使用 `sudo`。系统保护路径、顶层个人文件夹、运行中的应用和 DiskScope 自身不能加入删除队列。**Empty Trash** 在输入 `EMPTY` 确认后，仅永久清空当前用户的 `~/.Trash`。
- 内存为 Mach VM 估计，使用 GiB/MiB。进程 CPU 来自 macOS `ps`，多核进程可能超过 100%。网络统计使用物理 `en*` 接口，不重复累计 VPN 隧道。

## 源码结构

| 路径 | 内容 |
| --- | --- |
| `Sources/Core.swift` | POSIX 扫描、文件类型、筛选、队列去重和保护路径 |
| `Sources/Services.swift` | 存储与系统指标、应用发现、关联文件和残留候选 |
| `Sources/main.swift` | 原生窗口与拖动处理、WebKit 桥接、文件对话框和清理确认 |
| `web/` | 本地 HTML/CSS/JavaScript 界面与 squarified 树图布局 |
| `scripts/` | 构建、安装、原创图标生成和测试入口 |
| `tests/` | 扫描与树图回归测试 |
| `docs/VALIDATION.md` | 开发验收记录 |

## 测试与验收

安装 Python 3 和 Node.js 后执行：

```sh
zsh scripts/test.sh
```

脚本构建应用，执行扫描与树图回归测试、JavaScript 语法检查、真实系统状态采集，以及专用 UUID 文件的废纸篓移入与恢复测试。不会删除已有个人文件。手动检查和未验证情况见 [验收记录](docs/VALIDATION.md)。

运行 `zsh scripts/release.sh` 可为当前 Mac 的架构打包发布版本，在 `build/releases/` 下生成 DMG、ZIP 和 SHA-256 校验文件。

## 项目来源

DiskScope 参照 [DissectMac](https://dissectmac.com/) 可观察的界面和公开介绍的功能独立实现。项目不包含其源码或素材，未修改原应用或其许可证检查。DiskScope 与 DissectMac 没有关联或背书关系。MIT 许可证仅适用于本仓库代码和素材，不适用于所引用的第三方产品。

## 开源协议

Copyright © 2026 amtbsl。项目采用 [MIT 许可证](LICENSE)。
