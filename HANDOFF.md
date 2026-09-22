# iphone-follow-focus 项目交付文档

更新时间：2026-09-22

这份文档是后续 agent 的第一阅读入口。它描述当前仓库的真实实现，不要把旧提交或旧文档中
FastAccelStepper/RMT 的描述当作当前代码。

## 1. 项目目标

本项目是一个电影机自动跟焦器：

```text
iPhone LiDAR/人脸跟踪
    -> Flutter/Swift 负责距离滤波、目标映射和跟焦策略
    -> ESP32-S3 负责实时规划、软限位、STEP/DIR 和安全停止
    -> TMC2209
    -> 步进电机和镜头对焦环
```

当前可以先用 Windows Flutter 调试界面控制 ESP32；正式 iOS LiDAR 功能需要 macOS + Xcode +
iPhone Pro 真机。

## 2. 当前状态摘要

| 功能 | 当前状态 |
| --- | --- |
| ESP32-S3 固件编译 | 已通过 |
| 硬件定时器 STEP/DIR 输出 | 已替代旧 RMT 后端，已实测 |
| `JOG +8/-8/+80/-80` | 已验证位置增量准确 |
| `SET_POS`、STOP、反向保护 | 已实现并验证 |
| TMC2209 UART 诊断 | 已通，GPIO12 同脚半双工 |
| Wi-Fi SoftAP + UDP | 已通 |
| Flutter Windows 调试界面 | 可运行 |
| Flutter 协议和单测 | 25 项通过 |
| 通信失联停止 | 已实现，控制包超时 1000 ms |
| 手动 HOME / `positionTrusted` | 已实现 |
| 自动化 UDP 验收脚本 | 已完成，需在实际硬件/Wi-Fi 环境运行 |
| iOS LiDAR | 代码存在，未在本 Windows 环境验证 |
| Wi-Fi 列表扫描和设备发现 | 尚未实现，属于下一阶段 |

最近提交：

```text
a9c9725 fix: report trusted status on queries
3e802df feat: add motion safety and trusted home
5113270 fix: guard stepper direction changes
b6812e8 fix: replace RMT motion with timer pulses
```

## 3. 硬件和接线

硬件：

- ESP32-S3 Super Mini
- BIGTREETECH TMC2209 V1.1
- 0.9° 步进电机，400 整步/圈
- OLED 0.42 inch，I2C 地址 `0x3C`

当前引脚：

| 功能 | GPIO |
| --- | --- |
| BOOT 按键/手动切换使能 | 0 |
| STEP | 5 |
| DIR | 6 |
| EN，低有效 | 7 |
| OLED SDA/SCL | 8/9 |
| TMC UART | 12，同脚半双工 |
| 未使用 | 11 |
| USB D-/D+ | 19/20 |

TMC2209 实测可用接线：

```text
GPIO12 -> TMC 模块标记为 RX 的引脚
GPIO11 不接
模块 TX 不接
VDD/VIO = 3.3 V
VM/VS 使用电机电源
ESP32 和驱动器共地
先上 VM，再插 USB
```

不要根据参考工程的引脚名称直接改线。参考工程
`J:\softwareProject\esp32s3-tb6600-stepper` 是 DevKitC，使用 GPIO17，和本项目
Super Mini 不同。本项目已实测 `r12 t12`、115200、地址 0、TMC2209 version `0x21`。

不要重新引入 `neopixelWrite`。旧版 RMT API 和 IDF5/RMT 资源可能冲突，当前 WS2812
没有使用。

## 4. 固件

入口和主要文件：

- [firmware/src/main.cpp](<J:/New%20soft%20project/iphone-follow-focus/firmware/src/main.cpp>)：
  SoftAP、DNS、HTTP、UDP 初始化和主循环。
- [firmware/src/motor.cpp](<J:/New%20soft%20project/iphone-follow-focus/firmware/src/motor.cpp>)：
  硬件定时器脉冲、运动规划、TMC2209 UART、软限位、待机和看门狗。
- [firmware/include/motor.h](<J:/New%20soft%20project/iphone-follow-focus/firmware/include/motor.h>)：
  运动公共接口。
- [firmware/src/protocol.cpp](<J:/New%20soft%20project/iphone-follow-focus/firmware/src/protocol.cpp>)：
  UDP 命令解析和状态回复。
- [firmware/include/protocol.h](<J:/New%20soft%20project/iphone-follow-focus/firmware/include/protocol.h>)：
  协议常量和数据结构。
- [firmware/platformio.ini](<J:/New%20soft%20project/iphone-follow-focus/firmware/platformio.ini>)：
  PlatformIO `s3mini` 环境。

固件启动：

1. `motorBegin()` 初始化 GPIO、参数和硬件定时器。
2. OLED 和 Wi-Fi SoftAP 启动。
3. UDP 端口 `4210` 初始化。
4. 首次进入 `loop()` 时尝试 TMC UART，避免 UART 异常阻塞热点和按键。
5. 主循环处理 DNS、HTTP、UDP、待机和按键。

## 5. 运动后端和单位

当前不是 FastAccelStepper，也不是 RMT 队列。使用：

```text
hw_timer_t
定时器频率 50 kHz
ISR 用相位累加器生成 STEP
STEP 高电平约 3 us
只有真实输出 STEP 脉冲后 currentPos 才加/减 1
```

因此：

```text
0.9° 电机 = 400 整步/圈
脉冲/圈 = 400 * TMC 细分
1/16 = 6400 脉冲/圈
JOG +8 = 8 个脉冲
JOG +80 = 80 个脉冲
```

规划器是本地梯形/三角速度规划，不是 S 曲线：

```text
默认速度 = 8000 steps/s
默认加速度 = 20000 steps/s²
desired = sqrt(2 * acceleration * remaining_distance)
```

短距离达不到巡航速度是正常的。要改善短距离速度，应提高加速度，而不是只提高巡航速度。
反向时会先清零步速和相位，改变 DIR，等待约 3 us 后再输出反向脉冲。

## 6. Wi-Fi 和 UDP

当前固件固定为 SoftAP：

```text
SSID: FF-debug
密码: ffdebug1
AP channel: 1
默认地址: 192.168.4.1
UDP: 4210
HTTP: 80
```

HTTP 根页面可用于简单延迟测试。DNS captive portal 会把未知 HTTP 路径重定向到根页面。
Wi-Fi sleep 已关闭。

Flutter 当前 [MotorLink](<J:/New%20soft%20project/iphone-follow-focus/lib/ff_protocol.dart:241>)
使用 UDP，不建立 TCP 连接。现阶段默认目标仍是 `192.168.4.1:4210`。

### 当前协议

普通包固定 12 字节，小端：

```text
offset 0: magic uint8 = 0x46
offset 1: cmd uint8
offset 2: flags uint8
offset 3: sequence uint8
offset 4: a int32
offset 8: b int32
```

命令：

| 值 | 命令 | 参数 |
| --- | --- | --- |
| `0x01` | `SET_POS` | `a = 绝对目标步数` |
| `0x02` | `JOG` | `a = 相对步数` |
| `0x03` | `STOP` | 无 |
| `0x04` | `ENABLE` | `a = 0/1` |
| `0x05` | `SET_LIMITS` | `a=min, b=max` |
| `0x06` | `QUERY` | 无 |
| `0x07` | `SET_SPEED` | `a=steps/s, b=steps/s²` |
| `0x08` | `TMC_QUERY` | 无 |
| `0x09` | `TMC_SET` | `a=key, b=value` |
| `0x0A` | `HOME` | 手动软件校零 |

旧状态 `0x81` 仍是 12 字节。`QUERY` 当前会返回旧状态和 `STATUS_V2`。
`HOME` 也会连续返回这两个状态包。`STATUS_V2 = 0x83`，固定 16 字节：

```text
magic, cmd, flags, sequence,
pos int32, target int32,
position_trusted uint8, fault uint8, reserved uint16
```

flags 低 5 位：

```text
enabled = 1
moving = 2
uart_ok = 4
standby = 8
limited = 16
```

flags 高 3 位是最近命令结果：

```text
0 idle
1 accepted
2 completed
3 limited
4 rejected
5 stopped
```

sequence 用于把回复和请求关联。它只证明命令被接收并回复，不代表机械动作已经完成。

`STATUS` 和 `STATUS_V2` 使用同一个提升逻辑：`accepted` 在 `pos == target`
且不再运动时变为 `completed`。两种包的 `result` 始终一致。

## 7. 安全和位置可信度

### 通信看门狗

只有 `SET_POS` 和 `JOG` 会刷新运动看门狗。`QUERY`、`ENABLE`、TMC 查询等不会刷新。
看门狗阈值为 1000 ms。运动中超过阈值没有新的控制包时：

```text
motorStop()
communicationWatchdogArmed = false
commandResult = STOPPED
```

自动跟焦必须持续发送最新 `SET_POS`。当前没有区分自动会话和手动会话，长距离手动
SET_POS 也会受此规则影响。

### HOME

目前没有物理限位开关，`HOME` 不是机械回零。只有电机完全停止时才允许成功，成功后：

```text
currentPos = 0
target = 0
positionTrusted = true
```

上电、复位、禁用电机后 `positionTrusted = false`。这只是开环脉冲位置经过人工确认，
不等价于编码器闭环真实机械位置。

### 待机和使能

上电不会自动使能，避免电机突然带电。Flutter 连接后根据用户意图补发 `ENABLE`。
待机功能默认开启，静止约 2.5 s 后释放驱动；新的 JOG/目标会唤醒。

## 8. Flutter 调试程序

入口：[lib/main.dart](<J:/New%20soft%20project/iphone-follow-focus/lib/main.dart>)。

启动：

```powershell
cd "J:\New soft project\iphone-follow-focus"
. "J:\New soft project\commands\env.ps1"
flutter pub get
flutter run -d windows
```

双击 [open-flutter.bat](<J:/New%20soft%20project/iphone-follow-focus/open-flutter.bat>) 会：

1. 进入当前项目目录；
2. 启动 PowerShell；
3. 加载 `commands/env.ps1`；
4. 执行 `flutter run -d windows`；
5. 保持终端窗口不退出。

界面点击“连接电机”后才会创建 UDP socket，并发送速度、待机参数、ENABLE、QUERY、
TMC_QUERY。Windows 下 LiDAR 不可用，因为 [lidar.dart](<J:/New%20soft%20project/iphone-follow-focus/lib/lidar.dart>)
只在 iOS 启用原生通道。

Flutter 已有：

- 手动步数/圈数 JOG；
- 滑条绝对目标；
- 自动跟焦状态和死区；
- 停机闩锁，防止自动模式立即覆盖 STOP；
- 软限位预检；
- TMC 诊断；
- HOME 和 `positionTrusted`；
- 标定表持久化到 `%APPDATA%\iphone_follow_focus\lens_lut.json`。

`LensLut` 和电机换算测试位于 [lib/lens_lut.dart](<J:/New%20soft%20project/iphone-follow-focus/lib/lens_lut.dart>)
和 [lib/motor_cal.dart](<J:/New%20soft%20project/iphone-follow-focus/lib/motor_cal.dart>)。

## 9. 测试和验收

Flutter 测试：

```powershell
flutter test
```

当前已通过 25 项。

Python 语法检查：

```powershell
python -m py_compile test\udp_motion_acceptance.py
```

固件编译：

```powershell
platformio run -d firmware -e s3mini
```

烧录（当前设备曾使用 COM19）：

```powershell
platformio run -d firmware -e s3mini -t upload --upload-port COM19
```

打开串口监视器：

```powershell
platformio device monitor -d firmware -p COM19 -b 115200
```

实际硬件验收：

```powershell
python test\udp_motion_acceptance.py --host 192.168.4.1 --port 4210
```

脚本覆盖 ENABLE、JOG、HOME/STATUS_V2、SET_POS、STOP、反向、软限位、待机唤醒和
通信超时。必须连接 `FF-debug` 并接好电机后运行；没有硬件时只能做语法/编译验证。

两处容易误改的地方：

- SET_POS 组会同时校验 `STATUS` 和 `STATUS_V2` 对已完成的动作都报 `completed`。
- 通信超时组不能断言 `pos != target`：`motorStop()` 会把 `target` 重锚到停止位置，
  所以停止后 `pos == target` 恒成立。该组判定的是“没有到达请求的 19000 步”
  且 `result == stopped`。

验收时不能只看软件 `pos`。应同时观察电机是否实际转动，并用 TMC 状态判断：

```text
静止通常 TSTEP=65535、STST=1
运动时 TSTEP 应变小、STST 应解除
```

## 10. 当前未完成和下一步

### 首要下一步：Wi-Fi 设备发现

用户希望扫描附近 Wi-Fi 并显示可用跟焦器，连接时不依赖固定 IP。当前尚未实现。
建议按以下顺序设计，不要只按 SSID 判断设备身份：

1. 固件生成稳定 `device_id`，建议使用 ESP32 MAC 地址。
2. 将 SSID 从统一 `FF-debug` 改为可区分格式，例如 `FF-XXXXXX`，或至少保留
   `FF-` 设备前缀。
3. 增加 UDP 发现请求/响应，响应设备类型、ID、协议版本、固件版本和 UDP 端口。
4. Flutter 连接后先用发现协议验证这是本项目固件，再建立 `MotorLink`。
5. Windows 可使用原生 WLAN API 扫描；不要把 `netsh` 当正式跨平台方案。
6. iOS 受系统限制，不能假设普通 App 能自由读取全部附近 Wi-Fi 列表。正式 iOS
   方案更适合用 `NEHotspotConfiguration` 连接已知 SSID，再用 UDP 发现包验证。
7. 多设备识别使用 BSSID/MAC 或固件返回的 `device_id`，SSID 不是唯一身份。

### 固件

- 实现持久化 fault code，而不是当前 `STATUS_V2.fault = 0`。
- 评估自动跟焦和手动控制是否需要不同看门狗策略。
- 增加独立最大减速度和 jerk/S 曲线 profile。
- 接入真实机械限位后扩展 HOME 为自动回零。
- 如硬件允许，增加编码器闭环；开环 `pos` 不能证明机械真实位置。

### Flutter/iOS

- 把固定 `192.168.4.1` 替换为设备发现结果。
- 增加 Wi-Fi/设备列表页和连接状态。
- 完善 HOME 提示，明确它是软件校零而非机械回零。
- 在 Mac + iPhone Pro 上验证 LiDAR、目标跟踪、镜头标定和丢目标策略。
- 再开发正式 Swift/iOS 底层和 UI。

## 11. 修改规则

- 不要重新引入 FastAccelStepper/RMT 作为运动后端。
- 不要把 `pos == target` 单独当成机械运动完成证明。
- 不要把手机端每个 LiDAR 采样变成必须执行的离散轨迹点。
- 不要重新引入 `neopixelWrite`。
- 修改 STEP 输出时，必须保持“实际 STEP 脉冲完成后才推进 `currentPos`”。
- 修改协议时保留旧 12 字节客户端兼容，新增字段优先使用新命令/新包。
- 触碰电机、电流或引脚前先阅读本文和 [CONTROL_ARCHITECTURE.md](<J:/New%20soft%20project/iphone-follow-focus/CONTROL_ARCHITECTURE.md>)。
