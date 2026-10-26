# OpenLidarFocus · DJI FM03

**用 iPhone LiDAR 为手动镜头自动跟焦，也可以把手机变成无线跟焦手轮。**

简体中文 | [English](README.en.md)

[主要功能](#主要功能) · [硬件与接线](#硬件与接线) · [开始使用](#开始使用) · [开发与测试](#开发与测试)

OpenLidarFocus 是一个基于 iPhone LiDAR 的外置镜头跟焦项目。它通过 ESP32-S3 和 CAN 收发器控制 DJI RS 跟焦电机（2022，FM03），让配有对焦齿圈的手动镜头获得距离驱动的自动跟焦能力，也提供独立的无线手动跟焦模式。iPhone 用作测距、取景和控制终端，电机驱动的是外部镜头的对焦环。

当前版本：**App 2.6.2+26 · ESP32 固件 2.1.1 · UDP 协议 v2**。项目仍在开发与实机验证中，支持范围以本页列出的硬件和功能为准。

## 主要功能

### LiDAR 自动跟焦

- iPhone 后置 LiDAR 测距，支持取景点选测距与可选人脸跟踪。
- 按镜头保存名称、备注、对焦方向和距离标定表；镜头库提供首次使用指南与标定状态。
- **至少五点距离标定**，覆盖近、中、远物距；完成五点后可继续补点，物距相差不足 2 cm 时更新已有点。
- 按 **1/物距分段插值**生成焦点目标，图表与跟焦共用映射。超出标定范围时夹到最近或最远标定点；测距无效或过期时退出自动跟焦。
- 横竖屏取景、构图网格，以及可展开的控制与标定面板。

### 手机手轮与 A/B 拉焦

- 独立手动模式：连接设备并完成 FM03 自动寻限位即可使用，无需 LiDAR 或镜头距离表。
- 轮缘旋转、中心上下拖动微调，或切换滑块按 0～100% 行程指定目标。
- 手轮支持 0.25 / 0.5 / 1 / 2× 灵敏度及方向反转；滑块显示橙色 A、蓝色 B 标记和位置百分比。
- A/B 点设置、重设、清除、范围限制和端点直达；支持 **0.5～8 秒**定时拉焦，目标曲线可选缓入缓出或匀速。
- 三种刻度触感和实际反馈确认后的到位触感；控制区与停止按钮固定，设置区独立滚动。

A/B 点取自停稳后的实际电机反馈，仅在当前寻限位会话中有效。定时拉焦时长描述目标轨迹，实际机械到位时间取决于电机响应。

### 设备、调参与保护

- ESP32 独立热点、UDP 设备发现、连接状态显示，以及上次设备记忆与冷启动重连尝试。
- 调整最大拨轮速度、启动加速、接近目标减速和到位容差；以设备回读确认，普通运动中可调，停稳后保存到设备。
- CAN 诊断显示电机阶段、原始坐标、反馈年龄、发送失败及接收丢帧。
- OLED 开机完整显示 6 秒版本、热点、密码与 IP；运行时显示可信位置、目标、CAN/控制链路和故障状态。
- 普通跟焦停止后锁定并禁用运动，需明确复位；切后台停止控制与采集，返回前台后需明确复位才能恢复运动。
- 支持跟随系统、浅色和深色外观，iPhone 保存外观选择。

## 工作原理

```text
iPhone LiDAR / 点选目标 / 人脸跟踪
                  ↓
Swift FollowFocusCore ←→ Flutter 界面 / 手机手轮
测距处理、镜头映射、控制会话       ff.core 通道
                  ↓ Wi-Fi / UDP v2
ESP32-S3：反馈位置控制、超时保护、OLED
                  ↕ CAN 1 Mbps
            DJI FM03 → 镜头对焦环
```

Swift 核心只依赖 Foundation；iOS 壳负责相机、LiDAR 和平台通道；Flutter 负责展示与用户输入。电机位置控制在 ESP32 固件中运行。**0～4096 表示 FM03 寻限位后的归一化行程坐标，不是角度或步进脉冲数；速度参数也不是 RPM。**

## 硬件与接线

- 自动模式：配备后置 LiDAR 的 iPhone。完整 iOS 构建与部署需要 macOS、Xcode、Flutter 和真机签名；当前工程最低 iOS 15.4，LiDAR 仍受设备能力限制。
- ESP32-S3 Super Mini，4 MB Flash；SSD1306 72×40 I²C OLED。
- DJI RS 跟焦电机（2022，FM03）及与镜头匹配的齿轮安装结构。
- SN65HVD230 或兼容 3.3 V 逻辑、支持 1 Mbps 的 CAN 收发器；FM03 独立 5 V 电源。

接线速查：

- GPIO4 → CAN 收发器 D/TXD；GPIO5 ← R/RXD。
- OLED SDA → GPIO8，SCL → GPIO9；地址自动探测 `0x3C` / `0x3D`。
- ESP32、收发器与电机电源共地；CANH/CANL 按已核对的 FM03 转接板线序连接。
- RS3 断开；总线两端各 120 Ω，断电后 CANH/CANL 间约 60 Ω。

Type-C 接口在这里用于电源与 CAN 转接，不能按普通 USB 线颜色推断线序。完整接线、供电与验收见 [硬件说明](HANDOFF.md)。

从旧版 TMC2209 方案升级时，先拆除原 STEP/DIR 驱动接线；GPIO5 现在用于 CAN RX。历史方案保存在 `docs/legacy/`，不能用于当前版本接线。

## 开始使用

1. 接好硬件并给 FM03 独立供电。手机连接热点 `FF-XXXXXX`，默认密码 `change-me`，默认地址 `192.168.4.1`、UDP 端口 `4210`。
2. 在 App 首页进入设备管理，发现、选择并连接协议 v2 设备。按系统提示允许本地网络访问；自动模式还需要相机权限。
3. 选择模式并执行 **FM03 自动寻限位**，等待内部阶段 1/2 → 3。重连、重启 App 或换镜后需要重新寻限位。
4. **手动跟焦**：用手轮或滑块试转，停稳后设置 A/B 点，按需要启用范围限制或定时拉焦。
5. **自动跟焦**：先新建或选择镜头，小幅试转并确认物距变近方向。结合相机画面手动实焦，在电机停稳后记录至少五个标定点；距离可手动输入，或使用新鲜 LiDAR 测距。完成后点击“开始跟焦”，再开启自动跟焦。

镜头方向与距离表自动保存，重新寻限位保留已有表。改变方向或齿轮安装位置后需重新标定；旧 TMC2209 标定数据不能直接用于 FM03。

**FM03 内部自主寻限位目前没有已验证的软件取消方式。** “停止观察”、软件 STOP 或禁用不能保证中止内部校准；如需立即中止该过程，须切断电机电源。普通跟焦的停止与复位锁定不适用于中止这一内部动作。

## 开发与测试

先安装 Flutter、Xcode 和 PlatformIO。iOS 真机运行需在 Xcode 中配置开发者签名。

```sh
git clone https://github.com/ndpyzwy-0w0/OLF-OpenLidarFocus.git
cd OLF-OpenLidarFocus
flutter pub get
flutter run -d <iphone-device-id>
```

静态检查、界面测试和 Swift 核心测试：

```sh
flutter analyze
flutter test
(cd ios/FollowFocusCore && swift test)
```

编译与刷写 ESP32 固件：

```sh
pio run -d firmware
pio run -d firmware -t upload --upload-port <serial-port>
```

macOS 无硬件界面预览（需 Flutter、Python 3 和 Bash 环境）：

```sh
bash tool/ui_preview.sh
```

预览使用演示数据，不连接真实 LiDAR、UDP 或 CAN。iOS 模拟器不能验证 LiDAR；Android 模板不代表已支持完整硬件功能。固件主机模拟见 [test/firmware_host/README.md](test/firmware_host/README.md)。

主要目录：

```text
ios/FollowFocusCore/  Swift 协议、UDP、镜头映射与会话核心及测试
ios/Runner/           iOS 相机 / LiDAR、原生预览与 Flutter 通道
lib/                  Flutter 首页、镜头库、自动跟焦与手机手轮
firmware/             ESP32-S3 CAN 固件与 Python 调试工具
test/                 Flutter 测试与固件主机模拟
tool/                 Web 预览、带时间戳的串口采集工具
docs/legacy/          历史 TMC2209 方案与协议 v1
```

## 验证范围与文档

项目包含 Swift 核心测试、Flutter 界面测试和固件主机模拟。软件测试与编译不能替代机械验收：镜头负载、齿隙、重复到位、真实对焦精度、手机触感与横竖屏人脸跟踪，需要在实际安装组合下检查。CAN 反馈过期、通信超时等保护用于普通控制；内部寻限位的限制见上文。

- [硬件与实机验证](HANDOFF.md)：接线、构建部署与验收步骤。
- [PROTOCOL.md](PROTOCOL.md)：App ↔ ESP32 UDP v2 线协议。
- [CONTROL_ARCHITECTURE.md](CONTROL_ARCHITECTURE.md)：反馈控制、坐标、会话与停止语义。
- [UI_DEV.md](UI_DEV.md)：界面开发边界、演示预览与测试。
- [LIDAR_INTERFACE.md](LIDAR_INTERFACE.md)：原生 LiDAR 采样与事件接口。

## 致谢

FM03 CAN 报文与反馈解码参考 [DJI-FM03-can](https://github.com/ndpyzwy-0w0/DJI-FM03-can)，具体参考版本见 [硬件说明](HANDOFF.md#来源)。
