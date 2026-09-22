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
| STEP/DIR 绝对位置（已实测） | **通**：Flutter → AP → UDP → 电机 可正常控制旋转 |
| TMC2209 UART 读写寄存器 | **通**（2026-09-22 解决，见下） |
| iOS LiDAR | 代码有；Windows 编不出，需 Mac + iPhone Pro |

### UART 是怎么通

**接了模块上标 `RX` 的那个脚，不是 `TX`。** 这是唯一的原因。

```text
GPIO12 ---- 模块 RX 脚          ← 就这一根
GPIO11 空着（不要接，不要 10k）
3.3V → VDD      GND 共地      VM 先上电
模块 TX 空着
```

固件按 **GPIO12 同脚半双工**（`r12 t12`，115200，`RS485_HALF_DUPLEX`）握手成功：

```text
tmc try r12 t12 115200
tmc ok ver=0x21 rx=12 tx=12 addr=0 baud=115200
uart U r12 t12 a0 ok=1
```

`ver=0x21` 是 TMC2209 真实版本，整帧通过 CRC 校验，不是回声。UDP 端到端也验证过：

```text
STATUS   pos=0 target=0  en=0 run=0 uart=1
uart_ok=1 stealth=1  rms=800mA  1/16  toff=4 ihold=6 irun=13 ver=0x21 cs_actual=6
drv_status=0xC0060000  sg=0  tstep=65535  flags=0xC0   (stst, stealth；无 OT/OLA/OLB/S2G)
```

**踩过的坑，别重犯：**

- 接 **TX** 脚时：双脚模式下只能收到**自己发出的 4 字节** `05 00 06 6f`（及各地址对应 CRC）——那是 ESP 自己的回声，不是芯片应答；改成 GPIO12 同脚半双工后是 **0 字节**。两种都**不是**波特率问题，不要再扫波特率或对调引脚。
- TX 脚对地量到 **约 1.2V**（不是 UART 空闲的 3.3V），说明那根脚不是这根单线 UART。**1.2V 是故障特征，不是要修的目标。**
- 参考工程 `esp32s3-tb6600-stepper` 的 README 写的是接「模块 TX」；**在同一块 V1.1 模块上实测，跟焦器这边要接 RX 才通**。两块板子走线不同，以实测为准。

**电流来源已切换：** UART 通之前由模块 **VREF 电位器**决定；通之后 `tmcApply()` 会写 `GCONF`（`I_scale_analog=0`）+ `IHOLD_IRUN`，电流改由**寄存器**决定，**默认 800 mA RMS、16 细分、stealthChop**。所以：

- 电机**变热或变强是正常的**，是寄存器在接管，不是故障。
- 要调就在 Flutter 的 TMC 面板改 mA（参考工程用的是 400 mA），或改 `motor.cpp` 里的 `kRmsMa`。
- 此时拧 VREF 电位器**不再起作用**。

## 硬件

- 板：**ESP32-S3 Super Mini**（排针 GPIO0–13 + USB 19/20 + LED 48）。**没有 GPIO17/18。**
- 驱动：**BIGTREETECH TMC2209 V1.1**（与参考工程同一块/同款），UART **单线**。
- 电机电源 **VS/VM**（常见 12V）与逻辑 **VDD/VIO=3.3V** 分开，**共地**。VS 不要接到 3.3V。**先上 VM，再插 USB**。
- CLK / MS1 / MS2 悬空即可（地址 0）。

### 引脚（当前固件）

| 功能 | GPIO |
| --- | --- |
| BOOT 按键（使能） | 0 |
| STEP | 5 |
| DIR | 6 |
| EN（低有效） | 7 |
| OLED SDA / SCL | 8 / 9 |
| TMC UART（同脚半双工） | **12 → 模块 RX 脚** |
| （未使用） | 11 |
| WS2812 | 48 |
| USB D−/D+ | 19/20 |

Super Mini 丝印 **TX/RX 是 GPIO43/44**（USB 串口），**不要**接到 TMC。

### UART 接线（实测可用）

```text
GPIO12 ---- 模块 RX 脚
3.3V → VDD     GND 共地     VM 先上电
GPIO11 空着     模块 TX 空着     不要 10k
```

参考工程那套（`esp32s3-tb6600-stepper`）走的是 DevKitC 的 IO17 单线、接的是模块 TX。**跟随焦器这套不同，以实测的 `U r12 t12 a0` 为准**：同一块模块，这边必须接 **RX** 脚。

### 已跑通 UART 的参考工程（复用这个，不要再引入 TMCStepper）

`J:\softwareProject\esp32s3-tb6600-stepper`

- 板是 DevKitC，UART 在 **IO17 单线**：`Serial2.begin(115200, SERIAL_8N1, 17, 17)`
- `uart_set_mode(UART_NUM_2, UART_MODE_RS485_HALF_DUPLEX)`
- `gpio_set_drive_capability(tx, GPIO_DRIVE_CAP_0)` + pullup
- 只接模块 **TX**，不接 RX，不必 1k
- 读 IOIN `0x06`，回包 `05 FF 06`，version `0x21`/`0x20`
- 原始 4 字节读 / 8 字节写 + CRC，**不用 TMCStepper 库**

跟焦器 Super Mini 没有 17，已对齐成 **GPIO12 同脚半双工、接模块 RX 脚**（见「UART 是怎么通」）。

## 下一刀该干什么

UART 已通，硬件排查结束。剩下的都是软件/产品：

1. **先按审查画布修那两个真问题**（都不依赖硬件）：
   - 软限位默认值 `±1,000,000` → 与 App 的 `±20000` 一致（`motor.cpp` 两行）
   - iOS 预览 `.resizeAspectFill` 与点击坐标的换算（标定精度前提）
2. **确认电流合适**：现在寄存器默认 **800 mA RMS**。若镜头环发烫或丢步，在 Flutter TMC 面板调（参考工程用 400 mA）。
3. 在 Flutter 里跑一遍 TMC 面板：改 mA / toff / 细分 / StealthChop，看日志是否有异常位。
4. 上 Mac 编 iOS 真机包，测 LiDAR 距离与人脸跟踪，再做镜头标定。
5. 不要把主控改成 `VACTUAL`。不要为 UART 再引入 TMCStepper。

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

当前 `tmcBringUp()`：先 `r12 t12` 115200 半双工，再 `r11 t11`，再双脚 19200。失败串口 `tmc uart fail`，OLED `chk RX`。

**排查期的串口现象（当时的线是接在模块 `TX` 脚上，已废弃，仅作对照）：**

- 双脚模式常收到 **正好 4 字节** `05 00 06 6f`（及 addr1–3 对应 CRC）→ 那是 **ESP 自己的回声**，不是芯片应答
- GPIO12 同脚半双工：**0 字节**

结论是那根脚不对。**换到模块 `RX` 脚后，同样的 `r12 t12` 立刻握手成功**，说明固件和波特率一直是对的，不用改。

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

## 关键文件

- `firmware/src/motor.cpp` — STEP/DIR + UART  
- `firmware/src/main.cpp` — AP、BOOT、LED  
- `firmware/src/oled.cpp` — 底行 `motorUartHint()`  
- `firmware/include/protocol.h`  
- `lib/main.dart`、`lib/ff_protocol.dart`、`lib/lens_lut.dart`  
- `ios/Runner/LidarPlugin.swift`  
- 参考：`J:\softwareProject\esp32s3-tb6600-stepper\src\main.cpp` 里 `tmcUartOpen` / `tmcSetup`
