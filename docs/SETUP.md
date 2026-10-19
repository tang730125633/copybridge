# 构建与首次配对

这是单用户、两台可信设备之间的参考实现
首次配对需要你核对设备身份，当前没有扫码安装向导

## 1. 构建

Mac 在仓库根目录运行 `sh scripts/macos/build.sh`
产物在 `build/macos/CopyBridge.app`，脚本会执行不接触剪贴板的自检
构建目标由本机 Swift/SDK 决定，旧系统兼容性需单独验证
这是本地 ad-hoc 签名，不是 Developer ID 公证版；不要关闭系统安全保护

Windows 安装 .NET 10 SDK 后，在仓库根目录运行：

```powershell
dotnet publish apps/windows/CopyBridge.Windows.csproj -c Release -r win-x64 --self-contained true -o build/windows
$p = Start-Process .\build\windows\CopyBridge.exe -ArgumentList '--self-test' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw 'Self-test failed' }
```

## 2. Windows 端

在 Windows 当前登录的桌面会话启动，不要把 GUI 程序放进 SSH 的服务会话
以下地址只是示例，请替换为 Windows 的实际局域网地址：

```powershell
$bind = '192.168.1.100' # replace with your Windows LAN address
.\build\windows\CopyBridge.exe --bind $bind --port 43861
```

默认数据目录为 `%LOCALAPPDATA%\CopyBridge`
也可用 `--data` 指定独立目录；同一实例始终使用同一目录

只在 Windows 专用网络中放行此程序的 TCP 43861，限制远端为本地子网
不要开放到公网，不要关闭整个防火墙

首次启动生成 `certificate.pem`、`fingerprint.json` 与 `pairing.json`
配对资料十分钟有效，成功配对后会失效；不可公开、不可提交到仓库
证书绑定启动时的 IP，地址变化后需重新核对并配对
不要在已有实例运行时对同一目录重复执行 `--bootstrap`

## 3. 把配对资料交给 Mac

通过你已核验的 SSH 主机身份、受控本地介质或其他可信路径传递：

- `certificate.pem`：设备公开证书
- `fingerprint.json`：用于核对证书 SHA-256
- `pairing.json`：短期秘密，只交给准备配对的 Mac

不要从未经验证的网络连接获取后直接信任证书
不要分享旧的长期凭据；Mac 保存在 Keychain，Windows 使用当前用户 DPAPI

在 Mac 创建 `~/Library/Application Support/CopyBridge`，目录权限设为700
把证书保存为该目录下的 `device.pem`
把短期配对文件保存为该目录下的 `pairing.json`，文件权限设为600

## 4. Mac 配置

在同一目录写入 `config.json`，权限设为600：

```json
{
  "url": "https://192.168.1.100:43861",
  "deviceId": "REPLACE_WITH_A_NEW_UUID",
  "certificateSha256": "REPLACE_WITH_VERIFIED_LOWERCASE_CERTIFICATE_SHA256",
  "keychainAccount": "copybridge-my-pair"
}
```

地址替换成上一步选定的 Windows 地址，不带末尾斜线
`deviceId` 在 Mac 上用 `uuidgen` 生成新值，不要填 Windows 的设备 ID
`certificateSha256` 填已核对的 `fingerprint.json` 中对应字段

启动：

```sh
open build/macos/CopyBridge.app --args --pair-token-file "$HOME/Library/Application Support/CopyBridge/pairing.json"
```

成功后配对文件被删除，长期凭据写入 Keychain
以后正常打开应用即可；复制一段新文字，等待“可粘贴”后验收

## 5. 可选：Mac 登录启动

先把应用复制到 `~/Applications/CopyBridge.app`，再运行：

```sh
sh scripts/install-mac.sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/local.copybridge.mac.plist"
```

重复安装前检查已有登录项，避免重复启动
Windows 可在任务计划程序中为当前用户创建登录任务，选择“仅当用户登录时运行”，使用完整程序路径和相同的 `--bind` / `--data` 参数

## 停用与数据

两端菜单可以暂停或退出，不影响本机原来的复制粘贴
Mac 可用 `scripts/uninstall-mac.sh` 停用登录项，它不会删除应用、凭据和收到的文件
Windows 停用自己创建的登录任务即可
清理收到的文件前，确认其他文档没有引用它们
