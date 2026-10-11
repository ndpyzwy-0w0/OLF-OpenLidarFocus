# OpenLidarFocus · DJI FM03

iPhone LiDAR 自动跟焦：Swift 功能层 + Flutter UI + ESP32-S3，经 CAN 收发器控制 DJI RS 跟焦电机（2022，FM03）。ESP32-S3 Super Mini 开发板和 72×40 OLED 保留。

原 TMC2209 / STEP / DIR / EN / UART / DIAG 控制已弃用。App 2.0.1+5 配合固件 2.0.0，UDP 协议版本 2。本次仅修改 App，无需重烧已有 FM03 2.0 固件。

## 接线与使用

接线、编译、刷写和验收见 [HANDOFF.md](HANDOFF.md)。CAN TX=GPIO4、RX=GPIO5，1 Mbps；OLED SDA=GPIO8、SCL=GPIO9 不变。

1. 给 FM03 独立供电，接好 3.3V CAN 收发器，与 ESP32 共地，断开 RS3。
2. 连接 ESP32 热点 `FF-XXXXXX`（密码 `change-me`），App 扫描、选用设备并连接。
3. 新建镜头，点击始终可见的“FM03 自动寻限位”，等待阶段 1/2 → 3。FM03 内部维护两端限位，App 仅使用 0～4096 归一化坐标，不记录机械行程。
4. 用手机 + / − 按钮低速试转，结合相机画面选择物距变近的方向。
5. 用滑条或坐标增量手动对焦，画面实焦且电机停稳后记录物距和当前坐标。物距可手动输入，也可留空使用新鲜 LiDAR 测距。至少 5 点，覆盖近、中、远距离；可继续补点修正。
6. App 按 1/物距分段插值生成图表，图表与跟焦使用同一映射。点击“开始跟焦”，有新鲜 LiDAR 距离后开启“自动跟焦”。超出标定距离时保持最近标定端点，不做外推。
7. 方向和距离表自动持久化。重新连接、重启 App 或换镜头后先寻限位；已有表保留，不做最近点平移。更换齿轮安装位置或镜头后长按“重置距离标定”并确认，重新选方向和标定；改方向也会清空旧表。

坐标代表已校准镜头的归一化行程，不代表电机角度或 STEP 脉冲。新版使用 `lenses-fm03.json`，仅保存镜头信息、方向和距离表。2.0.0 的旧 FM03 表可能被对齐流程平移，升级时保留名称和备注、要求重新标定；旧 `lenses.json` 原样保留，不能沿用其步进标定数据。

FM03 参数：最大拨轮速度 1～256（默认 64）、到位容差 1～64（默认 4）、接近减速系数 1～64（默认 4）。这些是控制器参数，不是驱动电流或实际角速度。

内部校准暂无已验证的软件取消指令。“停止观察”只退出 App 观察流程；要立即中止内部校准须切断 FM03 电源。

## 开发与测试

```sh
flutter pub get
flutter analyze
flutter test
cd ios/FollowFocusCore && swift test
```

固件：`pio run -d firmware`。主机模拟：见 [test/firmware_host/README.md](test/firmware_host/README.md)。无硬件 UI 演示：`tool/ui_preview.sh`。

协议契约见 [PROTOCOL.md](PROTOCOL.md)，控制设计见 [CONTROL_ARCHITECTURE.md](CONTROL_ARCHITECTURE.md)。历史步进方案仅存放于 `docs/legacy/`。

FM03 报文及反馈解码来自 [DJI-FM03-can](https://github.com/ndpyzwy-0w0/DJI-FM03-can)，移植依据记录在 HANDOFF.md。软件测试与编译不能替代本项目的机械实机验收。
