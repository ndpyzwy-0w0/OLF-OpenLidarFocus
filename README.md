# 跟焦器（iphone-follow-focus）

苹果手机自动对焦跟焦器。Swift 功能层 + Flutter UI。
Dart 包名 `iphone_follow_focus`，iOS bundle id `com.ndpyz.iphoneFollowFocus`。

## 结构

```text
ios/FollowFocusCore/   功能层（本地 Swift Package，只依赖 Foundation）
                       协议、UDP 链路、设备发现、镜头/对齐、会话编排
ios/Runner/            iOS 壳：LiDAR 采集 + `ff.core` 通道（把功能层接到 UI）
lib/                   Flutter UI，只通过 `ff.core` 读写功能层
firmware/              ESP32-S3 固件
```

功能层**不能** import Flutter/UIKit，由编译器强制；UI 里不写控制逻辑。
契约与边界见 [HANDOFF.md](HANDOFF.md) §12/§13。

## 本机运行

本仓库只在 macOS 上开发。

```bash
flutter pub get
flutter run -d <device>            # 模拟器没有 LiDAR，距离显示 --，其余可测
```

真机 iOS 需要 Xcode 签名后部署，见 HANDOFF.md §8.1。

**只改 UI、不接硬件**时不需要 Xcode 和 iPhone，用 web 预览：

```bash
tool/ui_preview.sh                 # 构建 + 起本地服务 + 打开浏览器
```

细节、边界和注意事项见 [UI_DEV.md](UI_DEV.md)。

## 测试

```bash
cd ios/FollowFocusCore && swift test    # 功能层逻辑测试，约 6 秒，不需要模拟器
flutter test                            # UI 测试，用伪造核心驱动，不碰平台通道
```

`swift test` 在 macOS 原生跑，比 `xcodebuild test` 快几十倍；链路和会话测试在
loopback 上起一个假板子走**真实** UDP，不需要接硬件。

## 文档

| 文档 | 内容 |
| --- | --- |
| [HANDOFF.md](HANDOFF.md) | 交付入口：硬件接线、现状、看门狗/锁存语义、测试与验收、下一步 |
| [UI_DEV.md](UI_DEV.md) | **UI 开发入口**：UI/功能层边界、web 本地预览（`tool/ui_preview.sh`）、UI 测试写法 |
| [PROTOCOL.md](PROTOCOL.md) | **固件 ↔ 上位机的 wire 契约（唯一权威来源）**：包布局、命令表、flags 位、回包数量、hex 样例、上位机检查清单 |
| [CONTROL_ARCHITECTURE.md](CONTROL_ARCHITECTURE.md) | 控制架构与运动规划设计 |

固件目录 `firmware/`，验收脚本 `test/udp_motion_acceptance.py`，截断复现工具
`test/repro_jog_truncation.py`，调试工具 `firmware/tools/{discover.py,jog.py}`。
文件归属与多 agent 协同边界见 HANDOFF.md §12。
