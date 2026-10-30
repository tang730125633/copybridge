# CopyBridge · 两台电脑，一次复制

**在 Mac 复制，到 Windows 直接粘贴**

文字可以这样用<br>
文件也可以这样用<br>
反过来，同样支持

![泽龙与橘猫：让两台电脑之间的复制粘贴连起来](docs/art/copybridge-desk.webp)

[构建与配对](docs/SETUP.md) · [实机验证与边界](docs/VERIFICATION.md) · [实现原理](docs/ARCHITECTURE.md)

Windows v0.4.2 / Mac v0.3.2 提供统一图标、桌面入口和短口令连接
给第一次使用的人，见 [试用包与分享流程](docs/DISTRIBUTION.md)

## 为什么做这个

我想要的操作很简单

在 Mac 按下 Command+C<br>
走到 Windows，按下 Ctrl+V<br>
文字还是那段文字，文件还是原来的文件

CopyBridge 把这件事接起来
两台电脑通过局域网直接通信
不用把文件先发到聊天软件，也不经过中转服务器

## 怎么用

两台电脑先打开 CopyBridge，并连接同一可信网络

1. Windows 点击「连接 Mac」里的「复制连接信息」
2. 把这一行短信息带到自己的 Mac 并复制
3. Mac 点击「连接设备」→「粘贴连接信息」→「连接」
4. 看到已连接后，复制一段新文字，到另一台粘贴

只需要 Windows 地址和 20 字符的短连接口令
两项可自动填入，也可手动填写，不需要整段长码或配对文件
原来的长码与文件仅用于兼容旧版

连接信息十分钟有效，成功使用一次即失效
重启后双击两端桌面图标，程序沿用原配对尝试连接

Mac 用 **Command+C / Command+V**<br>
Windows 用 **Ctrl+C / Ctrl+V**

大文件需要先传完，再粘贴<br>
程序不会拦截快捷键，也不会替你补按粘贴

![复制、直传、核对、粘贴的工作流程](docs/art/copybridge-flow.svg)

## 设置窗口里有什么

| 页面 | 可以做什么 |
| --- | --- |
| 首页 | 查看当前连接、三步引导、暂停或恢复、打开收到的文件 |
| 连接设备 | 查看设备与状态，生成或导入配对邀请 |
| 同步设置 | 选择两个同步方向、文字、图片内容、文件和暂停 |
| 使用帮助 | 了解复制、加密直传、核对与可粘贴的过程 |

两端均可双击桌面图标进入，也可从 Mac 菜单栏或 Windows 托盘打开<br>
关闭设置窗口后，后台同步继续运行

修改设置、恢复或重新连接后<br>
请重新复制需要同步的内容<br>
程序不会补发之前的旧剪贴板

## 现在支持什么

当前是 **一台 Mac 与一台 Windows 一对一连接**
两端都要安装并打开 CopyBridge，网络互通，并完成配对
可以一台连 Wi-Fi、另一台插同一路由器的网线
访客网络或设备隔离可能阻止连接，即使 Wi-Fi 名称相同也不一定能用
目前不支持手机、同系统互连、多台同时同步或直接跨不同外网连接

| 内容 | 当前范围 |
| --- | --- |
| 纯文字 | 双向，中文、英文、表情、多行，最多 1 MiB |
| 静态图片内容 | 双向，最多 32 MiB、3200 万像素 |
| 单个本地文件 | 双向，不限扩展名，最多 2 GiB，保留原始字节 |
| 新复制优先 | 新内容撤销旧传输，目标电脑新复制的内容受到保护 |
| 菜单与托盘 | 打开设置、状态、暂停、收到的文件、断开设备、退出 |
| 两端共享设置 | 任意一端保存方向、类型或暂停，另一端自动更新 |

文件夹、多文件批次、未下载的云端文件、符号链接和富文本排版暂不支持
视频按真实文件传输，目标软件是否接受视频粘贴，取决于软件自身

## 真机上做到了哪里

在作者的一台 Apple Silicon Mac 和一台 Windows 11 上：

- 文字、普通文件、PNG、JPEG 和小 MP4，双向 12 项核对通过
- Mac 原生 Command+C，到 Windows 记事本和文件夹里的 Ctrl+V，通过并核对内容
- 一个完整的 2 GiB 文件传到 Windows，大小和 SHA-256 一致
- AutoCAD 2026 接收图片内容，保存图纸、关闭后重开仍正常
- 应用重启后自动重连，等待新复制，不重放旧剪贴板

这里的结果来自这两台设备<br>
不是对所有电脑、所有网络、所有软件的保证<br>
更完整的版本和测试边界见 [验证记录](docs/VERIFICATION.md)

v0.2 已核对 Mac 窗口导入配对<br>
共享暂停、方向和类型开关的实际拦截<br>
以及基本图文、文件的双向回归

新版已在两台作者设备安装，安装后六项双向内容核对通过<br>
Windows 原生窗口的逐项点击仍待本机验收<br>
这些状态会继续记入验证记录

## 从源码开始

这是供自行构建的源码版本
构建后，在两端设置窗口完成配对
首次连接不需要手写配置文件
当前没有通用的一键安装包

Mac 需要 Apple Silicon 与 Swift 命令行工具（实测 macOS 26.0.1）
Windows 需要 Windows 桌面环境与 .NET 10 SDK

```sh
git clone https://github.com/tang730125633/copybridge.git
cd copybridge
sh scripts/macos/build.sh
```

Windows 在项目根目录运行：

```powershell
dotnet publish apps/windows/CopyBridge.Windows.csproj -c Release -r win-x64 --self-contained true -o build/windows
Start-Process .\build\windows\CopyBridge.exe -ArgumentList '--self-test' -Wait
```

接下来按 [构建与配对](docs/SETUP.md) 打开两端应用
使用你自己的 Windows 生成配对邀请
不要套用别人的设备资料

## 放在哪里，什么时候停

收到的文件保存在两端用户目录的 `CopyBridge Received`
退出应用不会自动删除它们，避免文档中的文件引用失效

锁屏、睡眠或断网时停止当前任务<br>
恢复后重新复制一次<br>
如果同时开着其他剪贴板同步软件，请先停用其中一套

## 项目里的几块代码

| 位置 | 负责什么 |
| --- | --- |
| `apps/macos/CopyBridge.swift` | Mac 原生设置、菜单栏、剪贴板与传输 |
| `apps/windows/Program.cs` | Windows 托盘、HTTPS 接口与配对 |
| `apps/windows/SettingsWindow.cs` | Windows 原生设置与邀请操作 |
| `apps/windows/Bridge.cs` | 任务状态、新旧内容判定、接收与反向发送 |
| `apps/windows/NativeClipboard.cs` | Windows 原生文字、图片与文件格式 |
| `tests/protocol/check_server.py` | 连接真实接收端的协议检查工具 |

Swift / AppKit / CryptoKit · C# / .NET 10 / WPF / Kestrel

公开版本保留客户端代码与协议检查工具
不包含个人电脑地址、凭据、剪贴板内容、原始测试素材或部署历史

插画是工作原理的视觉表达，不是产品截图<br>
人物沿用我的个人网站，生成方式见 [插画说明](docs/ARTWORK.md)

唐泽龙 · [zelong.vip](https://zelong.vip)
