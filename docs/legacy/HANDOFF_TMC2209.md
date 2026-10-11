# iphone-follow-focus 项目交付文档

更新时间：2026-09-26

**固件 1.1.0 已加入 StallGuard4 自动识别行程。当前 Swift 镜头管理见 §13；固件接口及 Mac App 对接步骤见 §14 和 [PROTOCOL.md §14](PROTOCOL.md#14-stallguard4-自动镜头行程固件-110)。实际镜头行程仍待装镜验证。**

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

功能层（协议/链路/镜头/对齐/会话）全在 Swift 的 `ios/FollowFocusCore` 里，
Flutter 只是它的界面；Windows 桌面入口已移除。完整 iOS LiDAR 功能需要
macOS + Xcode + iPhone Pro 真机。

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
| 上位机设备发现 + 设备列表页 | 已实现（`FfDiscovery` + `discoverBoards` + 设备页），控制目标改为来自发现结果，见 §6 设备发现 |
| 镜头管理 + 行程标定 + 单侧对齐 | 已实现（功能层 `LensStore` + 镜头页 + 三步流程），见 §8 镜头流程 |
| 主机侧 Wi-Fi 扫描和列表 | iOS 做不到（系统限制），见 §10 |
| **功能层全在 Swift** | 已迁完，`ios/FollowFocusCore`；UI 只经 `ff.core` 通道，见 §13 |
| Swift 逻辑 + 会话测试 | `swift test` 全套通过，不需要模拟器 |
| Flutter UI 测试 | `flutter test` 全套通过，用伪造核心驱动，不碰平台通道 |
| 通信失联停止 | 已实现，控制包超时 1000 ms；请求 `flags` 位 0 = 单次锁存可豁免，见 §7 |
| 手动 HOME / `positionTrusted` | 已实现 |
| StallGuard4 双端自动行程 | 固件 1.1.0 与 iOS App 已接入；实镜标定待验，见 §14 |
| 固件协议契约文档 | [PROTOCOL.md](PROTOCOL.md)，wire 层唯一权威来源 |
| 自动化 UDP 验收脚本 | 已完成，真机 9/9 通过（含单发 JOG 流式/锁存对照） |
| iOS 真机部署（macOS） | 已打通，实测 iPhone 15 Pro Max / iOS 17.5，见 §8.1 |
| iOS LiDAR 功能 | 代码存在；部署链路已打通，功能本身仍待在真机验证 |

最近提交（不含本文档本次改动所在的提交，避免自引用导致的哈希失效）：

```text
47c98f5 chore: prepare project for public repository
60b171b fix: enable lidar ios deployment target
f28e153 refactor: split lidar native interface
5627fe5 docs: warn that jog.py pos N is a move, not a query
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
| TMC DIAG 堵转/故障输出 | 11，输入 |
| USB D-/D+ | 19/20 |

TMC2209 实测可用接线：

```text
GPIO12 -> TMC 模块标记为 RX 的引脚
GPIO11 <- TMC 模块 DIAG 引脚（新增；自动识别行程必需）
模块 TX 不接
VDD/VIO = 3.3 V
VM/VS 使用电机电源
ESP32 和驱动器共地
先上 VM，再插 USB
```

不要根据参考工程的引脚名称直接改线。参考工程
`J:\softwareProject\esp32s3-tb6600-stepper` 是 DevKitC，使用 GPIO17，和本项目
Super Mini 不同。本项目已实测 `r12 t12`、115200、地址 0、TMC2209 version `0x21`。
固件在标定前通过 UART 设置并验证驱动参数；标定运动中只监视 DIAG 脉冲，
停止运动后才读取 UART 诊断寄存器。GPIO11 未连接时，自动标定会在运动前拒绝启动。
手动标定不依赖 DIAG。

不要重新引入 `neopixelWrite`。旧版 RMT API 和 IDF5/RMT 资源可能冲突，当前 WS2812
没有使用。

## 4. 固件

入口和主要文件：

- [firmware/src/main.cpp](<firmware/src/main.cpp>)：
  SoftAP、DNS、HTTP、UDP 初始化和主循环。
- [firmware/src/motor.cpp](<firmware/src/motor.cpp>)：
  硬件定时器脉冲、运动规划、TMC2209 UART、软限位、待机和看门狗。
- [firmware/include/motor.h](<firmware/include/motor.h>)：
  运动公共接口。
- [firmware/src/protocol.cpp](<firmware/src/protocol.cpp>)：
  UDP 命令解析和状态回复。
- [firmware/include/protocol.h](<firmware/include/protocol.h>)：
  协议常量和数据结构。
- [firmware/src/device.cpp](firmware/src/device.cpp) 和
  [firmware/include/device.h](firmware/include/device.h)：设备身份
  （AP 接口 MAC → `FF-XXXXXX`）和固件版本号，SSID 与发现回包共用同一来源。
- [firmware/platformio.ini](<firmware/platformio.ini>)：
  PlatformIO `s3mini` 环境。

固件启动：

1. `motorBegin()` 初始化 GPIO、参数和硬件定时器。
2. OLED 启动；`WiFi.mode(WIFI_AP)` → `deviceBegin()` → `WiFi.softAP(deviceId(), ...)`。
   `deviceBegin()` 必须在 `mode()` 之后、`softAP()` 之前，因为 SSID 就是 `deviceId()`。
3. UDP 端口 `4210` 初始化。
4. 首次进入 `loop()` 时尝试 TMC UART，避免 UART 异常阻塞热点和按键。
5. 主循环处理 DNS、HTTP、UDP、待机和按键。

### 4.1 构建与刷写（macOS 现在也能做）

2026-09-29 起本机（macOS）就能编译和刷写，不必再借 Windows：

```bash
python3 -m venv ~/.pio-venv && ~/.pio-venv/bin/pip install -U platformio   # 只需一次
~/.pio-venv/bin/pio run -d firmware            # 编译（首次约 2 分钟，含下载工具链）
~/.pio-venv/bin/pio run -d firmware -t upload  # 刷写，板子在 /dev/cu.usbmodem*
```

`pio upload` 会**独占串口**：抓日志的 `tool/serial_tap.py` 必须先停掉，否则刷不进。

### 4.2 TMC 寄存器读的重试与串口诊断（2026-09-29）

半双工单线在 Wi-Fi 抢占下会偶发丢回包，真机标定起手读 `DRV_STATUS`/`IFCNT` 曾大约
一半的尝试拿到 `0xFFFFFFFF`，整轮标定因此被判 `CAL_UART = 3`。现在：

- `tmcReadReg` 4 次尝试、窗口 15 ms，**每次失败后排空 RX 再等 2 ms**（晚到的回包会
  污染下一轮，这是连续两次都失败的主因）；四次全败才返回失败并打印
  `tmc read fail addr=0xNN (total=N)`。
- 标定的"写九个寄存器 + IFCNT +9 校验"整块最多重来 3 次（丢写和读计数失败都靠它兜），
  仍不成立才 `CAL_UART`。
- 串口 TMC 行末尾新增 `drv_valid=`（DRV_STATUS 这次读成功了吗）和 `readfail=`（累计
  失败次数）。**协议没有变**：线上 `drv_status` 读失败仍按 0 发，"真读到 0"和"读失败"
  在线上依旧分不开 —— 要区分就看串口这一行。
- **堵转后那次 DRV_STATUS 读失败不再作废整轮**：DIAG 已经响了，UART 只是"顺便问一句
  有没有驱动故障"。读不到就记账（`calFaultChecksSkipped`）继续扫描，**发布 state=5 之前
  再补问一次**（那时电机已停、总线空闲，最容易问通）；补问读到故障位才 `CAL_DRIVER`，
  仍读不到才放行（串口留 `cal final drv check drv=0xFFFFFFFF` 痕迹）。真机上 6 次标定
  有 4 次死在这一读上，这条是成功率的主要来源。
- 串口 TMC 行再加 `diag=<上升沿累计>/<当前电平>`：静止时边沿数若还在涨 = 纯噪声；
  只有电机运动时涨 = 接错脚/与步进线串扰；两边都不涨而标定仍一动就停 = 芯片真在报。


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

上位机用 UDP，不建立 TCP 连接。Swift 功能层的 `MotorLink` 在
`ios/FollowFocusCore/Sources/FollowFocusCore/MotorLink.swift`；控制目标来自发现结果，
不再写死 `192.168.4.1:4210`（见 §6 设备发现）。

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

历史真机结果（固件 1.0.0）：`FF-75A578  fw 1.0.0  udp 4210  mac 92:DA:72:75:A5:78  at 192.168.4.1`，
且只收到 1 个数据包。

开发机排查提示：主机存在多条默认路由时（本项目机器上有以太网 + VPN），
受限广播 `255.255.255.255` 会跟随**默认路由**从别的网卡出去，永远到不了板子，
表现就是"单播能通、广播无响应"。所以 `discover.py` 先发一次不绑定的包，再逐个
绑定本机 IPv4 各发一次（等价于 SSDP 的做法），也支持直接发子网广播
`--target 192.168.4.255`。板子本身不需要为此做任何改动。

**上位机实现**：Swift 功能层的 `FfDiscovery`（回包解析，`FfProtocol.swift`）+
`discoverBoards()`（`Discovery.swift`），UI 在
[lib/device_page.dart](lib/device_page.dart)（只是列表和指引）。行为与 `discover.py` 一致：同一个
socket 重复发几次再等超时收包，按 `device_id` 去重。

**iOS 上有三条硬限制，决定了这里的做法**：

1. **不能扫描 Wi-Fi 列表**。iOS 没有通用扫描 API，只有 `NEHotspotHelper`，需
   Apple 单独审批且明确禁用于配件场景。所以 App 列的是**能应答发现包的板子**，
   不是周围的热点。
2. **不能在 App 内连 Wi-Fi**（免费个人团队）。`NEHotspotConfigurationManager`
   需要 Hotspot Configuration entitlement，**免费账号拿不到**（当前 profile 只有
   `application-id`/`team-id`/`get-task-allow`/`keychain-access-groups`）。
   所以热点要在 设置 → 无线局域网 手动切，App 里给指引。
3. **不能用广播**（含子网广播 `192.168.4.255`）。缺 multicast entitlement，实测
   报 `errno 13`（见 §8.1）。所以 `discoverBoards()` 默认**只单播** SoftAP 地址
   （`targets` 保留广播入口，但 iOS 上用不了）。

好消息是这三条不挡功能：板子是 SoftAP、地址固定，**单播就够**；而回包的**源地址
就是设备 IP**，`udp_port` 也在回包里，所以 `FfDiscovery` 一次就拿到了建链需要的
全部信息（`MotorLink.host` / `port` 不再写死 `192.168.4.1:4210`）。

设备热点名和 `device_id` 是同一份数据（都取自 AP 接口 MAC），所以看到
`FF-75A578` 就知道该连哪个热点。

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

**上位机侧的保活（曾是"控制有时候不灵"的根因）**：`QUERY` 不算控制包，
只有 `SET_POS`/`JOG` 会重置 `lastControlPacketMs`。所以"目标没变"不等于"不用发"，
一次 > 1 s 的行程会在中途被刹停。

- ✅ **已修（`SET_POS`）**：`FollowFocusSession.tick` 在 `state.moving` 且距上次控制包
  > 400 ms 时重发当前目标。`SET_POS` 是幂等的，重发既能保活又顺带解除待机。
  测试 `testLongMoveKeepsFeedingTheWatchdog` 用假固件的"运动停在半路"验证；
  把这段保活删掉该测试就会失败。
- ⏳ **未修（`JOG`）**：JOG 是**相对量**，重发等于多走一段，不能靠保活。
  长 JOG（例如"走圈"输入 2 圈 = 12800 步，> 1 s）仍会被 1 s 阈值截断。
  可选修法见下，**这是安全性相关的取舍，改之前要确认**：
  1. 给一次性手动 JOG 带 `FF_REQ_LATCH`（固件文档里对"一次性长行程"的正解），
     代价是失联时它会把这一段走完才停；
  2. 把长 JOG 改写成绝对 `SET_POS`（当前位置 + delta），代价是丢掉固件
     "从当前位置精确走 N 脉冲" 的语义 —— `state.pos` 有 200 ms 的陈旧度。

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

## 8. Flutter UI

入口：[lib/main.dart](lib/main.dart)。**UI 里没有控制逻辑** —— 全部状态来自
`ff.core` 的快照，全部动作是 `ff.core` 的方法调用，见 §13。

启动（只需要模拟器或真机，没有桌面端）：

```bash
flutter pub get
flutter run -d <device>      # 模拟器没有 LiDAR，距离会一直显示 --，其余功能可测
```

界面点击“连接电机”后，功能层才创建 UDP socket，并发送速度、待机参数、ENABLE、QUERY、
TMC_QUERY；LiDAR 由原生采集直连功能层。iOS 真机部署（签名、profile/release、
`flutter attach`）见 §8.1。

Flutter 已有：

- 手动步数/圈数 JOG；
- 滑条绝对目标；
- 自动跟焦状态和死区；
- 停机闩锁，防止自动模式立即覆盖 STOP；
- 软限位预检；
- TMC 诊断；
- HOME 和 `positionTrusted`；
- 镜头管理：启动进镜头选择页（[lib/lens_page.dart](lib/lens_page.dart)），每个镜头单独保存
  行程标定、变远方向和距离标定表，持久化到沙盒的
  `Library/Application Support/iphone_follow_focus/lenses.json`（iOS 上 `%APPDATA%` 不存在）；
- 跟焦前的三步：新镜头手动标定行程 → 单侧对齐（把当前位置认成焦距最近点）→ 选变远方向，
  然后才进跟焦；行程/方向约束软限位，避免拧反或超出标定行程。

镜头模型与存储、距离映射、电机换算、以及上面全部控制逻辑，都在 Swift 功能层
（`ios/FollowFocusCore`）里，见 §13。Dart 侧的对应文件已删除。

### 镜头流程（上位机）

```text
启动 → 镜头选择页 → 选/新建镜头
  ├ 未标定行程：① 标定行程（手动转到两端，记 A/B，两点距离=行程）
  ├ 已标定行程：② 单侧对齐（自由微调到最近对焦 → 确认最近点 → 选变远方向）
  └ ③ 跟焦（现有页面；软限位 = 最近点 + 变远方向 × 行程）
```

- “焦距最近点”是**会话量**：步进电机开环、掉电丢绝对位置，所以每次进入都要重新对齐，
  不持久化；行程长度和变远方向是物理属性，持久化。
- 距离标定表存的是标定当次会话的绝对步数，对齐后由 `lutRebaseDelta()` 整体平移到本次
  会话坐标系；因此 `SET_LIMITS` 只由“行程 + 对齐”决定，不再由距离标定表决定。
- 行程标定是防误触的：标过之后要长按“重新标定行程”并确认才会清空。HOME（软件置零）
  会作废对齐，需要重新对齐。

### 8.1 iOS 真机部署（macOS）

本仓库只在 macOS 上开发（功能层是 Swift Package，UI 只跑 iOS）。本节记录实测可用的
流程和坑。路径为 `/Users/macos/OLF-OpenLidarFocus`。

本文写作时的环境与实测结果：

| 项 | 值 |
| --- | --- |
| Flutter | 3.47.4 stable（`/Users/macos/flutter`） |
| Xcode | 16.4 (16F6) |
| 真机 | iPhone 15 Pro Max，iOS 17.5，UDID `00008130-001C2DE900C1401C` |
| 签名团队 | `WB8RFWDPG4`（Apple Development: ndpyzwy@163.com） |
| Bundle ID | `com.ndpyz.iphoneFollowFocus` |
| 部署目标 | iOS 15.4 |

前提：Xcode 已登录 Apple ID（免费账号即可），且 Mac 已信任该设备。

**`ios/Runner.xcodeproj` 原本没有 `DEVELOPMENT_TEAM`，真机部署必然签不过。** 已为 Runner
target 的 Debug/Release/Profile 三个配置补上，等价于在 Xcode「Signing & Capabilities」里
勾选 Team 的产物：

```text
CODE_SIGN_STYLE = Automatic;
DEVELOPMENT_TEAM = WB8RFWDPG4;
```

换人换账号时把 `DEVELOPMENT_TEAM` 改成自己的即可。CocoaPods **不需要**：本工程没有 pod
依赖，`LidarPlugin.swift` 直接放在 `ios/Runner/` 由 `AppDelegate` 注册，构建会跳过 CocoaPods
（本机也确实没装）。

#### debug / profile / release 的选择

debug 版是 JIT，必须由 Flutter 工具链喂代码，**脱离工具链从桌面点开始终失败**，引擎会直接
拒绝创建 FlutterEngine：

```text
Cannot create a FlutterEngine instance in debug mode without Flutter tooling or Xcode.

To launch in debug mode in iOS 14+, run flutter run from Flutter tools, run from an IDE with a Flutter
IDE plugin or run the iOS project from Xcode.
Alternatively profile and release mode apps can be launched from the home screen.
```

| 需求 | 模式 | 做法 |
| --- | --- | --- |
| 真机调试（热重载、断点） | debug | `flutter run -d <UDID>` |
| **从桌面点开** + 仍能看日志/热重载 | profile | `flutter build ios --profile` 后安装 |
| 性能/最终交付 | release | `flutter build ios --release` 后安装 |

需要在手机上直接点开就用 **profile**：AOT 编译能从桌面启动，同时保留 VM Service。实测产物
release 16.6 MB、profile 25.0 MB。

构建并安装到已连接设备：

```bash
xcrun devicectl list devices        # 查 UDID
flutter build ios --profile         # 产物 build/ios/iphoneos/Runner.app
xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
```

#### App 版本号（每次改动都要动）

版本号的唯一来源是 [pubspec.yaml](pubspec.yaml) 的 `version:`（`<semver>+<build>`）。
iOS 构建把它写进 `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`，
iOS 壳再从 `Bundle.main` 读出来放进快照（`app_version`），主界面标题下方直接显示
（形如 `v1.1.0+2`）。**改了行为就把这一行 bump 一次**：版本没变，装到手机上就分不清
是不是新版。约定：普通改动 `+n` 加一，功能或修 bug 提升前面的数字。网页预览
（`tool/ui_preview.sh`）显示的是 `v0.0.0+demo`，不是真机版本。

#### 冷启动重连与“链路真的通”

两个都会误导排查的问题（2026-09-29 真机上踩到）：

- **`connected` 只代表本地 socket bind 成功。** 手机掉出板子热点、App 刚从后台醒来还没发包、
  板子重启，它照样是 true；`enabled/standby/uartOk` 更是“收到过一次就永不失效”。
  于是顶栏会显示 `EN SLP UART`，实际一个包都不通，把人带去查 UART。
  现在快照里多了 `link_alive`（socket 开着 **且** 1.5 s 内收到过状态回包，
  见 `kLinkAliveWindow`），顶栏第三种状态是橙色的“`FF-XXXXXX · 失去回包 42s`”。
  判断“现在通不通”只能用 `link_alive`（Dart 侧 `FfState.linkAlive`），不要再看 `connected`。
- **冷启动后不用重新扫描了。** 选用过的板子（`device_id`/host/port/固件版本）记在
  `UserDefaults`（`DeviceMemo`，§13 的功能层里，Foundation 自带、不引新依赖），
  下次启动自动认回并走同一条 `openLinkOnQueue` 连接 —— 注意这**和手动点“连接电机”
  一样会 ENABLE(1)**，线圈会通电；所以只在有存档时做一次，且位置/对齐状态一律不恢复。

#### 依赖与构建的两个坑
- `flutter build ios` **不会**因为 `pubspec.lock` 变了就重跑 `pub get`：它只看
  `pubspec.yaml` 是否比 `.dart_tool/package_config.json` 新。手动还原或切换过 lock
  之后要显式跑一次 `flutter pub get`，否则编译仍沿用旧的解析结果（产物和 lock 不一致）。
- 本机 `~/.zshrc` 里设了 `PUB_HOSTED_URL=https://pub.flutter-io.cn` 走国内镜像，而
  非交互 shell（脚本/agent）不会读它，`pub get` 会改走官方源并把 lock 里的 `url:`
  整体改写。要在脚本里复现镜像解析，显式带上 `PUB_HOSTED_URL` 与
  `FLUTTER_STORAGE_BASE_URL`。

#### `flutter attach` 必须先起监听再启动 App

`flutter attach` 靠监听 App **启动那一刻**发出的 VM Service 广播来连接。App 已经跑起来再
attach 会一直停在 `Waiting for a connection from Flutter on <device>`。正确顺序是先 attach、
再重启手机上的 App：

```bash
flutter attach -d <UDID>   # 看到 Waiting for a connection 后，
                           # 在手机上杀掉 App 再点开一次
```

实测接上后 DevTools 与热重载均可用。

#### 三个坑

1. **别再跑不带 `--profile`/`--release` 的 `flutter run`**：它会用 debug 版覆盖已安装的
   profile/release 版，桌面图标随即报上面那段 `Cannot create a FlutterEngine`。恢复就是重新
   build + install。
2. **刚装完立刻启动可能被拒**，报 `... has an invalid code signature, inadequate entitlements
   or its profile has not been explicitly trusted by the user`。这是 iOS 装完后重新校验 profile
   的短暂窗口，等 20–30 s 重试即可，**不是签名坏了** —— 用
   `codesign --verify --deep --strict Runner.app` 通过、且 entitlements 里的
   `application-identifier` 与 `embedded.mobileprovision` 一致即可确认。**设备锁屏**也会导致
   完全相同的报错，先解锁再试。
3. **免费账号的 provisioning profile 只有 7 天有效期**（本文实测签发后到期日 2026-09-30），
   过期后桌面图标点不开，重新 build + install 即可。付费账号可到 1 年。

#### 已知运行期问题：未连电机时刷屏

手机没连电机 AP（`192.168.4.1`）时会持续打印：

```text
Unhandled Exception: SocketException: Send failed (OS Error: No route to host, errno = 65), address = 0.0.0.0, port = 0
#2  MotorLink.send (FollowFocusCore/MotorLink.swift)
#3  MotorLink.enable
#4  FollowFocusSession.connect
```

（Swift 侧这类错误走 `MotorLink.onSocketError`，界面上看"套接字错误"那一行，
不会像 Dart 版那样抛成未捕获异常。）

`address = 0.0.0.0, port = 0` 是**本地 socket 端点**（`bind(anyIPv4, 0)`），不是目标地址，别被
它误导：目标仍是 `192.168.4.1:4210`，这条错误只是在说"手机不在电机那个网段上"。

机制：`MotorLink.open()` 里的 `sock.listen((event) {...})` **没有注册 `onError`**，UDP 发送
失败是以**异步 stream 错误**抛出的，所以 `_connect()` 外层的 `try/catch` 拦不住（它只能拦同步
throw），会带着"触发发送那一行"的调用栈变成 Unhandled Exception。修法是在 `listen` 加
`onError` 兜底（一处即可覆盖所有调用方），并把 `onPressed: _connect` 丢掉的 Future 收好。
（已修：`listen` 带 `onError`，"功能可用性诊断"面板会把最近的套接字错误显示出来。）

#### 已知运行期问题：iOS 上 App 完全没网（`errno 65`）

**症状**：App 内 UDP 收发全无（诊断面板「UDP 状态回包」一直"尚未收到"、走步无反应），
但**同一时刻 Safari 能打开 `http://192.168.4.1/`**，信号满格。

**根因不是代码，是 iOS 的本地网络权限数据库损坏**：设置 → 隐私与安全性 → 本地网络里
开关显示"已授权"，但系统实际按"拒绝"执行。表现是该 App 的**所有**出站连接 —— UDP/TCP、
局域网、公网、**甚至发往本机自己的地址** —— 一律 `No route to host (errno = 65)`。

**判定方法**（不用改代码就能区分），App 内分别对这几类目标发包：

| 目标 | 权限被拦时的结果 |
| --- | --- |
| 同网段 `192.168.4.1` | `errno 65` |
| 本机自己的地址（不经过 ARP/路由） | 也是 `errno 65` |
| 公网 `8.8.8.8:53` / `1.1.1.1:443` | 也是 `errno 65` |
| Safari 同一时刻访问同样地址 | 正常 |

"连发给自己都失败 + Safari 正常"这个组合，就排除了选路、网卡、蜂窝/VPN 出口，
只剩"按 App 拦截"。

**修复**：设置 → 通用 → 传输或还原 iPhone → 还原 → **还原位置与隐私**，重启后重新授权。
本文实测修复后：`probeTx=32 rx=396`、`errno=null`、`tcp 192.168.4.1:80 OK`、固件回显正常。

**已排除的假设**（都实测过，都不是原因）：

- **出口网卡选错**：显式 `bind` 到 `192.168.4.4` 仍失败。而且 Apple 明确不建议去猜本机 IP
  （"Don't Try to Get the Device's IP Address"），所以 `open()` 保持 `anyIPv4` 通配绑定，
  由内核按目标挑出口。
- **蜂窝数据抢占**：关蜂窝、开飞行模式只留 Wi-Fi，一样失败。
- **长连接 socket 坏掉**：每次新建 socket 同样失败。
- **代理/VPN 工具残留**：关掉并删除 VPN 配置、重启手机后仍然失败。
  但如果机器上装了 Shadowrocket 这类工具，**先关掉再排查**，否则现象会互相叠加。
- **`NSLocalNetworkUsageDescription` 缺失**：已确认该键进了构建产物的 `Info.plist`。

**注意**：重装 App 会清掉权限记录，需要重新弹窗授权；授权后若仍不通，先试上面的"还原位置与隐私"。

**另一个独立限制**：往广播地址（`192.168.4.255` / `255.255.255.255`）发送会报
`Permission denied (errno = 13)` —— iOS 的**组播需要单独的
`com.apple.developer.networking.multicast` entitlement**。所以 §10 里计划的"用 UDP 广播发现
设备"在 iOS 上必须先申请这个权限，否则走不通。

## 9. 测试和验收

两套测试，各测各的层：

```bash
cd ios/FollowFocusCore && swift test    # 74 项：协议/链路/镜头/对齐/会话逻辑
flutter test                            # 25 项：UI 组件（伪造核心驱动，不碰平台通道）
```

控制逻辑的测试都在 `swift test` 里（macOS 原生跑，约 6 秒，不需要模拟器）。
`flutter test` 只断言"UI 发出了什么命令"，不断言限位/死区/相位 —— 那些不该在 UI 里。

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

### 主机侧设备发现和设备列表

用户希望扫描附近 Wi-Fi 并显示可用跟焦器，连接时不依赖固定 IP。固件侧已完成
（唯一 SSID + `FF_DISCOVER`，见 §6）。**已完成**：

1. ~~加入发现命令常量（`0x0B`/`0x84`）
   和 32 字节回包解析。~~ 已加：`kFfDiscover`/`kFfDiscoverReply` + `FfDiscovery`
   （Swift 功能层 `FfProtocol.swift`）。
2. ~~连上候选 AP 后**先用** `FF_DISCOVER` 验证，确认对方是本项目固件并拿到
   `device_id`/`mac`/`fw`/`udp_port`，再建立 `MotorLink`；不要再假设
   `192.168.4.1:4210`。~~ 已完成：`discoverBoards()` 负责探测，
   `MotorLink.useDevice()` 用回包的源地址和 `udp_port` 建链，`host` 改为可空、
   不再有写死默认值。
3. ~~实现 Wi-Fi/设备列表页，把候选设备、发现结果和连接状态都放在这一页。~~
   已完成：[lib/device_page.dart](lib/device_page.dart)。
4. ~~广播不可靠，App 侧要能回退到子网广播或单播候选 IP。~~ 已完成：
   `discoverBoards()` 默认单播，`targets` 可传广播地址。

**仍未做**：

5. **扫 Wi-Fi 列表在 iOS 上做不到**（系统没有通用扫描 API，`NEHotspotHelper` 需
   Apple 审批且禁用于配件场景）。设备页因此列出的是"能应答发现包的板子"，热点仍要
   手动在系统里切。若以后要一步到位，需要**付费**开发者账号才能用
   `NEHotspotConfiguration`（免费个人团队没有 Hotspot Configuration entitlement），
   届时应做成"记住用过的 SSID + 点击直连"，并保留手动切换作为回退。
6. ~~**Windows 桌面端**：用原生 WLAN API 扫描并连接。~~ **已放弃**：改为
   "Swift 功能层 + Flutter UI"，Windows 入口已删除（见 §13）。原因是功能层要能
   单独测试和被别的界面复用，桌面端那套 UDP/协议实现会成为第二份真相。
7. 多台板子同时在场时的选择体验：现在只在"恰好发现一台"时自动选中，多台会打开
   设备页。真机只验证过单台。

### 固件

- 实现持久化 fault code，而不是当前 `STATUS_V2.fault = 0`。
- ~~评估自动跟焦和手动控制是否需要不同看门狗策略。~~ **已实现**：请求 `flags` 位 0 =
  单次锁存（`FF_REQ_LATCH`），`STATUS_V2.reserved` 位 0 = ARMED 作为可观测性，见 §7。
  固件侧已完成并真机验收，剩下的修改在 App 侧（见下）。
- 增加独立最大减速度和 jerk/S 曲线 profile。
- 接入真实机械限位后扩展 HOME 为自动回零。
- 如硬件允许，增加编码器闭环；开环 `pos` 不能证明机械真实位置。

### Flutter/iOS

- ~~**长行程被看门狗截断**（"控制有时候不灵"、"点一次走 5 圈走到一半就停"的根因）。~~
  **`SET_POS` 已修**：`FollowFocusSession.tick` 在运动期间每 > 400 ms 重发当前目标
  （幂等），测试 `testLongMoveKeepsFeedingTheWatchdog` 钉住。
  **`JOG` 未修**：JOG 是相对量，重发等于多走一段，不能靠保活；"走圈"输入 1 圈以上
  （> 1 s 行程）仍会被截断。两个候选修法（锁存 / 改写成绝对 `SET_POS`）都是
  **安全性相关的取舍**，见 [PROTOCOL.md](PROTOCOL.md) §7.2，改前要确认。
- ~~实现 Wi-Fi/设备列表页，把候选设备、发现结果和连接状态都放在这一页。~~
  已完成，见 §10「主机侧设备发现和设备列表」与 [lib/device_page.dart](lib/device_page.dart)。
- ~~把固定 `192.168.4.1` 替换为设备发现结果。~~ 已完成：`MotorLink.host`
  改为可空、由 `useDevice()` 从发现回包填充，端口用回包的 `udp_port`。
- 完善 HOME 提示，明确它是软件校零而非机械回零。
- ~~修未连电机时刷屏的未捕获 `SocketException`~~（见 §8.1）：已在 `MotorLink.open()` 的
  `sock.listen` 加 `onError` 兜底，并把 `onPressed: _connect` 丢掉的 Future 收好。
- **iOS 真机 UDP 不通的根因是本地网络权限数据库损坏**，与代码无关，修法见 §8.1
  "已知运行期问题：iOS 上 App 完全没网"。若换新手机再遇到同样症状，直接按那节排查。
- **UDP 广播发现在 iOS 上需要 `com.apple.developer.networking.multicast` entitlement**
  （见 §8.1 末），要做的设备发现功能得先补这个权限。
- **iOS 真机部署链路已打通**（见 §8.1：`DEVELOPMENT_TEAM`、profile/release 可桌面启动、
  `flutter attach` 用法、7 天 profile 有效期）。剩下的是把 LiDAR 目标跟踪、镜头标定和
  丢目标策略在真机上验证并标定。
- 再开发正式 Swift/iOS 底层和 UI。

## 11. 修改规则

- 不要重新引入 FastAccelStepper/RMT 作为运动后端。
- 不要把 `pos == target` 单独当成机械运动完成证明。
- 不要把手机端每个 LiDAR 采样变成必须执行的离散轨迹点。
- 不要重新引入 `neopixelWrite`。
- 修改 STEP 输出时，必须保持“实际 STEP 脉冲完成后才推进 `currentPos`”。
- 修改协议时保留旧 12 字节客户端兼容，新增字段优先使用新命令/新包。
- **协议以 [PROTOCOL.md](PROTOCOL.md) 为准**：改协议/看门狗语义时先改它，再改代码。
- 触碰电机、电流或引脚前先阅读本文和 [CONTROL_ARCHITECTURE.md](<CONTROL_ARCHITECTURE.md>)。

## 12. 文件归属与协同边界

本仓库由多个 agent/会话并行改动，请按目录认领，避免互相踩：

| 归属 | 路径 | 说明 |
| --- | --- | --- |
| 固件侧 | `firmware/**`、`test/**`、[PROTOCOL.md](PROTOCOL.md) | 协议、运动控制、验收脚本 |
| **功能层（Swift）** | `ios/FollowFocusCore/**` | 协议/链路/镜头/对齐/会话编排。**不允许 import Flutter/UIKit** |
| **UI 层（Flutter）** | `lib/**` | Flutter UI。只通过 `ff.core` channel 读写功能层，见 §13 和 [UI_DEV.md](UI_DEV.md) |
| iOS 壳 | `ios/Runner/**`、`pubspec.yaml` | 插件注册、LiDAR 采集、平台视图 |
| 共享 | [HANDOFF.md](HANDOFF.md)、[README.md](README.md)、[UI_DEV.md](UI_DEV.md)、[CONTROL_ARCHITECTURE.md](<CONTROL_ARCHITECTURE.md>) | 改前先确认没有别人正在同一段落工作 |

协同规则：

- **协议只认 [PROTOCOL.md](PROTOCOL.md)**。上位机照它实现；需要新字段/新语义时，先让固件
  侧在 PROTOCOL.md 写清楚再实现，不要两边各自解读。
- 固件的任何行为变化（新的 `flags` 位、新的回包、看门狗/锁存语义）必须同一次改动里同步
  更新 PROTOCOL.md 和本文 §7，并在真机重跑 `test/udp_motion_acceptance.py`。
- 上位机不要依赖 `STATUS_V2.fault`（恒 0）、不要假设未定义位为 0、不要对单包回复"等第二
  个包"（见 §6 回包数量表）。
- 同一时刻只允许一个控制器发命令（AP 可接 4 台客户端，但控制权不共享）。
- 固件改动后 App 无需重新协商协议版本；但如果新增了字段，App 必须能在字段为 0 时退化工作。

## 13. Swift 功能层

### 目标

功能层全部在 Swift 底层实现，和 UI 拆开；UI 由专人编辑，只通过一条 channel 读写功能层。
UI 不用 Flutter 的话也能换成 SwiftUI，功能层不动。

### 目录职责

```text
ios/FollowFocusCore/            ← 功能层（本地 Swift Package，只有 Foundation 依赖）
  Sources/FollowFocusCore/
    FfProtocol.swift            12/16/22/32 字节包编解码、序号规则
    MotorCal.swift              步/圈/脉冲换算、软限位、峰值速度
    LensLut.swift               1/距离 插值、细分换算、距离滤波
    Lens.swift                  镜头模型、对齐区间、方向推断、重锚、存档
    UdpSocket.swift             BSD UDP（广播、非阻塞、poll）
    MotorLink.swift             序号、探测回显、状态回调
    Discovery.swift             设备发现（单播 + 去重 + 超时）
    FollowFocusSession.swift    20ms 控制 tick、使能自愈、停机闩锁、
                                自动跟焦死区、相位机、软限位下发
    SnapshotJson.swift          快照 → channel map（键名契约，有测试钉住）
ios/Runner/FollowFocusCorePlugin.swift   ff.core 方法表 + 事件推送
lib/                            ← UI 层
  ff_core.dart                  ff.core 客户端（只有字段搬运）
  main.dart                     跟焦页（纯渲染）
  lens_page.dart device_page.dart  镜头选择 / 设备列表
  ff_core_demo.dart             只在 web 上用的演示核心（假数据，见 UI_DEV.md）
```

边界由编译器强制：`FollowFocusCore` 不能 import Flutter —— 写不进去，不是靠约定。
UI 侧任何控制逻辑都应当移进 `FollowFocusSession`，不要在 Dart 里复制一份。

### 跑测试

```bash
cd ios/FollowFocusCore && swift test        # 全部逻辑测试，约 4 秒，不需要模拟器
```

在 macOS 原生跑，比 `xcodebuild test` 快几十倍；链路和会话测试在 loopback 上起一个
假板子（迷你固件模拟器）走**真实** UDP，不需要接硬件。容器/桥层的测试再走
`xcodebuild test`（`ios/RunnerTests/`）。

**只改 UI 时**不用模拟器也不用真机：`tool/ui_preview.sh` 起 web 预览，`flutter test`
跑 UI 测试。流程和边界见 [UI_DEV.md](UI_DEV.md)。

### 迁移状态

| 部分 | 状态 |
| --- | --- |
| 协议编解码、电机换算、距离表、镜头模型与存档 | ✅ 已迁，测试已搬 |
| UDP 链路、设备发现 | ✅ 已迁，有假板子端到端测试 |
| 会话编排（tick/使能自愈/停机闩锁/自动跟焦/相位机/软限位） | ✅ 已迁，有迷你固件模拟器测试 |
| `ff.core` channel（方法表 + 20Hz 状态快照） | ✅ 已做，见下 |
| Flutter UI 切到 channel、删除 Dart 功能层 | ✅ 已做 |
| LiDAR 采样直连会话（不再绕 Dart） | ✅ 已做 |
| 清理 Windows 桌面入口 | ✅ 已删 `windows/`（只有模板代码） |

Dart 侧的功能层（`ff_protocol.dart`、`lens.dart`、`lens_lut.dart`、`motor_cal.dart`）
和它们的测试已删除。**现在只有一份实现，在 Swift 里。**

### `ff.core` 契约

```text
方法通道 ff.core         命令，fire-and-forget，返回 nil 或一次性结果
事件通道 ff.core/events  约 20Hz 的聚合状态快照
```

| 方法 | 作用 |
| --- | --- |
| `start` / `stop` / `snapshot` | 会话生命周期；`snapshot` 取一次当前状态 |
| `discover` / `selectDevice` / `connect` / `disconnect` | 设备 |
| `enable` `stopPressed` `homePressed` `jog` `setSlider` `setAuto` `setSpeed` | 手动控制 |
| `setMicrosteps` `setTmc` `queryTmc` `setStandbyFeature` | TMC 调试面板（全保留） |
| `selectLens` `createLens` `deleteLens` | 镜头 |
| `recordStrokeA` `finishStroke` `recalibrateStroke` | ① 行程标定 |
| `confirmNear` `setDir` `startFollow` `unalign` | ② 单侧对齐 |
| `addLutPoint` `removeLutPoint` | ③ 距离标定 |
| `setTrackFaces` / `ingestDistance` | LiDAR（后者只给模拟器和测试用） |

分工：

- **命令表、参数解析、事件推送**：`ios/Runner/FollowFocusCorePlugin.swift`（纯搬运）。
- **快照 → map 的序列化**：`ios/FollowFocusCore/Sources/FollowFocusCore/SnapshotJson.swift`。
  放在功能层里是为了能用 `swift test` 钉住键名（`SnapshotJsonTests`）—— 跨语言的字典键
  拼错了不会崩，只会让界面静默显示空值。
- **Dart 侧解析**：`lib/ff_core.dart`。**只有字段搬运，没有逻辑。**

快照里连“圈数”“细分上限”这类派生值一起给（`pos_revs`、`stroke_revs`、`max_revs_per_sec`），
UI 不再自己乘 400/除细分。UI 里仅剩的算术是圈→脉冲的一次乘法（走圈按钮）和一个
纯显示的峰值速度提示，都不参与任何决策。

### LiDAR 直连

`LidarEngine.shared.onDistance` 直接回调给会话（`FollowFocusSession.ingest`），
采样不再经 event channel 绕到 Dart 再回来。`ff.lidar` 通道仍然保留，但只负责
预览图和人脸框的显示数据。

这条边界是刻意的：只有 `ios/Runner`（平台壳）能同时看到采集层和功能层，
功能层依旧不认识 UIKit/Camera。

### 迁移中修掉的 bug

Dart 版自动跟焦的死区判断写成了 `abs(want - (lastSent ?? want)) < 死区`，
`lastSent` 为 nil 时恒等于 0，于是每个 tick 都被判成“没跨过死区”直接 return：
**自动跟焦一个目标都发不出去，电机只会被手动滑条推动。** Swift 版只在真的
发过目标时才比死区（`if let last = lastSent, ...`），并加了测试钉住。


## 14. 2026-09-26 固件交接：自动识别镜头行程（App 已接入）

### 已完成范围

检查确认原固件只有 `SG_RESULT` 诊断读取，没有 StallGuard4 自动行程状态机。
现在基于原 `hw_timer_t` 脉冲和本地规划器实现双端寻位，不更换驱动框架；
2026-09-28 起运动中改由新增的 DIAG→GPIO11 接线检测堵转。
新增 CAL_START / CAL_QUERY / CAL_CANCEL / CAL_STATUS，wire 契约以 PROTOCOL.md §14 为准。
固件版本改为 1.1.0，协议主版本仍为 1，原 12/16/22/32 字节回包保持兼容。
本次仅修改固件、固件测试工具和交接文档；Flutter/iOS 页面由 Mac 设备接续开发。

流程：负向寻找第一端 → 正向回退 → 正向寻找另一端 → 负向回退 → 发布安全范围。
两端各退 16 整步；启动 200 ms 后才响应 DIAG 堵转脉冲，
正向扫描和最终回退还需要观察到一段无 DIAG 脉冲的运动。每段有最大步数和 60 秒上限，
1000 ms 标定保活超时、200 ms ISR 服务超时均会停止。
UART 回复必须通过 CRC，写配置通过 IFCNT 的九次增量确认（这些 SG 寄存器是只写，不能靠读回确认）。
失败、取消或驱动异常停止并禁用电机，坐标不可信，软限位收紧至当前位置。
成功后保留保持电流，直至用户主动禁用或用 HOME/SET_LIMITS 等使结果失效，避免选择方向时丢原点。

### App 两个入口和操作顺序

1. 选择已有镜头后的标定页，在“确认为焦距最近点”旁加入“自动识别行程”。
   新增镜头流程也提供同一入口，复用同一标定流程，不自动偷偷启动电机。
2. DISCOVER 判断固件 >=1.1.0；旧固件继续人工标定，不把旧固件返回的 STATUS 当作识别成功。
   开始前提示只支持有机械挡块的对焦环，确认齿轮啮合，停止 App 原有跟焦/手轮/目标保活定时器。
3. QUERY 确认电机停止，ENABLE(1)。首次 CAL_QUERY(a=0) 读取上一 run_id；
   选择另一个 1..255 的 id，以它作为 CAL_START.sequence，a=阈值、b=最大寻端步数。
   默认阈值 60 仅为调试起点，尚未针对实际镜头验证。默认每段两电机圈。
4. 每 200 ms 发 CAL_QUERY(a=run_id)，独立的 sequence 用于匹配回复。
   请求重试 CAL_START 必须复用同一个 run_id，不能因 UDP 丢包不断换 id。
   界面显示阶段而非伪造百分比：寻找第一端、退回、寻找第二端、退回、完成/失败。
5. 返回、取消、切后台时发 CAL_CANCEL；停止轮询后固件也会在 1 秒内停机。
   普通 QUERY 不续期。扫描期间禁止 App 下发 TMC_SET、SET_SPEED、SET_LIMITS、HOME 或跟焦目标。
6. 只有 error=0、state=5、valid=1 才能采用安全范围。固件已经设置 [0,safe_max] 并停在 safe_max，
   此时不要再 HOME 或 SET_LIMITS，否则自动识别结果会被标记失效。
7. 显示“对焦距离变化方向”：正步数使对焦距离变远 / 正步数使对焦距离变近。
   变远时 near=0、far=safe_max；变近时 near=safe_max、far=0。
   可在安全范围内提供小步试动，并允许用户反转方向。方向留在 App 镜头档案，不改物理 DIR 定义。
8. 按镜头保存 safe_span、travel、方向、microsteps、实际电流、SGTHRS、固件版本及标定条件。
   换镜、重新啮合、手动拧环、禁用或设备重启后应重新定位，不能仅把旧步数范围发回就认定原点有效。
   固件不保存镜头档案。App 仍需距离到步数 LUT；识别行程和方向不会自动得到精确物距曲线。

### App 接入进度（2026-09-28）

Swift 功能层已按 §14 解码 CAL_STATUS，负责固件版本门控、停止确认、run_id 选择、
200 ms 标定查询、丢包重试、互斥和取消。新镜头与现有镜头共用 Flutter 入口，用户确认
机械挡块和齿轮后才会启动；旧固件保留手动流程。扫描阶段显示具体阶段和错误原因，
成功后要求确认近远方向，并清空旧距离表。镜头档案保存安全行程、估计机械行程、
细分、电流、阈值、每段上限和固件版本。

自动标定得到的坐标只在当前连接和使能周期内有效。切镜、离开页面、禁用、HOME、
重连、结果失效或状态回包超时都会停止并丢弃会话坐标；旧行程数据保留供查看，
再次使用需重新识别。也可长按“重新标定行程”确认清空旧行程，软件置零后改用
人工两端记录。`swift test` 的 UDP 假板子覆盖双向确认、首包丢失、旧固件、旧 run、
拒绝、取消、断联和方向；Flutter 测试覆盖显式启动和方向按钮。尚未用真实镜头验收。

### 本次验证与边界

- 用户明确设备尚未连接镜头，本次只验证固件和通信，不启动真实运动。
- 主机模拟直接编译生产 motor.cpp/protocol.cpp，测试说明见 `test/firmware_host/README.md`。
  已覆盖双端成功、余量、配置恢复、成功后保持、互斥指令、停止/禁用、错误 run 保活、
  UART/CRC/寄存器写丢失、驱动故障、最大距离、全低 SG 误判、阶段/通信/ISR 超时和新旧回包兼容。
- PlatformIO s3mini 构建通过；COM19 ESP32-S3 刷写、镜像哈希校验通过。
- Wi-Fi `FF-75A578` 非运动实测通过：DISCOVER 版本 1.1.0，CAL_STATUS 32 字节，
  sequence 回显、无效 run_id 和未使能启动拒绝、空闲取消、旧 STATUS/STATUS_V2/TMC_DUMP 正常。
  TMC UART=1、chip=0x21，位置始终 0；结束保持禁用。
  Windows 原热点配置密码不匹配，已同步为本仓库 `change-me` 后恢复连接。
- 真实镜头的堵转阈值、打滑/齿隙影响、范围重复性和两端余量仍待现场调参，不能标记为机械验收通过。
  原 `test/udp_motion_acceptance.py` 会实际转动电机，本次按用户限制未运行。

调试工具：`python firmware/tools/calibrate.py` 只读；`--smoke` 先禁用电机再验证通信，
不会使能/运动；`--start --threshold 60 --max-steps 12800` 会真正转动电机，
仅装好适用镜头并准备好急停后使用；`--cancel` 取消。默认连 192.168.4.1:4210。
串口 115200 输出 run/阶段/结束原因和估计行程，便于和 App 抓包对照。

后续机械验收至少需要：从中点及两端分别启动、多次扫描比较行程、两种方向确认、
模拟断联和取消、齿轮打滑/无挡块失败验证，并在实际电流/细分下记录 SG 数值与所用阈值。
安全范围是开环估计，连续低值检测存在延迟，回退余量不能代替实际镜头负载验证。

### 现场记录 2026-09-29（真机第一次跑起来）

App 侧两个误导性 bug 已修（见 §8.1 与 `FfProtocol.swift` 注释）：CAL_STATUS 的
`error` 曾被解码器卡在 ≤10，固件回 `CAL_DIAG=11` 时整包被丢，界面只会说
“标定保活超时，请检查连接”；修好后 App 能直接显示“DIAG 未接通”。

接线补齐后（`GPIO11 <- TMC DIAG`，`cal DIAG GPIO11 pullup=0 pulldown=0` 即已接通），
固件能启动标定并真的转动电机，但连续 6 次都没走完，串口日志给出两类原因：

| 现象 | 串口 | 判断 |
| --- | --- | --- |
| 每段只走 ~317 步就判堵转 | `cal DIAG run=N phase=1 pos=-317`（1600 步/秒 ≈ 198 ms） | 恰好卡在固件的 200 ms 启动屏蔽之后 → **堵转判定一直在成立**，即 `SGTHRS=60`（比较基准 2×60=120）高于实际 SG 读数（TMC_QUERY 读到 26–86）→ **阈值过大，误判为空载即堵转** |
| 两端只有 ~870 步 | `state=7 error=9`（`CAL_SHORT_TRAVEL`） | 行程过短的保护正确触发，是上面误判的后果，不是新问题 |
| 堵转后读诊断失败 | `drv=0xFFFFFFFF` → `state=7 error=3`（`CAL_UART`） | 停转瞬间那次 `tmcReadReg(0x6F)` 半双工丢包；已加固（见 §4.2）：4 次重试 + 重试前排空与延时 |

**当晚结论（阈值填 1 之后）**：`SGTHRS=1` 时空载不再误判，电机能持续走；
运行中用**手代替镜头限位**挡住输出轴，DIAG 立即触发、端点识别成立 ——
**自动识别行程的机制在真机上第一次跑通**（此前只是固件/主机模拟验证）。

由此可以定下几个数：

- 这台机器的**空载 SG 读数落在"阈值 1 不触发、阈值 10 就触发"之间**：60 和 10 每段都恰好
  在 200 ms 屏蔽结束处被当成堵转（`pos≈-317` 与 `pos≈-321` 几乎相同，说明与阈值高低无关，
  而是空载读数一直在触发侧）。**阈值必须现场标定**，不能沿用文档里的默认 60。
- 判定与"电机是否有负载"无关：StallGuard 是**负载测量**，空载读数落在阈值哪一侧取决于
  阈值本身；所以拆掉负载不能当作"不会误判"的证据（固件文案 `error=9` 里的
  "空载读数无效"就是这个意思）。
- 电池/电流不是这一轮的原因：负载拆掉后现象不变，问题在阈值与 DIAG 信号本身。

下一步（按性价比排序）：

1. **拿着 `SGTHRS=1` 上真实镜头**，从行程中点开始标定：真挡块能触发就说明可用；
   若一路顶到每段上限报 `error=5`（`CAL_DISTANCE`），把阈值往上加几档（2–5）再试。
   验收项见本节的"后续机械验收至少需要"。
2. **加固堵转后那次 DRV_STATUS 读**（§14 讨论）：读失败时按堵转继续、完成前补一次检查，
   避免"没问到诊断值"就把整轮标定作废（真机上 6 次里 4 次死在这里）。
3. **加 `diagEdges` 电平/边沿计数**到周期串口行：静止若在涨=纯噪声，只有走步时涨=接错脚/串扰，
   两者都不涨但标定仍 200 ms 停=芯片真在报 —— 三种情况一眼分开。

排查用工具：`python3 tool/serial_tap.py`（本仓库，只读抓 115200 串口并打时间戳，
USB CDC 掉线会自动重连，板子被拔时会干净退出）。App 报错时对照同一时刻的固件输出，
比在 App 侧猜快得多。

### 固件侧完成情况（2026-09-29）

上面 3 条已做完并**已刷进板子**（`FF-75A578`，本机 macOS 用 `~/.pio-venv` 的
PlatformIO 编译 + 刷写，见 §4.1）：

- `tmcReadReg`：4 次尝试 / 15 ms 窗口 / 失败后**排空 + 2 ms** 再重试；
- 标定的寄存器配置块（9 次写 + IFCNT +9 校验）最多整块重来 3 次；
- 串口诊断：失败时 `tmc read fail addr=0xNN (total=N)`，TMC 行加
  `drv_valid=` / `readfail=`（线上协议**未改**，见 §4.2）；
- **主机模拟重新能编译 DIAG 版固件**：`test/firmware_host/Arduino.h` 补了
  `digitalRead`/上拉下拉/`attachInterrupt`，并新增三条钉住现场结论的用例
  （DIAG 未接必须在运动前拒绝、扫描期间丢包不打断、堵转误判→`CAL_SHORT_TRAVEL`），
  见 `test/firmware_host/README.md`。

剩下的仍然是**机械调参**：现场已确定 `SGTHRS=1` 在空载下可用（见上一节的现场记录），
真实镜头要从行程中点开始验，必要时加几档阈值或调 `maxRevs`；电流/细分组合也属于现场决定，
代码侧没有可替代的验证。


