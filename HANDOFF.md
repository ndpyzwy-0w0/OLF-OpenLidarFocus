# FM03 交付与接线

## 硬件

开发板仍为 ESP32-S3 Super Mini，OLED 仍为 SSD1306 72×40，I²C GPIO8 SDA / GPIO9 SCL，地址自动探测 0x3C/0x3D。BOOT 按钮 GPIO0 切换普通控制使能。

使用 SN65HVD230 或其他兼容 3.3V 逻辑、支持 1 Mbps 的 CAN 收发器：

- ESP32 GPIO4 → 收发器 D/TXD；GPIO5 ← R/RXD。
- 收发器 VCC 接 3.3V、GND 与 ESP32 和 FM03 电源地共地。
- CANH/CANL 接 FM03 Type-C 测试板上参考仓库已核对的 CAN 差分线；按已验证线序接线，不从普通 USB 线颜色推断极性。
- FM03 由独立 5V 电源经 Type-C VBUS/GND 供电，电源需有足够电流。CAN 收发器不能给电机供电。
- RS3 断开；总线两端各 120Ω，断电后 CANH/CANL 间约 60Ω。参考台架使用保留 120Ω 的收发器模块，加上 FM03 自带 120Ω。

原 GPIO5 STEP、GPIO6 DIR、GPIO7 EN、GPIO11 DIAG 和 GPIO12 UART 不再使用；尤其 GPIO5 已改为 CAN RX，刷写前拆除原驱动接线。

## 构建与刷写

固件 2.0.0，App 2.0.0+4；固件仍用 `firmware/platformio.ini` 的 `s3mini` 配置、4MB flash、USB CDC。

```sh
pio run -d firmware
pio run -d firmware -t upload --upload-port <串口>
flutter build ios --no-codesign
```

单独 `firmware.bin` 写入地址 0x10000；首次完整刷写优先用 PlatformIO upload 同时写入 bootloader/partitions/app，不能把应用 bin 写到 0x0。iPhone 真机安装仍需要 Xcode 签名。

本次只编译和模拟，不自动操作串口、刷写板子或启动机械运动。实际安装后请先低速核对方向、终端电阻及反馈新鲜度。

## 控制行为与验收

1. 打开热点和 OLED，OLED 显示 CAN 1M 4/5；无电机反馈时 CAN 状态不在线。
2. App 扫描发现 2.0.0 / protocol=2；旧 1.x 板子不能连接控制。CAN 面板显示 stage、原始坐标、反馈年龄、发送失败和接收丢帧。
3. 新镜头先运行一次内部校准，观察阶段1/2到阶段3，坐标0～4096；不能把阶段1/2的 INT32_MAX 哨兵当位置。
4. 用最大速度16～64、容差4，从两个方向接近机械标记，核对重复到位、齿轮回差和实际停止误差，再记录距离标定。
5. 普通运动中关闭 App/断开 Wi-Fi，应在1秒通信超时后归零；拔掉 CAN 反馈，应在300ms过期后停止普通输出。恢复后用新命令重新取得控制。
6. 校准期间停止观察/失联不会取消 FM03 内部自主动作。固件保持校准锁直到观察到真实阶段3，超时仍不放行普通运动；如需立即中止，切断电机电源。

归零成功只表示报文发送完成和速度值为0；尚需实机核对机械响应。反馈坐标的传感器来源、精度、回差和掉电保留不在参考仓库已验证范围内。

## 来源

移植参考仓库 `ndpyzwy-0w0/DJI-FM03-can` 的 `src/motor_control.cpp` 和 `src/motor_status.h`；版本见本文件末尾引用。采用其 0x503 DUML 请求/速度/校准模板、CRC、逐帧发送、0x504 完整帧重组和阶段3坐标筛选。其2026-10-10记录确认内部校准可用、同坐标对应可重复机械位置；本项目反馈到位控制仍需上述实机验收。

App 通道与镜头/LiDAR结构沿用原项目。历史说明位于 `docs/legacy/`，不能作为新版接线或验收依据。

参考提交：[39431c2](https://github.com/ndpyzwy-0w0/DJI-FM03-can/tree/39431c2b67e42a1e290ebfdb4ab2678541cef667)。
