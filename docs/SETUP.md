# 构建与首次配对 · v0.2

两台电脑先接入同一局域网
构建后，在原生设置窗口里完成配对
不需要手写配置文件

Windows 负责生成一次性邀请
Mac 导入后，预览并确认设备
配对后，两端共享同一份同步设置

## 1. 构建应用

Mac 在仓库根目录运行：

```sh
sh scripts/macos/build.sh
```

产物在 `build/macos/CopyBridge.app`
脚本会执行不接触剪贴板的自检
构建目标由本机 Swift 和 SDK 决定
旧系统兼容性需要单独验证

这是本地 ad-hoc 签名构建
不是 Developer ID 公证版
不要关闭系统安全保护

Windows 安装 .NET 10 SDK 后
在仓库根目录运行：

```powershell
dotnet publish apps/windows/CopyBridge.Windows.csproj -c Release -r win-x64 --self-contained true -o build/windows
$p = Start-Process .\build\windows\CopyBridge.exe -ArgumentList '--self-test' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw 'Self-test failed' }
```

## 2. 打开两端的设置窗口

**Windows**

在已登录的 Windows 桌面中
双击 `build/windows/CopyBridge.exe`
首次使用会打开设置窗口

以后可以右键右下角的托盘图标
选择「打开设置」
图标可能收在托盘的隐藏图标区域

程序会选择可用的局域网地址
在「连接设备」页核对当前地址
如果显示 `127.0.0.1`，那是本机测试地址
另一台电脑不能用它连接

**Mac**

双击 `build/macos/CopyBridge.app`
未连接设备时，会打开设置窗口
以后从菜单栏选择「打开设置…」

两端都有三个页面：

| 页面 | 用途 |
| --- | --- |
| 连接设备 | 查看状态、生成或导入邀请、连接设备 |
| 同步设置 | 选择方向、内容类型和是否暂停 |
| 工作原理 | 了解复制、加密直传、核对与粘贴 |

关闭设置窗口后，后台同步继续
需要停止运行时，从菜单或托盘退出

## 3. 在 Windows 生成邀请

进入「连接设备」
点击「连接 Mac · 生成邀请」

可以选择：

- 「复制配对码」：交给自己的 Mac 输入
- 「保存配对文件…」：保存为 `.copybridge` 文件

首次配对时，两端尚未同步剪贴板
可以用 U 盘或本地文件共享等可信方式
把这份小文件交给自己的 Mac
这一步只在首次配对或换设备时做

邀请十分钟有效，成功使用一次即失效
过期后，在 Windows 重新生成
已有配对时，会先确认是否断开旧连接

配对码和文件包含一次性连接凭据
只交给准备连接的 Mac
不要公开分享，也不要提交到代码仓库

## 4. 在 Mac 导入并确认

进入「连接设备」
点击「选择配对文件…」，导入刚才的文件
也可以在受保护的输入框粘贴配对码
再点击「预览设备」

程序先检查配对资料
通过后，只预览设备名称、地址和有效期
确认是自己的 Windows
再点击「连接这台 Windows」

设备身份与加密连接由程序自动核对
配置和长期凭据也会自动保存
Mac 使用 Keychain，Windows 使用用户级保护
不需要手工拆分证书或填写设备编号

看到已连接后，复制一段新文字
等提示「可粘贴」，再去另一端粘贴
首次连接、重连和恢复都不会补发旧内容

如果配对失败，原有本机配置会保留
配对码过期就重新生成
时间提示异常时，先校对两台系统时间
设备身份验证失败时，重新核对邀请来源
不要绕过证书检查

从旧版升级时，请生成新邀请重新配对
v0.2 不会自动读取或迁移旧版钥匙串秘密
已收到的文件不会因此删除

## 5. 在任意一端设置同步范围

进入「同步设置」，选择需要的项目：

| 开关 | 控制什么 |
| --- | --- |
| Mac → Windows | 在 Mac 复制，送到 Windows |
| Windows → Mac | 在 Windows 复制，送到 Mac |
| 文字 | 文字、链接、代码 |
| 图片内容 | 截图或复制的图像像素 |
| 文件 | 单个本地文件，包括图片文件和视频 |
| 暂停 | 暂停两台设备之间的同步 |

Mac 点击「保存到两台设备」
Windows 点击「保存设置」
保存成功后，另一端会自动更新
暂停期间，也能从任意一端恢复

截图与图片文件是两种复制方式
关闭「图片内容」不会关闭 PNG 文件传输
从文件夹复制的 PNG、JPEG、视频等
都由「文件」开关控制

如果提示另一端已经修改了设置
先查看或载入最新设置，再保存
程序不会静默覆盖另一端的新选择

修改、恢复或重连之后
请重新复制需要同步的内容
单个文件上限仍为 2 GiB
暂不支持文件夹和多文件批次

较大的文件要等传完再粘贴
提前粘贴可能仍是上一次的内容
「工作原理」页也会说明这些行为

## 网络与独立测试目录

默认使用同一局域网直连
Windows 默认监听 TCP 43861
只在专用网络放行此程序
把远端范围限制为本地子网
不要开放到公网或关闭整机防火墙

多网卡或独立测试时，可以指定地址
下面只是示例，请换成实际局域网地址
普通首次配对不需要这一步

```powershell
.\build\windows\CopyBridge.exe --bind 192.168.1.100 --port 43861 --data "$env:LOCALAPPDATA\CopyBridge-Test"
```

证书与启动地址关联
更换地址时需重新核对并配对
不要修改证书来跳过身份检查

默认 Windows 数据目录：
`%LOCALAPPDATA%\CopyBridge`

Mac 默认配置目录：
`~/Library/Application Support/CopyBridge`

需要测试候选版时，可使用独立目录：

```sh
open -n build/macos/CopyBridge.app --args --data "$HOME/Library/Application Support/CopyBridge-Test"
```

`--data` 用来隔离配置、日志与测试数据
不要让两个实例同时使用同一目录
实际复制粘贴测试时，先暂停另一套实例

## 可选：登录后启动

先完成配对与新内容的复制粘贴检查
再配置登录启动

Mac 把应用复制到 `~/Applications/CopyBridge.app`
然后运行：

```sh
sh scripts/install-mac.sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.copybridge.mac.plist"
```

重复安装前检查已有登录项
避免同时运行多个实例

Windows 可为当前用户建立登录任务
选择「仅当用户登录时运行」
使用应用的完整路径
有自定义启动参数时，也要保持一致

## 停用与文件保留

两端菜单可以暂停或退出
不会改变本机原来的复制粘贴

收到的文件保存在用户目录的
`CopyBridge Received`
独立测试目录下的位置可能不同
可从应用菜单打开收到的文件

退出或解除配对不会自动删除这些文件
清理前，请确认其他文档没有引用它们

Mac 可用 `scripts/uninstall-mac.sh` 停用登录项
它不会删除应用、凭据和收到的文件
Windows 停用自己创建的登录任务即可

本页说明 v0.2 的操作流程
实际通过范围与未完成项
以 [验证记录](VERIFICATION.md) 为准

再次打开 Windows 程序会显示已有实例的设置窗口，不会重复运行同步程序
快捷方式可带 `--settings`，首次启动也直接打开设置；登录启动可不带此参数
