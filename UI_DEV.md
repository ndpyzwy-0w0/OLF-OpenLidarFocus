# UI 开发与本地预览

给负责 UI 的人（和他的 AI）看的：怎么在不接硬件、不用 Xcode 的情况下改界面并预览。
架构背景和 `ff.core` 契约见 [HANDOFF.md](HANDOFF.md) §12/§13。

## 先记住这条边界

```text
ios/FollowFocusCore/   功能层（Swift）：协议、链路、镜头、对齐、会话编排
ios/Runner/            iOS 壳：把功能层接到 `ff.core` 通道，LiDAR 采集
lib/                   UI 层（Flutter）：只渲染 + 发命令
```

**UI 里不写控制逻辑。** 具体说，`lib/` 里不允许出现 `_limitsFor`、`_autoSteps`、
`_phaseFor` 这类函数 —— 出现就是第二份实现，和 Swift 那份迟早不一致。

需要新行为时的顺序，别颠倒：

1. 在 `FollowFocusSession` 里实现（带 `swift test`）
2. 在 `FollowFocusCorePlugin.swift` 加一个方法（纯搬运，解析参数）
3. 在 `lib/ff_core.dart` 加一个同名的搬运方法
4. 最后才是 UI 里调用它

快照里已经把派生值算好了（`pos_revs`、`stroke_revs`、`max_revs_per_sec`、`lut_points`
的 `steps` 已经是当前细分下的值），UI 不要再自己乘 400 或除细分。UI 里仅有的算术是
「走圈」按钮的圈→脉冲乘法和一个纯显示的峰值速度提示，都不参与决策。

判据：如果 `lib/` 的改动能让电机做出不同动作，那这段逻辑放错地方了。

## 本地预览（不需要 iPhone，不需要 Xcode）

一条命令：

```bash
tool/ui_preview.sh
```

Windows 上运行 `.\tool\ui_preview.ps1`。脚本会在首次运行时准备项目本地 Flutter SDK，后续每次调用都会重建 Web 包并输出预览链接；SDK、依赖缓存和构建产物都放在被忽略的 `build/` 下。

它会构建 release web 包、在 `127.0.0.1:8123` 起静态服务器、打开浏览器。
改完 Dart 代码重新跑一次，然后刷新页面。

```bash
PORT=9000 tool/ui_preview.sh        # 换端口
SKIP_BUILD=1 tool/ui_preview.sh     # 只起服务，不重新构建
```

### 为什么不是 `flutter run -d web-server`

| 方式 | 结果 |
| --- | --- |
| `flutter run -d web-server` | DDC 调试包：几百个 `.lib.js` 模块 + `dwds` 热重载客户端。在只有 Safari 的机器上**长时间白屏**（实测，见下） |
| `flutter build web --release` + 静态服务器 | 单个 2.6MB `main.dart.js`，canvaskit 打进本地 `build/web/canvaskit/`，不碰 CDN |

脚本还带 `--pwa-strategy=none`：不加 Service Worker，否则浏览器会拿旧缓存顶住新构建，
你改了半天发现界面没变。

代价是**没有热重载**。想要热重载就装 Chrome 或 Edge，然后：

```bash
flutter run -d chrome
```

Chrome/Edge 上 DDC 调试包是正常工作的。

### 关于 Safari 白屏

现象：这台机器上 `flutter run -d web-server` 的页面在 Safari 里一直是白的，
同一时间用 Cursor 内置浏览器（Chromium）打开是正常渲染的。

已确认的部分：调试包会加载 `ddc_module_loader.js`、`dart_sdk.js`、`dwds/injected/client.js`
和几百个模块；换到 release 包后，服务器日志确认 Safari 把 `main.dart.js`、`canvaskit.wasm`、
字体全部拉了下来（HTTP 200）。

**没有确认的部分**：Safari 里最终是否渲染出来，是靠人肉看的，没法自动化验证。
如果 release 包在 Safari 里也白，先用 Chromium 系浏览器确认是不是渲染问题，再看
Safari 的「开发 → 显示网页检查器」控制台。

## web 上为什么有假数据

`ff.core` 通道的实现是 iOS 侧的 Swift 插件 —— 浏览器里没有它。真的 `FfCore` 在 web 上
`invokeMethod` 会抛 `MissingPluginException`，`snapshot()` 拿不到东西，界面只能停在
「选择镜头」的空列表上。

所以 `lib/main.dart` 在 `kIsWeb` 时用 `FfCoreDemo`：

```dart
final core = kIsWeb ? FfCoreDemo() : FfCore();
```

`lib/ff_core_demo.dart` 预置一个已标定镜头，并把按钮接到一个**够看**的状态机上：三个相位
都能走通，滑条、诊断面板、TMC 面板都有内容。

它**不是**第二份控制逻辑：没有软限位夹紧、没有自动跟焦死区、没有看门狗保活、没有运动规划，
只有单位换算和相位推进。真机和 iOS 模拟器永远走 `FfCore`，碰不到这个类。

`test/ff_core_demo_test.dart` 钉住了它的相位推进、软限位和细分换算 —— 改坏的话 web 预览会
「点了没反应」，测试会先失败。

想看空状态：在预览里把镜头全删掉。

## 跑测试

```bash
flutter analyze
flutter test
```

`flutter test` 里 UI 测试的写法见 `test/widget_test.dart`：它的 `FakeCore` **只覆盖
`FfCore.invoke` 这一个出口**，所以不碰平台通道、不需要 mock method channel，
断言的是「UI 发出了什么命令」。加新的 UI 交互时照这个模式加一条。

功能层的逻辑测试在 Swift 侧（`cd ios/FollowFocusCore && swift test`），改协议/限位/相位
相关的东西才需要动。

## 改完 UI 的交付检查

- [ ] `flutter analyze` 干净
- [ ] `flutter test` 全过
- [ ] `tool/ui_preview.sh` 把改动的界面点一遍
- [ ] `lib/` 里没有多出控制逻辑（见本文第一节）
- [ ] 改动只碰了 `lib/**` 和 `test/**`；如果碰了 `ios/FollowFocusCore`，那边也要 `swift test`

## 已知限制

- web 预览**只覆盖 UI**。LiDAR 在 web 上是占位图（「LiDAR 需 iPhone Pro」），
  UDP、电机、看门狗这些必须在 iPhone 真机上验收（见 HANDOFF §8.1、§9）。
- 静态包没有热重载；这台机器没装 Chrome，装一个体验会好很多。
- `build/` 在 `.gitignore` 里，预览产物不会进版本库。
