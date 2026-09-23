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
| Wi-Fi SoftAP + UDP | 已通，SSID 每板唯一 `FF-XXXXXX` |
| 固件侧设备发现 `FF_DISCOVER` | 已实现，真机验证通过 |
| 主机侧 Wi-Fi 扫描和列表 | 尚未实现，属于下一阶段 |
| Flutter Windows 调试界面 | 可运行 |
| Flutter 协议和单测 | 25 项通过 |
| 通信失联停止 | 已实现，控制包超时 1000 ms；请求 `flags` 位 0 = 单次锁存可豁免，见 §7 |
| 手动 HOME / `positionTrusted` | 已实现 |
| 固件协议契约文档 | [PROTOCOL.md](PROTOCOL.md)，wire 层唯一权威来源 |
| 自动化 UDP 验收脚本 | 已完成，真机 9/9 通过（含单发 JOG 流式/锁存对照） |
| iOS LiDAR | 代码存在，未在本 Windows 环境验证 |

最近提交：

```text
2301604 test: cover single-shot JOG streaming vs latched modes
8add5d6 docs: clarify watchdog ARMED semantics and refresh the commit log
45cc8c8 feat: add latched single-shot moves and allow several AP clients
b453ca4 docs: record per-board SSID and discovery protocol
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
- [firmware/src/device.cpp](firmware/src/device.cpp) 和
  [firmware/include/device.h](firmware/include/device.h)：设备身份
  （AP 接口 MAC → `FF-XXXXXX`）和固件版本号，SSID 与发现回包共用同一来源。
- [firmware/platformio.ini](<J:/New%20soft%20project/iphone-follow-focus/firmware/platformio.ini>)：
  PlatformIO `s3mini` 环境。

固件启动：

1. `motorBegin()` 初始化 GPIO、参数和硬件定时器。
2. OLED 启动；`WiFi.mode(WIFI_AP)` → `deviceBegin()` → `WiFi.softAP(deviceId(), ...)`。
   `deviceBegin()` 必须在 `mode()` 之后、`softAP()` 之前，因为 SSID 就是 `deviceId()`。
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

当前固件为 SoftAP，SSID 每板唯一：

```text
SSID: FF-XXXXXX   例如 FF-75A578，取自 AP 接口 MAC 末三字节
密码: change-me
AP channel: 1
默认地址: 192.168.4.1
UDP: 4210
HTTP: 80
```

SSID 和发现回包里的 `device_id` 都由 [firmware/src/device.cpp](firmware/src/device.cpp)
统一生成，两者必然一致；回包里的 `mac` 就是扫描列表显示的 BSSID。实测本板
`FF-75A578` / `92:DA:72:75:A5:78`。注意设备启动日志打印的 eFuse 基址是
`90:DA:72:75:A5:78`，与 BSSID 差一个本地管理位，所以身份必须取 AP 接口 MAC
（`WiFi.softAPmacAddress()`），不能取基址，否则和扫描结果对不上。

`netsh wlan show networks` 返回的是缓存，刚上电/刚重启后可能扫不到新 SSID，
隔几秒重试即可，验证 SSID 不需要真的连上去。

HTTP 根页面可用于简单延迟测试。Wi-Fi sleep 已关闭。AP 最多允许 4 台客户端同时接入
（手机 + 调试机），但协议约定同一时刻只有一个控制器发命令。

captive portal 现在按 iOS/Android 规范应答，目的是**不**弹出"需要登录网络"面板（否则
系统面板会打断 App 的 UDP 连接）：`/hotspot-detect.html` 和 `/library/test/success.html`
返回 `200` + `<HTML>…Success…</HTML>`，`/generate_204` 返回 `204`。只有人类乱输的未知
路径才 `302` 跳根页面（DNS 通配把任意域名解析到 `192.168.4.1`）。真机实测：

```text
/hotspot-detect.html        -> 200 text/html  <HTML>…Success…</HTML>
/library/test/success.html  -> 200
/generate_204               -> 204
/some/random/url            -> 302 Location: http://192.168.4.1/
```

Flutter 当前 [MotorLink](<J:/New%20soft%20project/iphone-follow-focus/lib/ff_protocol.dart:241>)
使用 UDP，不建立 TCP 连接。现阶段默认目标仍是 `192.168.4.1:4210`。

### 当前协议

> **完整 wire 契约见 [PROTOCOL.md](PROTOCOL.md)**：字段布局、回包数量不对称、请求 `flags`
> 锁存位、已验证的十六进制样例、上位机实现检查清单。本节只保留速查内容。

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
| `0x0B` | `DISCOVER` | 无，回 `0x84`，且**不**附状态包 |

请求包的 `flags`（偏移 2）本版只定义位 0：`0x01 = FF_REQ_LATCH`（单次锁存，语义见 §7）。
只有 `SET_POS`/`JOG` 解释它，其它命令忽略它；未定义的位一律忽略，便于前向兼容。

**回包数量是不对称的**，上位机不要一律"等第二个包"：

| 请求 | 回包 |
| --- | --- |
| `QUERY`、`HOME` | `STATUS` + `STATUS_V2`（两个） |
| `TMC_QUERY`、`TMC_SET` | 只有 `TMC_DUMP`（**没有** `STATUS`） |
| `DISCOVER` | 只有 `DISCOVER_REPLY` |
| 其它合法命令、未知命令 | 1 个 `STATUS` |

只有"长度 < 12"或"首字节 ≠ 0x46"的报文才被当成非协议包**原样回显**（用于链路探测）。

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

`STATUS_V2.reserved`（偏移 14，小端 uint16）位 0 = `FF_V2_WATCHDOG_ARMED (0x0001)`，
表示当前是否处于"流式看门狗监视"状态，见 §7。`STATUS_V2.fault` 目前恒为 0，故障只能
通过 `TMC_DUMP.drv_flags` / `uart_ok` 判断。

`STATUS` 和 `STATUS_V2` 使用同一个提升逻辑：`accepted` 在 `pos == target`
且不再运动时变为 `completed`。两种包的 `result` 始终一致。

### 设备发现

`DISCOVER` 复用控制端口 `4210`，不另开端口。请求就是普通 12 字节包的
`cmd = 0x0B`，`a`/`b` 忽略。设备回一个 32 字节 `FF_DISCOVER_REPLY = 0x84`，
固定小端布局：

```text
offset 0:  magic uint8 = 0x46
offset 1:  cmd uint8 = 0x84
offset 2:  kind uint8 = 1（跟焦器）
offset 3:  protocol uint8 = 1
offset 4:  udp_port uint16
offset 6:  fw_major/minor/patch uint8 ×3
offset 9:  mac[6]，与扫描到的 BSSID 相同
offset 15: device_id[16]，NUL 结尾，例如 "FF-75A578"
offset 31: reserved
```

`protocol.h` 里有 `static_assert(sizeof(FfDiscovery) == 32)`。这个分支在
[firmware/src/protocol.cpp](firmware/src/protocol.cpp) 里**直接 `return`**：
发现请求不该顺带回一个状态包，否则和 `QUERY` 的双包行为混淆，主机端也不好解析。

主机侧工具 [firmware/tools/discover.py](firmware/tools/discover.py)：

```powershell
python firmware\tools\discover.py                      # 广播
python firmware\tools\discover.py --target 192.168.4.1 # 单播
python firmware\tools\discover.py --bind 192.168.4.2   # 指定源地址
```

真机结果：`FF-75A578  fw 1.0.0  udp 4210  mac 92:DA:72:75:A5:78  at 192.168.4.1`，
且只收到 1 个数据包。

开发机排查提示：主机存在多条默认路由时（本项目机器上有以太网 + VPN），
受限广播 `255.255.255.255` 会跟随**默认路由**从别的网卡出去，永远到不了板子，
表现就是"单播能通、广播无响应"。所以 `discover.py` 先发一次不绑定的包，再逐个
绑定本机 IPv4 各发一次（等价于 SSDP 的做法），也支持直接发子网广播
`--target 192.168.4.255`。板子本身不需要为此做任何改动。

## 7. 安全和位置可信度

### 通信看门狗

只有 `SET_POS` 和 `JOG` 会刷新运动看门狗。`QUERY`、`ENABLE`、TMC 查询等不会刷新。
看门狗阈值为 1000 ms。运动中超过阈值没有新的控制包时：

```text
motorStop()
communicationWatchdogArmed = false
commandResult = STOPPED
```

由请求包 `flags`（偏移 2）位 0 选择模式，只有 `SET_POS`/`JOG` 解释它：

| `flags` 位 0 | 模式 | 语义 |
| --- | --- | --- |
| `0`（默认） | 流式 | 本次移动纳入看门狗：必须持续发新包，静默 > 1 s 就刹停 |
| `1`（`FF_REQ_LATCH = 0x01`） | 单次锁存 | 本次移动**不**纳入看门狗：发一次即可跑完；此时失联，移动会走到目标才停（软限位照常生效） |

可观测性：`STATUS_V2.reserved` 位 0 = `FF_V2_WATCHDOG_ARMED`。它表示"当前的流式监视模式
是否武装"，由最近一次被接受的 `SET_POS`/`JOG` 决定（流式 → 1，锁存 → 0），并且在一次流式
移动跑完之后**仍然为 1**：改写/清除时机只有 `ENABLE(0)`、`HOME`、看门狗超时和下一次锁存命令
（`STOP` 不清，无害，因为 tick 还要求 `MOVING`）。所以要判断"此刻失联会不会被刹停"必须写成
`ARMED && MOVING`。

选择建议：

- **自动跟焦 / 手轮类连续控制**：流式，持续发最新目标。目标没变也应每 200–500 ms 重发
  （重复同一个 `SET_POS` 是幂等的，且会解除待机），否则一次 >1 s 的行程会被截断。
- **一次性长行程**（"移动到某位置"、标定）：用锁存位，一次发完，不会被 1 s 阈值截断。

已知问题在**上位机侧**：当前 Windows/Dart 版 App 只在目标变化时才发 `SET_POS`
（[lib/main.dart](lib/main.dart) 附近），没有保活定时器，所以任何超过 1 s 的行程都会被
看门狗截断 —— 这正是"控制有时候不灵"的根因。修法是加保活或改用锁存位，固件行为本身
符合契约。真机对照证据见 §9。

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

待机释放扭矩时**不清** `positionTrusted`，这是刻意的例外（不同于 `ENABLE(0)` 会清）。
所以长时间待机 / 人工拧过镜头之后，开环 `pos` 仍被标记可信，必要时用 `HOME` 重新校零。
`TMC_STANDBY`（TMC_SET `key=7`，`1`=开启，`0`=关闭）会写进 NVS 持久化。

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

如果测试在加载阶段就全部失败，报
`Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket upgrade request`,
这是本机环境问题，不是代码问题：全局的 `HTTP_PROXY`/`HTTPS_PROXY` 会把 Dart VM 连接
本地 `flutter_tester` 的 WebSocket 也送去代理。判断特征是所有测试文件一起挂，包括从
未改动过的 `widget_test.dart`。对测试进程清掉代理即可：

```powershell
Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY -ErrorAction SilentlyContinue
$env:NO_PROXY = "127.0.0.1,localhost"
flutter test
```

Python 语法检查：

```powershell
python -m py_compile test\udp_motion_acceptance.py
python -m py_compile test\repro_jog_truncation.py
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

复现"单发 JOG 被 1 s 看门狗截断"（App"走圈"按钮的症状）：

```powershell
python test\repro_jog_truncation.py --host 192.168.4.1 --port 4210 --reps 3
```

该工具严格照抄 App 的发包方式（单发 `JOG` 16000 步 = 5 圈 + 200 ms `QUERY` + 1 s `TMC_QUERY`
轮询），四种模式各走 `--reps` 趟：App 默认 1.2 圈/秒流式、App 滑条 3.0 圈/秒流式、固件默认
2.5 圈/秒流式、以及 `flags = 0x01` 锁存对照。每趟打印"最后运动中 / 首次静止"时刻、截断位置和
原始 200 ms 采样轨迹。**流式必然被截断、锁存必然跑满**（实测 4 模式 × 3 趟：23.5–25.2% /
58.2–60.5% / 42.1–43.5% / 100%），末行给出结论，退出码 0 = 与文档一致。跑完设备停在
`pos = 0`、静止、`ENABLE(0)`。

脚本覆盖 ENABLE、JOG、HOME/STATUS_V2、SET_POS、STOP、反向、软限位、待机唤醒、
通信超时、单次锁存和单发 JOG 的流式/锁存对照，共 9 组。必须连接设备 AP（`FF-XXXXXX`）
并接好电机后运行；没有硬件时只能做语法/编译验证。

脚本开始时会先发一次 `HOME`（软件置零），所以**起始位置不影响结果**：轴停在离 0 很远的
地方也能直接跑。若套件启动时轴仍在运动，第一组就会以一条明确的
`axis was not idle at suite start` 失败，而不是在几组之后报一个看不懂的超时。

该脚本会真实驱动电机（多组长行程往返，单次最长 16000 步 ≈ 5 圈 / 约 2 s），
运行前先确认镜头行程内没有障碍物。

已在 `FF-75A578` 上跑过多轮：最初两轮 7/7，加入单次锁存位和 AP 多客户端改动之后是
8/8，最近一轮 **9/9 全部通过，exit 0**（这一轮刻意先把轴锁存移到 `pos = 20000` 再开跑，
用来验证起始位置无关）。每次固件改动后都重跑，用于确认没有牵连影响。
其中四组结果最能说明问题：

- SET_POS：同一个 `seq` 的 legacy `STATUS` 和 `STATUS_V2` 都在动作结束后报
  `completed`（`pos == target == 32`）。修复前 `STATUS_V2` 会停留在 `accepted`，
  本组即失败。
- 通信超时：请求 19000 步，实际走到 6202 步被看门狗刹停，`result == stopped`，
  且 `target` 被 `motorStop()` 重锚为 6202。该组同时断言 `QUERY` 不刷新看门狗
  （发 `QUERY` 不能续命）和流式移动期间 `STATUS_V2` 的 ARMED 位为 1。
- 单次锁存：同一个 12000 步的锁存 `SET_POS` **只发一次**，静默 1.25 s 后仍在运动并
  最终 `completed`；对照组的流式命令在同样静默下被停在 6202 步、`result == stopped`。
  这一对是"短行程能跑、长行程会被截断"的直接证据。
- 单发 JOG 的流式/锁存对照（就是 App "走圈"按钮走的 `JOG` 路径）：8000 脉冲/秒下走
  16000 步（5 圈），流式单发停在 `pos = 6455` / `result = stopped`，锁存单发跑满
  `pos = 16000` / `result = completed`。截断位置只由"速度 × 1 s"决定，与行程总长无关 ——
  这就是「点一次走 5 圈，走到一半左右就断」的成因，改法见 §10 的 Flutter 侧条目。

`trusted` 会在两种情况下回到 0：上电/烧录后（此时 `pos = 0`），以及
`motorSetEnabled(false)`。后者是刻意的 —— 驱动器不再保持扭矩，开环步数不再可信。
所以 App 每次重新使能后都要重新 HOME，不能假设 `trusted` 会保持。HOME 只做软件
置零，电机不会动。

整轮所有组一起很快失败、且每条都只打印 `FAIL <组名>: timed out` 时，那是 `recv`
超时而非断言失败（`socket.timeout` 的字符串恰好就是 `"timed out"`）。本项目实测
这种情况全部由 Wi-Fi 掉线引起，先确认 `192.168.4.1` 能 ping 通再重跑。

四处容易误改的地方：

- SET_POS 组会同时校验 `STATUS` 和 `STATUS_V2` 对已完成的动作都报 `completed`。
- 通信超时组不能断言 `pos != target`：`motorStop()` 会把 `target` 重锚到停止位置，
  所以停止后 `pos == target` 恒成立。该组判定的是“没有到达请求的 19000 步”
  且 `result == stopped`。
- 单次锁存组的两个 `SET_POS` 必须打上 `flags = 0x01`，忘了就是流式，会在 1 s 后被
  刹停而失败；断言"静默后仍在运动"的等待时间必须 > 1000 ms（当前用 1.25 s），
  但又要小于该行程的运动时长（12000 步 ≈ 1.9 s），否则动作已经结束。
- 单发 JOG 对照组同理，而且它显式下发 `SET_SPEED 8000/20000`（固件默认值，不持久化）：
  速度调低会让流式截断得更早（App 默认 1.2 圈/秒时只走到 3379 步），组里的
  `0 < pos < 16000` 断言就是用来锁住"被截断"这个性质的，不要改成精确步数。

验收时不能只看软件 `pos`。应同时观察电机是否实际转动，并用 TMC 状态判断：

```text
静止通常 TSTEP=65535、STST=1
运动时 TSTEP 应变小、STST 应解除
```

## 10. 当前未完成和下一步

### 首要下一步：主机侧 Wi-Fi 扫描和设备列表

用户希望扫描附近 Wi-Fi 并显示可用跟焦器，连接时不依赖固定 IP。固件侧已完成
（唯一 SSID + `FF_DISCOVER`，见 §6），剩下的都在主机侧：

1. 在 [lib/ff_protocol.dart](lib/ff_protocol.dart) 加入发现命令常量（`0x0B`/`0x84`）
   和 32 字节回包解析。
2. 扫描附近 Wi-Fi，筛出 `FF-` 前缀的 AP 作为候选设备，展示成"可用设备"列表。
3. 连上候选 AP 后**先用** `FF_DISCOVER` 验证，确认对方是本项目固件并拿到
   `device_id`/`mac`/`fw`/`udp_port`，再建立 `MotorLink`；不要再假设
   `192.168.4.1:4210`。
4. 用回包里的 `mac` 和扫描到的 BSSID 交叉校验，确认列表项和控制连接指向同一台板子。
5. Windows 用原生 WLAN API 扫描；不要把 `netsh` 当正式跨平台方案。
6. 广播在开发机上不可靠（主机多条默认路由会让 `255.255.255.255` 走错网卡，见 §6），
   所以 App 侧要能回退到子网广播或单播候选 IP。
7. iOS 受系统限制，普通 App 不能自由读取附近 Wi-Fi 列表。正式 iOS 方案用
   `NEHotspotConfiguration` 连接已知 SSID，再用 UDP 发现包验证。SSID 现在每板唯一，
   多设备场景可以让用户先选 SSID 再连接。

### 固件

- 实现持久化 fault code，而不是当前 `STATUS_V2.fault = 0`。
- ~~评估自动跟焦和手动控制是否需要不同看门狗策略。~~ **已实现**：请求 `flags` 位 0 =
  单次锁存（`FF_REQ_LATCH`），`STATUS_V2.reserved` 位 0 = ARMED 作为可观测性，见 §7。
  固件侧已完成并真机验收，剩下的修改在 App 侧（见下）。
- 增加独立最大减速度和 jerk/S 曲线 profile。
- 接入真实机械限位后扩展 HOME 为自动回零。
- 如硬件允许，增加编码器闭环；开环 `pos` 不能证明机械真实位置。

### Flutter/iOS

- **修长行程被看门狗截断**（"控制有时候不灵"、"点一次走 5 圈走到一半就停"的根因）：
  [lib/ff_protocol.dart](lib/ff_protocol.dart) 的 `setPos()` / `jog()` 只发单包、`flags` 恒 0，
  [lib/main.dart](lib/main.dart) 的 `_jog()`（走步/走圈按钮）发完就不再发，`_onTick()` 也只在
  目标变化时发 `SET_POS`，没有保活。任何超过 1 s 的行程都会在 1.0 s 处被刹停，截断位置
  =速度 × 1 s（实测 5 圈：8000 脉冲/秒 → 6455 步；App 默认 1.2 圈/秒 → 3379 步；加
  `flags = 0x01` → 16000 步跑满）。两种改法：一次性长行程改发 `flags = 0x01` 锁存
  （`setPos`/`jog` 加一个 `latch` 形参，`_jog()` 传 `latch: true`），或在运动未完成期间每
  200–500 ms 重发当前目标。精确改法与实测数字见 [PROTOCOL.md](PROTOCOL.md) §7.2，
  改完用 `test/udp_motion_acceptance.py` 的 `single-shot JOG: streaming vs latched` 组核对。
- 实现 Wi-Fi/设备列表页，把候选设备、发现结果和连接状态都放在这一页。
- 把固定 `192.168.4.1` 替换为设备发现结果。
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
- **协议以 [PROTOCOL.md](PROTOCOL.md) 为准**：改协议/看门狗语义时先改它，再改代码。
- 触碰电机、电流或引脚前先阅读本文和 [CONTROL_ARCHITECTURE.md](<J:/New%20soft%20project/iphone-follow-focus/CONTROL_ARCHITECTURE.md>)。

## 12. 文件归属与协同边界

本仓库由多个 agent/会话并行改动，请按目录认领，避免互相踩：

| 归属 | 路径 | 说明 |
| --- | --- | --- |
| 固件侧 | `firmware/**`、`test/**`、[PROTOCOL.md](PROTOCOL.md) | 协议、运动控制、验收脚本 |
| 上位机侧 | `lib/**`、`ios/**`、`pubspec.yaml` | Flutter / iOS App |
| 共享 | [HANDOFF.md](HANDOFF.md)、[README.md](README.md)、[CONTROL_ARCHITECTURE.md](<J:/New%20soft%20project/iphone-follow-focus/CONTROL_ARCHITECTURE.md>) | 改前先确认没有别人正在同一段落工作 |

协同规则：

- **协议只认 [PROTOCOL.md](PROTOCOL.md)**。上位机照它实现；需要新字段/新语义时，先让固件
  侧在 PROTOCOL.md 写清楚再实现，不要两边各自解读。
- 固件的任何行为变化（新的 `flags` 位、新的回包、看门狗/锁存语义）必须同一次改动里同步
  更新 PROTOCOL.md 和本文 §7，并在真机重跑 `test/udp_motion_acceptance.py`。
- 上位机不要依赖 `STATUS_V2.fault`（恒 0）、不要假设未定义位为 0、不要对单包回复"等第二
  个包"（见 §6 回包数量表）。
- 同一时刻只允许一个控制器发命令（AP 可接 4 台客户端，但控制权不共享）。
- 固件改动后 App 无需重新协商协议版本；但如果新增了字段，App 必须能在字段为 0 时退化工作。
