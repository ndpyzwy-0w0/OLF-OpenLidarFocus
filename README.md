# 跟焦器（iphone-follow-focus）

苹果手机自动对焦跟焦器。Flutter 工程，包名 `com.ndpyz.iphone_follow_focus`。

## 本机运行

先加载工程根目录环境，再进入本目录：

```powershell
. "J:\New soft project\commands\env.ps1"
cd "J:\New soft project\iphone-follow-focus"
flutter pub get
flutter run -d chrome
```

Windows 桌面：`flutter run -d windows`

真机 iOS 需要 macOS + Xcode，当前 Windows 环境不能打包 iPhone 安装包。

## 文档

| 文档 | 内容 |
| --- | --- |
| [HANDOFF.md](HANDOFF.md) | 交付入口：硬件接线、现状、看门狗/锁存语义、测试与验收、下一步 |
| [PROTOCOL.md](PROTOCOL.md) | **固件 ↔ 上位机的 wire 契约（唯一权威来源）**：包布局、命令表、flags 位、回包数量、hex 样例、上位机检查清单 |
| [CONTROL_ARCHITECTURE.md](<J:/New%20soft%20project/iphone-follow-focus/CONTROL_ARCHITECTURE.md>) | 控制架构与运动规划设计 |

固件目录 `firmware/`，验收脚本 `test/udp_motion_acceptance.py`，调试工具
`firmware/tools/{discover.py,jog.py}`。文件归属与多 agent 协同边界见 HANDOFF.md §12。
