# 构建与连接 · Mac 0.3.2 / Windows 0.4.2

## 普通用户

完整解压 Windows 包，双击 CopyBridge.exe
Mac 将 CopyBridge.app 放到应用程序文件夹后打开
两台电脑接入同一个可信网络

1. Windows 进入「连接 Mac」，点击「复制连接信息」
2. 把这一行短信息带到自己的 Mac 并复制
3. Mac 点击「连接设备」→「粘贴连接信息」→「连接」

Mac 也可以手动填写 Windows 地址和短连接口令
默认端口由程序填写，不需要用户了解
短信息十分钟有效、只使用一次
连接好后会保存配对，重启后在两端双击桌面图标即可尝试恢复连接
恢复后请重新复制一次，旧内容不会补发

Mac 支持 Command+V，也提供直接读取剪贴板的按钮
旧长码或配对文件位于「旧版配对码或文件」，仅用于兼容旧版

Windows「使用指南」可添加桌面快捷方式
Mac 可在访达为应用制作替身并放到桌面
关闭窗口后仍运行；从菜单或托盘选择退出才停止

## 构建

Mac：

```sh
sh scripts/macos/build.sh
```

输出：`build/macos/CopyBridge.app`
图标原图或尺寸变化时先运行 `sh scripts/build-icons.sh`

Windows 安装 .NET 10 SDK 后：

```powershell
dotnet publish apps/windows/CopyBridge.Windows.csproj -c Release -r win-x64 --self-contained true -o build/windows
$p = Start-Process .\build\windows\CopyBridge.exe -ArgumentList '--self-test' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw 'Self-test failed' }
```

自检请在发布目录以外执行；测试输出不要放进分享包
图标资源相对于仓库根目录引用，需保留 assets/icon

## 配置与网络

默认 Windows 数据：`%LOCALAPPDATA%\CopyBridge`
默认 Mac 数据：`~/Library/Application Support/CopyBridge`
Windows 默认为 TCP 43861，仅在可信专用网络允许通信
不要将此端口开放到公网，不要关闭整机防火墙

可用 `--data` 指定独立目录；Windows 支持 `--bind` 与 `--port`
`--background` 用于安静登录启动，桌面入口使用 `--settings`（Windows）或正常打开应用（Mac）

网络地址变化时，仍受原证书和保存地址约束；本次没有重做自动发现
协议与安全边界见 [短连接信息](QUICK_PAIRING.md)
分享步骤见 [试用包与分享流程](DISTRIBUTION.md)
通过范围见 [验证记录](VERIFICATION.md)
