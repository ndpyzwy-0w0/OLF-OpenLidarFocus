# OpenLidarFocus · DJI FM03

iPhone LiDAR 自动跟焦：Swift 功能层 + Flutter UI + ESP32-S3，经 CAN 收发器控制 DJI RS 跟焦电机（2022，FM03）。ESP32-S3 Super Mini 开发板和 72×40 OLED 保留。

原 TMC2209 / STEP / DIR / EN / UART / DIAG 控制已弃用。App 2.0.0+4 配合固件 2.0.0，UDP 协议版本 2；请两端一起升级。

## 接线与使用

接线、编译、刷写和验收见 [HANDOFF.md](HANDOFF.md)。CAN TX=GPIO4、RX=GPIO5，1 Mbps；OLED SDA=GPIO8、SCL=GPIO9 不变。

1. 给 FM03 独立供电，接好 3.3V CAN 收发器，与 ESP32 共地，断开 RS3。
2. 连接 ESP32 热点 `FF-XXXXXX`（密码 `change-me`），App 扫描、选用设备并连接。
3. 创建镜头，运行 FM03 内部行程校准，等待阶段 1/2 → 3，获得 0～4096 坐标。
4. 确认坐标增大对应焦距变远还是变近；手动调整焦点，记录至少两个距离标定点，再开启自动跟焦。

坐标代表已校准镜头的归一化行程，不代表电机角度或 STEP 脉冲。新版使用 `lenses-fm03.json`；旧 `lenses.json` 原样保留，不能沿用其标定数据。

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
