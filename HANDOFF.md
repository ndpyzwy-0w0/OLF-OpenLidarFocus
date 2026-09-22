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
| WS2812 | 48（**当前未使用，见下**） |
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

1. **在 Flutter 里实测一遍**：连接 → 使能 → Jog/滑条 → 确认轴真的转（别只看界面的 pos 数字；`pos` 是开环计数）。Jog 想更快就加**加速度**，不是加巡航速度。
2. **确认电流合适**：运行电流默认 800 mA RMS。若镜头环发烫或丢步，在 Flutter TMC 面板调（参考工程用 400 mA）。保持电流默认 200 mA，待机自动断电默认开。
3. 在 Flutter 里跑一遍 TMC 面板：每个参数都有中文说明，改完看日志是否有异常位。
4. 上 Mac 编 iOS 真机包，测 LiDAR 距离与人脸跟踪，再做镜头标定。
5. 不要把主控改成 `VACTUAL`。不要为 UART 再引入 TMCStepper。**不要加回 `neopixelWrite`。**

## 固件要点

路径：`firmware/`，PlatformIO env `s3mini`。

```text
pio run -e s3mini -t upload --upload-port COM19
```

`platformio.ini`：`ARDUINO_USB_CDC_ON_BOOT=1`，`monitor_dtr=0` `monitor_rts=0`。Flash 写 4MB。打开 CDC 若收不到 boot 日志：探测在 `loop` 里，USB 常晚于前半段 printf。

启动顺序（故意的）：

1. `motorBegin()`：FastAccelStepper RMT。OLED、WiFi AP。
2. **`loop` 里第一次** `motorUartBegin()`，避免 UART 卡死时按键/热点都不工作。
3. **不要** `setCpuFrequencyMhz(80)`。

### 绝对不要用 `neopixelWrite` 驱动 GPIO48 的 WS2812（已删除）

**这是修了好几轮才找到的坑，务必别再引入。**

Arduino 的 `esp32-hal-rmt.c` 里 `neopixelWrite` 用**旧版 `rmt_*` API + 自己的私有通道分配表 `g_rmt_objects[]`**；而 FastAccelStepper 在 IDF5 下用**新版 `driver/rmt_tx.h`（`rmt_channel_handle_t`）**。**两套分配器各自记账、看不到对方，会同时抢到同一个硬件 RMT 通道。**

后果不是报错，而是**静默错乱**，而且症状随分配顺序变：

| 现象 | 含义 |
| --- | --- |
| ESP 侧 `pos` 平滑推进、`run=1` | 固件以为在动 |
| 芯片侧 `STST=1`、`CS_ACTUAL` 停在 IHOLD | **驱动根本没收到脉冲** |
| 有时 `STST=0` 但 `pos` 卡死不动 | 通道被抢，ISR 记账和输出脱节 |
| 偶发 `OT` | 电机堵转发热 |

所以**不要用 `pos` 变化判断电机是否在转**——那是开环计数，跟轴无关。**看 `STST` 和 `TSTEP` 才是真相**：运动时 `TSTEP` 会掉到小数值（如 94→2047），静止时是 65535。`CS_ACTUAL` 运动时应升到 IRUN（13），静止回 IHOLD（6）。

LED 已整段删除（`PIN_LED` / `setLed` / `updateLed` / `neopixelWrite`），OLED 已经显示 OFF/EN/RUN 和 UART 状态，功能不丢。**要恢复 RGB 灯，必须用 IDF5 新版 RMT 驱动（和 FastAccelStepper 同一个分配器），不要用 `neopixelWrite`；MCPWM 在 IDF5 下没有后端可用（`StepperISR_idf4_esp32_mcpwm_pcnt.cpp` 只有 IDF4 版）。**

BOOT：只切换使能（OLED `OFF`↔`EN`），**不会自己转**。转要用 Flutter Jog/`SET_POS`。EN 在 `applyEnable` 里直接 `digitalWrite`（低=使能）。

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

## 为什么“点走步没反应”（已定位）

固件里 `motorJog` / `motorSetPos` 的第一行是：

```c
if (!stepper || !enabled) return;
```

**未使能时静默返回**，App 那边看不出任何异常。而 **板子一重启 `enabled` 就归零**，App 只在点「连接电机」时发过一次使能——于是重启之后所有走步/滑条/自动跟焦都像坏了一样。实测对照：

```text
enabled=0 时 JOG 800 -> pos=0  target=0   ← 被完全忽略
ENABLE 之后同一 JOG  -> pos=800           ← 正常
```

修法在 App 侧（固件不该自动使能电机，那样上电就带电很危险）：App 用 `_wantEnabled` 记“用户意图”，发现固件报 `enabled=0` 就自动补发一次使能（1 秒节流）。点走步时若发现没使能，会先发使能并提示“再点一次”。

**规矩：App 端别用“上报的 enabled”当“用户想要的状态”，两者要分开记。**

## 参数持久化（NVS）

TMC 参数存进 flash（`Preferences` 命名空间 `tmc`），重启不再回默认值：

| 键 | 内容 |
| --- | --- |
| `rms` | 运行电流 mA |
| `hold` | 保持电流 mA |
| `ms` | 细分 |
| `toff` | 关断时间 |
| `stealth` | 静音开关 |
| `intpol` | 微步插值 |
| `standby` | 待机断电开关 |

写入时机：每次 `motorTmcSet()` 之后；读取在 `motorBegin()` 里、**必须早于 `tmcApply()`**。

**故意不持久化 `enabled`**：开机自动使能电机很危险（会突然带电顶镜头）。要由 App 连上后自己补使能。

实测：设成 1000 mA / 1/32 / toff 7 / spread 后复位，读回仍是这四个值。

## 走步 / 走圈

换算：**0.9° 电机 → 400 整步/圈**，脉冲/圈 = 400 × 细分（1/16 时 = 6400）。逻辑在 `lib/motor_cal.dart`（`MotorCal`），有单测；换 1.8° 电机只改 `fullStepsPerRev = 200`。

**走圈复用 JOG，不在固件里加新指令**：步数 = 圈数 × 脉冲/圈，然后发相对运动。App 面板有 步 / 圈 两个输入框和各自的「走步/走圈/反向」按钮，并显示当前位置是多少圈。

## 速度 / 加速度（为什么“调速不生效”、“换 256 后很慢”）

**速度和加速度在 App 里用物理单位给（圈/秒、圈/秒²），发给固件前乘脉冲/圈换成步。**
不要用步/秒做界面单位——换细分会让同一数值的物理速度差 16 倍，这就是
“换成 1/256 后变得很慢”的原因：脉冲/圈从 6400 变成 102400，同样 40000 步/秒
的物理速度从 6.25 圈/秒掉到 0.39 圈/秒。

实测（同一圈行程，40000 步/秒）：

| 细分 | 脉冲/圈 | 耗时 |
| --- | --- | --- |
| 1/16 | 6400 | 0.33 s |
| 1/256 | 102400 | 2.9 s |

**hz 是巡航速度，accel 才是短行程的瓶颈。** 跑固定距离 d 时峰值速度 ≈
`sqrt(2 * accel * d)`，够不到 hz 就没意义。所以 80/800 步的 Jog 想更快要加**加速度**，
不是加巡航速度。App 里两个滑条都是圈/秒、圈/秒²。

**1/256 外部细分在这个项目上没有意义**：TMC2209 开 `intpol`（固件默认开）时，
MRES=1/16 会内部插值到 1/256，平滑度一样但脉冲只有 1/16。除非有特殊理由，
外部细分保持 **1/16 + 插值**。App 会在速度超过当前细分的物理上限时给出提示。

## 软限位：按“圈”缩放，不要写死步数

固件默认软限位是 **±`kDefaultLimitRevs` 圈（20）**，随细分自动重算：
`步数 = 400 × 细分 × 20`。1/16 时是 ±128000 步，1/256 时是 ±2048000 步。

**为什么不能写死步数**：写死 ±20000 时，1/16 下还有 3.1 圈行程，1/256 下只剩
**0.2 圈**——连一圈都走不了，命令被 `clampLim()` 静默夹掉，表现就是“点了没反应”。
这正是“SLP 之后操作无反应”的成因之一（另一个是无线链路偶发掉线）。

`minLim/maxLim` 在 App 下发 `SET_LIMITS` 后被 `limExplicit` 锁定，不再自动重算。
App 侧对应常量是 `lib/motor_cal.dart` 的 `kDefaultLimitRevs`——**两边必须一致**。

App 还会在发命令前用 `_lo()/_hi()` 预检，超限就提示而不是静默失败。
“点了没反应”这类问题一半来自静默 no-op，能提示就提示。

### 标定与细分绑定

`LensLut` 记录 `microsteps`，`scaledTo(ms)` 按比例换算步数，`adding()` 会先把旧点
统一到当前细分再加新点。**不这样做的话，改一次细分整套标定就静默错位。**

## 状态标志与 `isRunning()`

`motorMoving()` 用**位置是否到达目标**判断，**不用** `FastAccelStepper::isRunning()`。
实测 `isRunning()` 在目标被反复覆盖后会保持 true，后果是界面永远显示 RUN、
待机永不触发。

`motorStop()` 之后位置还会因减速越过目标，所以 `settleTick()`（每 loop 调用）
在位置连续 300 ms 不变时把 `target` 对齐到实际位置，让 `motorMoving()` 收敛。

## 写测试脚本时注意（踩过的坑）

状态包（0x81）和 TMC dump（0x82）都发到同一个 UDP 源端口。**每次发送前先清空
接收队列，并按 `d[1]` 匹配期望的命令码**；否则会把上一条 TMC 回复当成状态包解析，
得出“pos == target 但 MOVING 置位”这种自相矛盾的结论，浪费大量时间排查固件。

```python
def raw(c, a=0, b=0, want=0x81):   # 除 TMC 命令外都回 0x81
    drain()                         # 清空遗留报文
    send(c, a, b)
    return 按 d[1] == want 匹配的报文
```

## TMC2209 可调参数

App 面板每个参数都配中文说明；固件侧 `FfTmcKey`（`include/protocol.h`）与 `motorTmcSet` 的 key 一一对应。

| key | 参数 | 含义 / 范围 |
| --- | --- | --- |
| 1 | 运行电流 | 转动时的电流 mA，300–1200，默认 800。越大越有力越热 |
| 2 | 细分 | 每整步细分数 8/16/…/256，越高越平滑、脉冲越多 |
| 3 | StealthChop | 1=静音（静止可能有轻微嗡声），0=SpreadCycle（响、力矩硬） |
| 4 | toff | 斩波关断时间 1–15，一般 3–5 |
| 5 | 保持电流 | 停止时维持的电流档 0–31（相对 irun）。**0 = 不锁轴、不发热** |
| 6 | 运行电流档 | 直接写 IRUN 的 CS 值 0–31，一般不用动 |
| 7 | **待机断电** | 1=静止约 2.5 s 后断使能（不发热不震），0=一直保持电流 |

**注意 `CS_ACTUAL` 是“配置值”不是“实测电流”**：待机断使能后它仍显示 IHOLD 档（如 3），别据此判断待机没生效——看状态位 `FF_FLAG_STANDBY`（App 显示 `SLP`）和轴是否发烫。

## 待机发热 / 轻微震动

静止时的发热与嗡震都来自**保持电流**。两级处理：

1. **默认保持电流从 400 mA 降到 200 mA**（`kHoldMa`），CS 档从 6 降到 3——发热约为原来 1/4。
2. **待机自动断电**（key 7，默认开）：静止约 2.5 s 后拉高 EN 释放驱动，0 发热 0 震动；任何运动指令立刻唤醒。

代价：待机时**没有锁轴力**。跟焦是开环的，若镜头环受重力/弹簧会自己走，位置就会丢——这时把待机断电关掉（App 开关），或把保持电流调到 0 之外的值。

## 已知未复现的异常

**排查历史**：曾经观察到 `run=1` 卡住、`pos` 冻结、`TSTEP` 恒定不变的“空转重放”状态。
后来查明有两类原因，**都不是固件**：

1. **测试脚本把 TMC dump（0x82）当状态包（0x81）解析**（见上面“写测试脚本时注意”）。
   带严格命令码过滤的脚本复测，`moving` 一直正确。
2. **软限位静默夹掉命令**（写死步数时）：命令超过 `clampLim()` 就直接变成原地不动，
   看起来像“卡死”，实际上是没动。

如果将来真遇到“位置不动”，按这个顺序查：
1. `STST` / `TSTEP`：`TSTEP != 65535` 说明驱动在收脉冲（轴在转）；`pos` 只是开环计数，不可信
2. `moving` 标志（`FF_FLAG_MOVING`）与 `standby`（`FF_FLAG_STANDBY`）：待机后要先唤醒
3. 是不是超出了软限位
4. 断电重启

## UDP 协议

12 字节 LE，magic `0x46`。实现：`firmware/include/protocol.h`、`lib/ff_protocol.dart`。

| cmd | 含义 |
| --- | --- |
| 0x01 SET_POS | a=步数 |
| 0x02 JOG | a=delta |
| 0x03 STOP | |
| 0x04 ENABLE | a≠0 使能 |
| 0x05 SET_LIMITS | a,b（按步数，会锁住自动限位） |
| 0x06 QUERY | 回 STATUS 0x81 |
| 0x07 SET_SPEED | a=Hz b=accel（**注意是步/秒，App 负责从圈/秒换算**） |
| 0x08 TMC_QUERY | 回 22 字节 TMC_DUMP 0x82 |
| 0x09 TMC_SET | a=key b=val（key 见 TMC 表，7=待机断电；回 0x82） |

flags：bit0 EN，bit1 RUN，bit2 UART_OK，bit3 STANDBY（待机已断使能）。

**除 TMC 命令回 0x82 外，其它命令都回 0x81。**

TMC keys：1 rms mA，2 细分，3 stealth，4 toff，5 ihold，6 irun。

## Flutter / iOS

- Windows 调试 GUI：`open-flutter.bat`；Flutter SDK `J:\New soft project\tools\flutter`。
- **不要**加 Python tkinter。`firmware/tools/jog.py` 仅 CLI。
- **不要**加回 `shared_preferences`（Windows 要 Developer Mode 符号链接）。LUT 用 `dart:io` 写 APPDATA/HOME。
- `windows/runner/CMakeLists.txt` 已 `/utf-8`（MSVC 中文）。
- 滑条有 `_sliderDirty`：不拖滑条时不要每 20ms 把 Jog 打回 0。
- 连接后自动 `enable(true)`。
- 速度与加速度是两个滑条；加速度默认 200000，别写死成 20000，否则调速滑条看起来没反应。
- iOS：`ios/Runner/LidarPlugin.swift`，LiDAR 约 0.2–5m。Windows 不能测。

**iOS 未修的已知问题（会影响标定精度）**：预览层用 `.resizeAspectFill`，竖屏 480×640 画面被裁掉两侧再铺满屏幕；但点击坐标按 view 边界直接归一化后当深度图坐标用，**取景点会系统性偏移**，越靠画面边缘越偏。这个偏移标定补不回来，必须先把 aspect-fill 的显示矩形算出来再反算，或改成 `.resizeAspect` 加黑边。

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
