# SnapInsert Mac

在 Mac 上接收 iPhone 拍摄的照片，并插入当前编辑位置。原生 SwiftUI，支持 macOS 14 及以上。

## 下载

[下载 Mac 安装包（DMG · Apple Silicon）](https://github.com/DanielPro0706/SnapInsert-Mac/releases/latest/download/SnapInsert-Mac-AppleSilicon.dmg) · [ZIP 备用下载](https://github.com/DanielPro0706/SnapInsert-Mac/releases/latest/download/SnapInsert-Mac-AppleSilicon.zip) · [发布记录](https://github.com/DanielPro0706/SnapInsert-Mac/releases)

将 DMG 中的 `SnapInsert.app` 拖入“应用程序”。正式发布包使用 Developer ID 签名，通过 Apple 公证并附带公证票据。安装包适用于 Apple Silicon（M 系列）Mac。

## iPhone

[通过 TestFlight 安装 SnapInsert](https://testflight.apple.com/join/c53sNGZt)

Mac `1.0.4` 支持配套 iPhone 客户端。iPhone `1.0.2` 提供完整的传输排队、下一张箭头与首次使用提示。

## 使用

1. 打开 Mac 上的 SnapInsert，从菜单栏相机图标进入接收器。
2. 在“邀请码授权”中填写维护者发放的测试群组邀请码，激活此 Mac 的配对。
3. 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 SnapInsert，以便自动粘贴。
4. 用 iPhone 扫描 Mac 接收器中的配对二维码。
5. 在支持图片粘贴的应用中放好光标，再在 iPhone 拍照并插入。

关闭 Mac 主窗口后，接收器继续运行。菜单栏图标遵循用户设置，首次默认显示。可通过 Finder 再次打开应用来恢复主窗口。

## 配对与隐私

两端通过互联网中转连接，支持不同 Wi-Fi 和蜂窝网络。默认中转地址为 `https://danieldev.top`。连接需要有效的群组邀请授权。每个邀请码对应一个测试群组，维护者设置该群组允许的同时传输人数。空闲配对不占传输名额，达到并发或可用带宽预算时任务排队，照片保留在 iPhone 上等待。传输完成或取消后释放名额。邀请码长期有效，可由维护者撤销。累计传输量用于使用统计。

照片和回执使用 AES-256-GCM 端到端加密。服务保存邀请码摘要、已授权房间标识、同时传输人数上限、累计用量和活动时间，以管理群组授权与撤销。网络中转可见连接 IP、时间、数据大小及路由信息。

配对密钥保存在系统 Keychain。二维码包含密钥，请只向自己的设备展示。Mac 可重置配对。每次发送使用一次性加密挑战，处理照片前校验。照片保留在运行内存和 Mac 剪贴板中，系统或第三方剪贴板工具可能保留历史。

自动插入依赖辅助功能权限、稳定的输入焦点及目标应用对图片粘贴的支持。“已发送粘贴指令”表示已投递快捷键，接收器无法确认目标应用是否接受图片。

完整的数据处理与保留说明见 [隐私政策](docs/PRIVACY.md)。

## 构建

使用 Xcode 打开 `SnapInsert.xcodeproj`，选择 `SnapInsertMac` scheme。自行签名时，在 Signing & Capabilities 中选择自己的开发团队。

```sh
swift test
xcodebuild -project SnapInsert.xcodeproj -scheme SnapInsertMac \
  -configuration Release -derivedDataPath /tmp/SnapInsert-Mac \
  CODE_SIGNING_ALLOWED=NO build
```

`Shared/` 包含 Mac 所需的配对、加密和传输协议，`macOS/` 包含接收器与自动粘贴实现。共享协议测试位于 `Tests/SnapInsertCoreTests/`。

已公证的 Mac App 可用以下脚本打包为 DMG、ZIP 和 SHA-256 校验文件。

```sh
./Scripts/package-mac.sh /path/to/SnapInsert.app /path/to/release-directory
```

## 许可

MIT，见 [LICENSE](LICENSE)。
