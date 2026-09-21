# 跟焦器交接（2026-09-22）

下一任模型先读本文，再改代码。仓库：`J:\New soft project\iphone-follow-focus`。

## 产品

电影机拍片；iPhone 贴机身当 LiDAR 测距/跟踪；ESP32-S3 Super Mini + TMC2209 扭电影镜头对焦环。电机是笨绝对位置伺服。手机做 LiDAR/人脸/LUT。链路：**WiFi SoftAP + UDP**，不要 BLE。

## 现在通 / 不通

| 块 | 状态 |
| --- | --- |
| USB 烧录 COM19（S3 原生 CDC） | 通 |
| SoftAP `FF-debug` / `ffdebug1`，UDP `192.168.4.1:4210` | 通 |
| OLED 0.42" 72×40 I2C `0x3C` | 通 |
| STEP/DIR 绝对位置（曾经转过） | 软件在；若轴不动先查 VS、EN、滑条/Jog |
| TMC2209 UART 读寄存器 | **不通**（卡在这里） |
| iOS LiDAR | 代码有；Windows 编不出，需 Mac + iPhone Pro |

**不要再靠扫波特率/对调引脚 magically 修好 UART。** ESP 侧已经能发报文、能听到自己的回声。芯片 TX 焊盘量到 **约 1.2V**，不是 UART 空闲（应约 3.3V）。先把这根脚和 VIO 弄对。

## 硬件

- 板：**ESP32-S3 Super Mini**（排针 GPIO0–13 + USB 19/20 + LED 48）。**没有 GPIO17/18。**
- 驱动：用户还有一套已跑通的 TMC 工程（见下）。模块多半是 **BIGTREETECH TMC2209**，UART **单线**。
- 电机电源 **VS/VM**（常见 12V）与逻辑 **VDD/VIO=3.3V** 分开，**共地**。VS 不要接到 3.3V。UART 也要 VM 先有电。
- CLK / MS1 / MS2 在已通工程里可以悬空（地址 0）。

### 引脚（当前固件）

| 功能 | GPIO |
| --- | --- |
| BOOT 按键（使能） | 0 |
| STEP | 5 |
| DIR | 6 |
| EN（低有效） | 7 |
| OLED SDA / SCL | 8 / 9 |
| TMC UART TX（ESP 发） | 11 |
| TMC UART RX（ESP 收） | 12 |
| WS2812 | 48 |
| USB D−/D+ | 19/20 |

Super Mini 丝印 **TX/RX 是 GPIO43/44**（USB 串口），**不要**接到 TMC。

### UART 接线（用户最后的说法）

```text
GPIO11 ----10k----+---- TMC TX
GPIO12 -----------┘
3.3V → VDD     GND 共地     VM 先上电
```

标准是 **1k** 不是 10k。11 只能经过电阻到焊点，**不要**再直连 TX。

用户量 **TMC TX ≈ 1.2V**。可能：

1. 探笔在 **VREF**（电位器本来就是 ~1V），不是 TX/PDN。
2. **VIO 实际不是 3.3V**，芯片没逻辑电，ESP 经 10k 把脚拉在中间。
3. 拔掉 11/12 再量 TX：到 3.3V = ESP 在拉总线；仍 1.2V = 脚不是 UART 或没电。

BTT 左边常见顺序：EN、MS1、MS2、**TX/RX（同一脚）**、CLK、STEP、DIR。要接 **TX/RX 那根**，不是空焊盘。

### 已跑通 UART 的参考工程（复用这个，不要再引入 TMCStepper）

`J:\softwareProject\esp32s3-tb6600-stepper`

- 板是 DevKitC，UART 在 **IO17 单线**：`Serial2.begin(115200, SERIAL_8N1, 17, 17)`
- `uart_set_mode(UART_NUM_2, UART_MODE_RS485_HALF_DUPLEX)`
- `gpio_set_drive_capability(tx, GPIO_DRIVE_CAP_0)` + pullup
- 只接模块 **TX**，不接 RX，不必 1k
- 读 IOIN `0x06`，回包 `05 FF 06`，version `0x21`/`0x20`
- 原始 4 字节读 / 8 字节写 + CRC，**不用 TMCStepper 库**

跟焦器 Super Mini 没有 17，应对齐到 **直连 TMC TX 的那根脚（现在是 GPIO12）** 做同样的同脚半双工。

## 固件要点

路径：`firmware/`，PlatformIO env `s3mini`。

```text
pio run -e s3mini -t upload --upload-port COM19
```

`platformio.ini`：`ARDUINO_USB_CDC_ON_BOOT=1`，`monitor_dtr=0` `monitor_rts=0`。Flash 写 4MB。打开 CDC 若收不到 boot 日志：探测在 `loop` 里，USB 常晚于前半段 printf。

启动顺序（故意的）：

1. `motorBegin()`：FastAccelStepper RMT，**先于** `neopixelWrite`（RGB 也占 RMT，反了会 `step pin busy`，EN 拉不下来）。
2. OLED、WiFi AP。
3. **`loop` 里第一次** `motorUartBegin()`，避免 UART `flush` 卡死时按键/热点都不工作。
4. **不要** `setCpuFrequencyMhz(80)`：WS2812 会灭。

BOOT：只切换使能（OLED `OFF`↔`EN`，灯红/绿），**不会自己转**。转要用 Flutter Jog/`SET_POS`。EN 在 `applyEnable` 里直接 `digitalWrite`（低=使能）。

TMC 报文（和 [这篇](https://blog.csdn.net/m0_64386340/article/details/141472069) 一样，不要用串口助手当产品）：

- 读：`05 addr reg crc`（reg **不要** `|0x80`）
- 写：`05 addr (reg|0x80) d3 d2 d1 d0 crc`
- 回包从机地址 `0xFF`；跟焦 **不要**写 `VACTUAL 0x22` 当主控（那是内部脉冲，破坏绝对位置）

当前 `tmcBringUp()`：先 `r12 t12` 115200 半双工，再 `r11 t11`，再双脚 19200。失败串口 `tmc uart fail`，OLED `chk TX`。

**已观察的串口现象（不要当“波特率错”）：**

- 双脚模式常收到 **正好 4 字节** `05 00 06 6f`（及 addr1–3 对应 CRC）→ **自己的读 IOIN 回声**，没有 `05 FF …`
- GPIO12 同脚半双工：**0 字节**（半双工抑制回声，芯片仍不回）

TMCStepper 已从 `platformio.ini` 拿掉。CRC 在 `motor.cpp` 里。

## UDP 协议

12 字节 LE，magic `0x46`。实现：`firmware/include/protocol.h`、`lib/ff_protocol.dart`。

| cmd | 含义 |
| --- | --- |
| 0x01 SET_POS | a=步数 |
| 0x02 JOG | a=delta |
| 0x03 STOP | |
| 0x04 ENABLE | a≠0 使能 |
| 0x05 SET_LIMITS | a,b |
| 0x06 QUERY | 回 STATUS 0x81 |
| 0x07 SET_SPEED | a=Hz b=accel |
| 0x08 TMC_QUERY | 回 22 字节 TMC_DUMP 0x82 |
| 0x09 TMC_SET | a=key b=val |

flags：bit0 EN，bit1 RUN，bit2 UART_OK。

TMC keys：1 rms mA，2 细分，3 stealth，4 toff，5 ihold，6 irun。

## Flutter / iOS

- Windows 调试 GUI：`open-flutter.bat`；Flutter SDK `J:\New soft project\tools\flutter`。
- **不要**加 Python tkinter。`firmware/tools/jog.py` 仅 CLI。
- **不要**加回 `shared_preferences`（Windows 要 Developer Mode 符号链接）。LUT 用 `dart:io` 写 APPDATA/HOME。
- `windows/runner/CMakeLists.txt` 已 `/utf-8`（MSVC 中文）。
- 滑条有 `_sliderDirty`：不拖滑条时不要每 20ms 把 Jog 打回 0。
- 连接后自动 `enable(true)`。
- iOS：`ios/Runner/LidarPlugin.swift`，LiDAR 约 0.2–5m。Windows 不能测。

## 约束（用户规则）

- 新工程放 `J:\New soft project`，不要写到 home。
- Super Mini 只用 0–13。
- 少写抽象、少加依赖。
- 不要改 plan 文件。
- 未要求不要 commit。
- 懒：能复用 `esp32s3-tb6600-stepper` 的 UART 就复用，不要再造 GUI。

## 下一刀该干什么

1. **万用表**（优先于再写固件）  
   - TMC **VDD 对 GND = 3.3V**  
   - 确认 1.2V 的点是不是 **VREF**  
   - 断开 ESP 11/12 后 TX/PDN 空闲是否 **3.3V**  
   - 通断：该焊盘 ↔ Super Mini 丝印 **12**（不是丝印 TX）
2. VDD 和 TX 空闲都是 3.3V 之后，复位，串口应出现 `tmc ok ver=0x21 rx=12 tx=12`，OLED `U r12 t12 a0`。
3. UART 通了再让 Flutter TMC 面板改电流/StealthChop。STEP/DIR 跟焦不依赖 UART。
4. 不要把主控改成 `VACTUAL`。不要为 UART 再引入 TMCStepper。

## 关键文件

- `firmware/src/motor.cpp` — STEP/DIR + UART  
- `firmware/src/main.cpp` — AP、BOOT、LED  
- `firmware/src/oled.cpp` — 底行 `motorUartHint()`  
- `firmware/include/protocol.h`  
- `lib/main.dart`、`lib/ff_protocol.dart`、`lib/lens_lut.dart`  
- `ios/Runner/LidarPlugin.swift`  
- 参考：`J:\softwareProject\esp32s3-tb6600-stepper\src\main.cpp` 里 `tmcUartOpen` / `tmcSetup`
