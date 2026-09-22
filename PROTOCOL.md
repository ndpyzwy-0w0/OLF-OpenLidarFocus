# 跟焦固件通信契约（PROTOCOL.md）

本文件是 ESP32-S3 跟焦固件与上位机之间**唯一的线上协议契约**。上位机（`lib/**`、`ios/**`）请把它当
只读依赖；固件侧（`firmware/**`、`test/udp_motion_acceptance.py`、本文件）负责维护它。代码与本文件
不一致时，以本文件为准去修代码；上位机不要按猜测实现。

- 协议版本：`protocol = 1`（`kFfProtocolVersion`）
- 固件版本：`fw 1.0.0`（[device.h](firmware/include/device.h) 的 `kFwMajor/Minor/Patch`，与
  [pubspec.yaml](pubspec.yaml) 的 `version: 1.0.0+1` 保持一致）
- 验收状态：`test/udp_motion_acceptance.py` 真机 9/9 通过（含"单次锁存"和"单发 JOG 流式/锁存对照"用例）

---

## 1. 设备身份与网络

| 项 | 值 | 说明 |
| --- | --- | --- |
| SSID | `FF-` + AP 接口 MAC 末三字节大写十六进制 | 例：MAC `92:DA:72:75:A5:78` → `FF-75A578` |
| 密码 | `ffdebug1` | 写死在固件里（`kPass`） |
| 信道 | 1 | `kApChannel` |
| 板子 IP | `192.168.4.1` | AP 模式，手机/调试机作为 STA 拿到 `192.168.4.x` |
| UDP 端口 | `4210` | `kUdpPort`，控制与发现共用 |
| HTTP | `http://192.168.4.1/` | 状态页；探测路径见 §1.2 |
| AP 客户端上限 | 4 | `kApMaxStations`，手机 + 调试机可同时接入 |

**身份一致性**：扫描得到的 BSSID（`92:DA:72:75:A5:78`）= 发现回包里的 `mac` = SSID 去掉 `FF-` 前缀的
末三字节。上位机连接前应做这个校验，避免连到名字相似的其它设备。

### 1.1 同一时刻只有一个控制器

AP 允许多台客户端，但固件不区分命令来源：**最后到达的命令生效**。上位机侧必须保证同一时刻只有一个
控制者（例如 App 前台时独占，调试脚本先停手）。多控制器同时发 `SET_POS` 会互相抢目标。

### 1.2 联网探测（captive portal）

固件按 iOS/Android 规范回答探测请求，**故意不弹“登录网络”面板**：

| 路径 | 响应 |
| --- | --- |
| `/hotspot-detect.html`、`/library/test/success.html` | `200` + `<HTML>…Success…</HTML>` |
| `/generate_204` | `204 No Content` |
| 其它任意路径 | `302 → http://192.168.4.1/`（给人用；DNS 通配把任意域名解析到 `192.168.4.1`） |

---

## 2. 报文封装

所有控制/状态包都是 **12 字节小端（LE）** 的 `FfPacket`：

| 偏移 | 字段 | 类型 | 说明 |
| --- | --- | --- | --- |
| 0 | `magic` | u8 | 恒 `0x46`（`'F'`） |
| 1 | `cmd` | u8 | 见 §3 |
| 2 | `flags` | u8 | 请求方向与回包方向含义不同，见 §2.1 / §2.2 |
| 3 | `pad` / `sequence` | u8 | 上位机自填的序号，回包原样回显（旧客户端可填 0） |
| 4-7 | `a` | int32 | 含义随 `cmd` |
| 8-11 | `b` | int32 | 含义随 `cmd` |

### 2.1 请求方向的 `flags`（本版只定义位 0）

| 位 | 名称 | 含义 |
| --- | --- | --- |
| 0 | `FF_REQ_LATCH = 0x01` | `0` = **流式**（默认）：本次移动纳入通信看门狗，运动期间必须持续发新包，静默超过 1 s 会被刹停。<br>`1` = **单次锁存**：本次移动不纳入看门狗，发一次即可，固件自行跑完；此时若上位机失联，移动会一直走到目标才停（软限位照常生效）。 |
| 1-7 | 保留 | 固件忽略未知位（前向兼容）。上位机也应忽略自己不认识的位。 |

只有 `SET_POS`(0x01) / `JOG`(0x02) 解释这个字节；其它命令忽略它。

### 2.2 回包方向的 `flags`

低 5 位是状态位，高 3 位是最近一次命令的结果（`FF_RESULT_SHIFT = 5`，掩码 `0xE0`）。

低 5 位：

| 值 | 名称 | 含义 |
| --- | --- | --- |
| 1 | `FF_FLAG_ENABLED` | 用户使能中（注意：使能 != 正在通电，见 §7） |
| 2 | `FF_FLAG_MOVING` | 正在运动（`stepRate != 0 \|\| pos != stepTarget`） |
| 4 | `FF_FLAG_UART_OK` | TMC 驱动 UART 通信正常 |
| 8 | `FF_FLAG_STANDBY` | 已进入待机断电：用户仍使能，但驱动被释放（EN 抬高） |
| 16 | `FF_FLAG_LIMITED` | 最近一次位置命令被软限位夹紧 |

高 3 位（`result = (flags >> 5) & 0x07`）：

| 值 | 名称 | 含义 |
| --- | --- | --- |
| 0 | idle | 上电后还没收到任何命令 |
| 1 | accepted | 命令被接受，若还没走完就是进行中 |
| 2 | completed | 已到位（`pos == target && !moving`） |
| 3 | limited | 命令被软限位夹紧后接受 |
| 4 | rejected | 拒绝（最典型：未 `ENABLE` 就发 `SET_POS`/`JOG`） |
| 5 | stopped | 被 `STOP`、取消使能或通信看门狗停下 |

**提升规则**：`accepted` 在 `pos == target && !moving` 时上报为 `completed`（`effectiveResult()`）。
所以「发一次命令后只看一个包」可能读到 `accepted`，之后读到 `completed` —— 两者都不算错。

---

## 3. 命令表

| cmd | 名称 | `a` | `b` | 回包 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `0x01` | `SET_POS` | 绝对目标位置（步） | — | STATUS | 需先 `ENABLE(1)`，否则 `rejected` 且不动 |
| `0x02` | `JOG` | 相对位移（步） | — | STATUS | 同上；目标 = 当前位置 + `a` |
| `0x03` | `STOP` | — | — | STATUS | 立刻停在当前物理位置，并把 `target` 重锚到当前 `pos` |
| `0x04` | `ENABLE` | `1` 使能 / `0` 取消 | — | STATUS | `0` 会 `STOP` + 清 `position_trusted` |
| `0x05` | `SET_LIMITS` | 最小步数 | 最大步数 | STATUS | 会覆盖默认的 ±20 圈，并清除 `LIMITED` |
| `0x06` | `QUERY` | — | — | STATUS **+ STATUS_V2** | 查询用；**不刷新看门狗** |
| `0x07` | `SET_SPEED` | 频率 Hz | 加速度 | STATUS | 钳制：Hz∈[100, 40000]，accel∈[100, 1000000] |
| `0x08` | `TMC_QUERY` | — | — | TMC_DUMP | 不回 STATUS |
| `0x09` | `TMC_SET` | 参数键 | 值 | TMC_DUMP | 键见 §6.3；不回 STATUS，设置项持久化 |
| `0x0A` | `HOME` | — | — | STATUS **+ STATUS_V2** | 只做软件置零，电机不动；`moving` 时 `rejected` |
| `0x0B` | `DISCOVER` | — | — | DISCOVER_REPLY | **不回状态包**，见 §4 |
| 其它 | 未知命令 | — | — | STATUS | 只回一个 STATUS（不是错误码，靠 result 位判断不了） |

回包总是单播回**请求的来源 IP:端口**。

### 3.1 回包数量不对称（上位机必须知道）

| 发出去的 | 收回来 |
| --- | --- |
| `SET_POS` / `JOG` / `STOP` / `ENABLE` / `SET_LIMITS` / `SET_SPEED` | 1 × STATUS |
| `QUERY` / `HOME` | 2 × 包：STATUS + STATUS_V2 |
| `TMC_QUERY` / `TMC_SET` | 1 × TMC_DUMP（没有 STATUS） |
| `DISCOVER` | 1 × DISCOVER_REPLY（没有 STATUS） |
| 未知命令（magic/长度合法） | 1 × STATUS |

上位机不要"收到第一个包就以为回复结束"，也不要用"等第二个包"的方式读单包命令的回复（会白等一个
超时）。

### 3.2 非协议包会被原样回显

长度 < 12 字节，或第 0 字节不是 `0x46` 的 UDP 包，固件**原样回显**（保留这个行为是为了链路 RTT
测量）。上位机侧注意：

- 解析前先校验 `len >= 12 && data[0] == 0x46`，否则不要把回显当成状态包。
- 反过来，不要指望用一个畸形包去探测固件，它只会把同样的字节还给你。

---

## 4. 发现（DISCOVER / DISCOVER_REPLY）

- 请求：12 字节包，`cmd = 0x0B`，`a`/`b`/`flags` 无意义。可发到
  `255.255.255.255:4210`（广播，需要逐网卡绑定发送）或直接单播 `192.168.4.1:4210`。
- 回复：**32 字节** `FfDiscovery`，单播给请求方。

| 偏移 | 字段 | 类型 | 说明 |
| --- | --- | --- | --- |
| 0 | `magic` | u8 | `0x46` |
| 1 | `cmd` | u8 | `0x84` |
| 2 | `kind` | u8 | `1` = 跟焦器（`kFfKindFollowFocus`） |
| 3 | `protocol` | u8 | `1` |
| 4-5 | `udp_port` | u16 LE | `4210` |
| 6 | `fw_major` | u8 | `1` |
| 7 | `fw_minor` | u8 | `0` |
| 8 | `fw_patch` | u8 | `0` |
| 9-14 | `mac` | u8[6] | AP 接口 MAC，等于扫描到的 BSSID |
| 15-30 | `device_id` | char[16] | NUL 结尾，如 `FF-75A578` |
| 31 | `reserved` | u8 | 保留，当前 0 |

---

## 5. 回包布局

### 5.1 STATUS（`0x81`，12 字节）

与 §2 的 `FfPacket` 同布局：`a = pos`（当前步数），`b = target`（目标步数），`pad` 回显请求序号，
`flags` 见 §2.2。

### 5.2 STATUS_V2（`0x83`，16 字节）

| 偏移 | 字段 | 类型 | 说明 |
| --- | --- | --- | --- |
| 0 | `magic` | u8 | `0x46` |
| 1 | `cmd` | u8 | `0x83` |
| 2 | `flags` | u8 | 与 STATUS 完全相同的状态位 + result |
| 3 | `sequence` | u8 | 回显请求的 `pad` |
| 4-7 | `pos` | int32 | 当前步数 |
| 8-11 | `target` | int32 | 目标步数 |
| 12 | `position_trusted` | u8 | 见 §8 |
| 13 | `fault` | u8 | **当前恒为 0（占位）**，不要据此判断故障 |
| 14-15 | `reserved` | u16 | 位定义见下 |

`reserved` 位：

| 位 | 名称 | 含义 |
| --- | --- | --- |
| 0 | `FF_V2_WATCHDOG_ARMED = 0x0001` | 通信看门狗「已武装」：如果正在运动且是流式命令，静默 1 s 就会被刹停。 |
| 1-15 | 保留 | 固件忽略，上位机也忽略。 |

**`ARMED` 的正确用法**：它表示"当前处于流式监视模式"，**不是**"现在正在被监视"。
它由最近一次被接受的 `SET_POS`/`JOG` 设置：流式命令置 `1`，锁存命令置 `0`。一次流式移动
跑完之后它**仍然是 `1`**，清除/改写时机只有 `ENABLE(0)`、`HOME`、看门狗超时和下一次锁存命令。
只有 `ARMED && MOVING` 同时成立，才意味着"此刻失联会被刹停"。

### 5.3 TMC_DUMP（`0x82`，22 字节）

| 偏移 | 字段 | 类型 | 说明 |
| --- | --- | --- | --- |
| 0 | `magic` | u8 | `0x46` |
| 1 | `cmd` | u8 | `0x82` |
| 2 | `uart_ok` | u8 | TMC UART 是否通 |
| 3 | `stealth` | u8 | StealthChop 是否开启 |
| 4-5 | `rms_ma` | u16 | 运行电流（mA） |
| 6-7 | `microsteps` | u16 | 细分 |
| 8 | `toff` | u8 | 关断时间 |
| 9 | `ihold` | u8 | 保持电流档 |
| 10 | `irun` | u8 | 运行电流档 |
| 11 | `version` | u8 | 芯片版本，TMC2209 = `0x21` |
| 12 | `cs_actual` | u8 | 实际电流档读数 |
| 13 | `drv_flags` | u8 | 由 `drv_status` 归纳，见下 |
| 14-17 | `drv_status` | u32 | `DRV_STATUS` 原值（`0xFFFFFFFF` 表示读失败，此时上报 0） |
| 18-19 | `sg` | u16 | StallGuard 结果 |
| 20-21 | `tstep` | u16 | TSTEP 测量值 |

`drv_flags` 位：`1` OT · `2` OTPW · `4` OLA · `8` OLB · `16` S2GA · `32` S2GB · `64` STST · `128` STEALTH。

**故障诊断只能靠这里**（`STATUS_V2.fault` 是空占位）：`drv_flags` 出现 OT/OTPW/S2GA/S2GB/OLA/OLB，
或者 `uart_ok == 0`，才是真正的硬件异常。

---

## 6. 运动语义

### 6.1 前置条件与拒绝

- `SET_POS` / `JOG` 在**未使能**或步进定时器未就绪时直接 `rejected`，不动，也不改变 `target`。
- 建议顺序：`ENABLE(1)` → `SET_LIMITS(min,max)`（若已标定）→ `SET_SPEED(hz,accel)` → `SET_POS/JOG`。
- 被软限位夹紧时：`result = limited`、`FF_FLAG_LIMITED` 置位、`target` 是夹紧后的值。`SET_LIMITS` 会清掉
  `LIMITED` 标志。
- `HOME` 要求当前不运动（`moving` 时 `rejected`），**不要求使能**。

### 6.2 位置与限位单位

- 1 圈 = `400 × 细分` 步。默认细分 16 → **3200 步/圈**。
- 未标定时软限位是 ±20 圈，并随细分自动缩放（1/256 细分时同样是 ±20 圈）。
  历史上写死 ±20000 步的默认值会在换细分后把行程无声夹没，表现成"点了没反应"。
- 上位机标定后应下发 `SET_LIMITS`（按步数）覆盖默认值。

### 6.3 TMC 参数键（`TMC_SET` 的 `a`）

| 键 | 名称 | 范围/建议 |
| --- | --- | --- |
| 1 | `TMC_RMS` | 运行电流 mA，建议 300–1200（默认 800） |
| 2 | `TMC_MICROSTEPS` | 8/16/…/256（默认 16） |
| 3 | `TMC_STEALTH` | `1` 静音（默认）/ `0` SpreadCycle 更硬 |
| 4 | `TMC_TOFF` | 1–15，一般 3–5（默认 4） |
| 5 | `TMC_IHOLD` | 0–31，`0` = 停止时不锁轴、不发热 |
| 6 | `TMC_IRUN` | 0–31，一般不用，改用 `TMC_RMS` |
| 7 | `TMC_STANDBY` | `1` 静止约 2.5 s 后断使能（默认）/ `0` 一直保持电流 |

### 6.4 持久化（NVS）

| 持久化（重启保留） | 不持久化（重启后回默认/需重发） |
| --- | --- |
| TMC 参数：`rms` `hold` `ms` `toff` `stealth` `intpol` `standby`（namespace `tmc`） | 使能状态（开机一律不使能，安全考虑） |
| | 位置 `pos` / `target`（开机归 0，`position_trusted = 0`） |
| | 软限位、速度/加速度 |

---

## 7. 通信看门狗与「单次锁存」（本版重点）

固件默认假设上位机会**持续**发控制包；静默会被当作失联并刹停。

```
kControlTimeoutMs = 1000

每个 SET_POS / JOG 到达时：
    lastControlPacketMs = now
    communicationWatchdogArmed = !(该包的 flags 位 0 置 1)     // 流式 → 武装；锁存 → 不武装

motorCommunicationTick()（主循环每轮）：
    if (!armed || !enabled || !moving) return
    if (now - lastControlPacketMs < 1000) return
    刹停：motorStop() + armed = false + result = stopped
```

要点：

1. **只有 `SET_POS` / `JOG` 刷新看门狗**。`QUERY`、`STOP`、`SET_LIMITS`…都不刷新 —— 用它们当心跳无效。
2. 重发同一个 `SET_POS` 目标是安全且幂等的：不会产生额外运动，只会刷新看门狗、解除待机。
3. 超时刹停会把 `target` 重锚到当前 `pos`，所以停住之后 `pos == target` 恒成立，`result = stopped`。
4. `armed` 的清除/改写时机：`ENABLE(0)`、`HOME`、看门狗超时，以及**下一次锁存命令**（锁存会把
   它置 0）。`STOP` **不清**（无害：tick 还要求 `moving`）。
5. 被拒绝的命令（例如未使能时的 `SET_POS`）也会留下 `armed = true`，同样无害：任何后续被接受的移动
   都会重新设置它。

### 7.1 谁该用哪种模式

| 场景 | 建议 |
| --- | --- |
| 自动跟焦（实时跟踪被摄体） | **流式**，且运动期间每 **200–500 ms** 重发一次最新目标（哪怕目标没变）；失联必须能自动停 |
| 手动拖动滑条 | 拖动过程流式保活；松手后如果目标还没到，继续保活到停，或改用锁存单发 |
| 上位机「点一下就移动到某位置」（一次性的长行程） | **锁存**（`flags` 位 0 = 1），发一次即可，不必为了防截断而空转发包 |
| 上位机自己就是唯一的控制者且保证不断线 | 两种都行；锁存更省电、更省带宽 |

### 7.2 上位机必须改的地方（「点一次走圈，走到一半就停」的根因）

`lib/` 目前两条发送路径都是**流式**（`FfPacket.flags` 默认 0）：[ff_protocol.dart](lib/ff_protocol.dart)
的 `setPos()` / `jog()` 是纯单发，而 [main.dart](lib/main.dart) 的 `_jog()`（"走步"/"走圈"按钮）
发完就不再发。于是任何超过 1 s 的行程都在 **1.0 s 处**被看门狗刹停 —— 截断位置只由
"速度 × 1 s"决定，跟行程总长无关：

| 速度设置（单发 `JOG 16000` = 5 圈） | 1.0 s 处被截断的位置（真机实测） |
| --- | --- |
| 3200 脉冲/秒（App 默认 1.2 圈/秒，加速度 96000） | `pos ≈ 3800–4000` 步 ≈ **1.2 圈**（24–25%） |
| 9600 脉冲/秒（App 滑条 ≈3 圈/秒，加速度 96000） | `pos ≈ 9300–9700` 步 ≈ **2.9 圈**（58–61%） |
| 8000 脉冲/秒（固件默认，加速度 20000） | `pos ≈ 6700–7000` 步 ≈ **2.1 圈**（42–44%） |
| 3200 脉冲/秒 + 锁存 | `pos = 16000` 步 = **5.00 圈**，`result = completed` |

上表是实测值（`test/repro_jog_truncation.py` 的真机输出），比"纯速度 × 1 s"的理论值略小一点，
差在加速段 —— 起步到匀速也占了那 1 s 里的一部分。

两个改法任选一个；"点一次就走"的按钮用锁存更合适（省电、省带宽）：

```dart
// ff_protocol.dart：让单发命令能带锁存位
void setPos(int steps, {bool latch = false}) =>
    _send(FfPacket(cmd: kFfSetPos, a: steps, flags: latch ? 0x01 : 0));
void jog(int delta, {bool latch = false}) =>
    _send(FfPacket(cmd: kFfJog, a: delta, flags: latch ? 0x01 : 0));

// main.dart：走步/走圈是一次性长行程 → 用锁存
_link.jog(delta, latch: true);
```

```dart
// 或者：保持流式，在运动未完成期间每 200–500 ms 重发当前目标（幂等，见上）
if (_moving) _link.setPos(_targetSteps);
```

自动跟焦**不要**用锁存：它必须靠保活，失联时要能自动停（见 §7.1）。改完之后可以用
`test/udp_motion_acceptance.py` 里的 `single-shot JOG: streaming vs latched` 组核对两种模式
都还符合契约。

想亲眼看截断，跑 `python test/repro_jog_truncation.py`：它严格照抄 App 的发包方式（单发 `JOG`
16000 步 + 200 ms `QUERY` + 1 s `TMC_QUERY` 轮询），四种速度/模式各走几趟，打印每趟的
"最后运动中 / 首次静止"时刻和原始轨迹。**流式必然被截断，锁存必然跑满**，输出末行给出结论、
退出码 0；设备停在 `pos = 0`、静止、`ENABLE(0)`。

### 7.3 真机验证过的证据

- 流式 `SET_POS 19000` 后静默 1.25 s → 停在 `pos = 6202`，`result = stopped`（应到 19000）
- 锁存 `SET_POS 12000` 后静默 1.25 s → 仍在运动（`pos ≈ 8606 → 12000`），最终 `result = completed`
- 单发 `JOG 16000`（= 5 圈）8000 脉冲/秒：流式停在 `pos = 6455` / `stopped`，锁存跑满
  `pos = 16000` / `completed`
- 三条都在 `test/udp_motion_acceptance.py` 里成为固定用例（`communication timeout` /
  `latched single-shot move` / `single-shot JOG: streaming vs latched`）
- 另有 `test/repro_jog_truncation.py` 在真机上反复复现（4 种模式 × 3 趟）：每趟流式都在
  "最后运动中 0.81–0.83 s / 首次静止 1.02–1.04 s"被刹停、`result = stopped`、`armed` 由 1 转 0，
  截断位置 24–61%（随速度）；锁存 3 趟全部 `16000` 步 / `completed`。轨迹里能直接看到
  `t=1.03s pos=4008 target=4008 moving=0 result=stopped armed=False` —— `target` 被
  `motorStop()` 重锚，证明是看门狗主动刹停，不是丢包或限位。

---

## 8. `position_trusted` 与 HOME

`position_trusted` 回答一个工程问题：**当前步数与真实镜头位置还对应得上吗？**

| 时机 | `position_trusted` |
| --- | --- |
| 上电 | `0`（步数是软件计数，未经标定） |
| `HOME` | `1`（明确把当前静止位置定义为原点） |
| `ENABLE(0)` | `0`（断电期间外力可能转动过镜头，计数不再可信） |
| 待机断电（§9） | **刻意保留不变**（这是已知的例外，见下） |

上位机用法：

- `position_trusted == 0` 时不要把 `pos` 当绝对角度用；需要绝对定位就先 `HOME` 或让用户重新标定。
- `HOME` 只做软件置零：清零 `pos`/`target`、置 `position_trusted = 1`、`result = completed`，**电机不动**。
  所以它要求当前不运动。
- 例外：进入待机断电会释放扭矩（镜头理论上可被外力推动），但固件**不清** `position_trusted`。如果
  上位机需要严格语义，请自己监视 `FF_FLAG_STANDBY`：一旦在待机期间观察到外部位移风险，就重新标定。

---

## 9. 使能与待机

- `ENABLE(1)`：允许运动；会立即解除待机（EN 拉低通电），`standbyOff = false`。
- `ENABLE(0)`：`STOP` + 清 `position_trusted` + 清 `armed`，`result = stopped`。
- 待机断电（`kStandbyDelayMs = 2500`）：使能状态、无运动、且 `TMC_STANDBY = 1` 时，静止 2.5 s 后把 EN 抬高
  释放扭矩（防发热/防微震）。此时 `FF_FLAG_ENABLED` 仍为 1、`FF_FLAG_STANDBY` 也为 1。
  **只有 `SET_POS` / `JOG` 会唤醒**（`QUERY` 不会）。
- `TMC_STANDBY = 0` 可以整体关掉待机断电（持久化）。

---

## 10. 上位机实现检查清单

必须做：

1. 连上 AP 后先 `DISCOVER`（广播或 unicast `192.168.4.1`），核对 `device_id`/`mac` 与扫描到的 BSSID。
2. 运动前 `ENABLE(1)`；收到 `rejected` 先查是不是没使能。
3. 自动跟焦/长时间移动：**运动期间每 ≤500 ms 重发一次目标**（流式），或者改用锁存位（接受"失联不会自动停"）。
4. `QUERY` / `HOME` 要收**两个**包（STATUS + STATUS_V2）；其余命令只收一个。
5. 解析前校验 `len >= 12 && data[0] == 0x46`，否则当回显忽略。
6. 用 `pos == target && !moving`（或 `result == completed`）判断到位，用 `result` 区分
   `rejected` / `limited` / `stopped`。
7. `SET_POS` 用步数（不是圈）；标定后下发 `SET_LIMITS`，否则默认限位是 ±20 圈。

不要做：

1. 不要用 `TMC_QUERY` / `QUERY` 当心跳（不刷新看门狗）；心跳用重复 `SET_POS`/`JOG`。
2. 不要把 `ARMED` 单独当"正在被监视"；看 `ARMED && MOVING`。
3. 不要依赖 `STATUS_V2.fault`（恒 0）。
4. 不要假设 `reserved`/未知 `flags` 位为 0 是错误。
5. 不要多个控制器同时发命令（最后到达者赢）。
6. 不要指望固件保存位置/使能状态；重连后自己重新使能并重新标定。

---

## 11. 真机已验证样例（十六进制）

以下全部是实测抓包（板子 `FF-75A578`，固件 1.0.0，TMC2209）。

**闲置 + 已使能 + 待机断电**（发 `QUERY`，seq=0x2A）

```
→ 46 06 00 2A 00 00 00 00 00 00 00 00
← 4681ad2a e02e0000 e02e0000          STATUS: flags=0xAD(enabled|uart|standby, result=stopped), pos=target=12000
← 4683ad2a e02e0000 e02e0000 00 00 0000   V2: trusted=0, fault=0, reserved=0（未武装）
```

**`HOME`**（seq=0x2B）

```
← 46814d2b 00000000 00000000              STATUS: flags=0x4D(enabled|uart|standby, result=completed)
← 46834d2b 00000000 00000000 01 00 0000   V2: trusted=1（已建立原点）
```

**流式长移动**（`JOG +25000`，flags=0x00，被限位夹到 30000）

```
→ 46 02 00 50 50 61 00 00 00 00 00 00
← 46817750 70170000 30750000              STATUS: flags=0x77(enabled|moving|uart|limited, result=limited)
← 46817751 df2f0000 30750000              QUERY: 仍在运动
← 46837751 e62f0000 30750000 01 00 0100   V2: pos=12262 target=30000, reserved=0x0001 → 已武装
   ↑ 此刻静默 1 s 就会被刹停
```

**锁存长移动**（`JOG +25000`，flags=0x01）

```
→ 46 02 01 53 50 61 00 00 00 00 00 00
← 46817753 eb2f0000 30750000              STATUS: 与流式完全相同的运动状态
← 46837754 09490000 30750000 01 00 0000   V2: pos=18697, moving 且 reserved=0x0000 → 不武装（失联也不会停）
```

**未知命令**（`cmd = 0x33`，magic/长度合法）

```
→ 46 33 00 2C 07 00 00 00 F7 FF FF FF
← 46814d2c 00000000 00000000              只回一个 STATUS（不是错误码，也不是回显）
```

**畸形包原样回显**

```
→ DE AD BE EF                            ← DE AD BE EF
→ 99 06 00 00 01 00 00 00 02 00 00 00    ← 同样的 12 字节（magic 不是 0x46）
```

**发现回复**

```
← 46840101721001000092da7275a57846462d3735413537380000000000000000
  │  │ │ │ └─udp 4210 │  └─fw 1.0.0 │  mac 92:DA:72:75:A5:78 │  device_id "FF-75A578"
  │  │ │ └ protocol=1                └ kind=1 = 跟焦器
  │  │ └ cmd=0x84
  │  └ magic=0x46
```

**`TMC_QUERY`**（22 字节）

```
← 46820101900110000400062100c0000000c07200ffff
  uart_ok=1 stealth=1 rms=400mA ms=16 toff=4 ihold=0 irun=6 ver=0x21 cs=0
  drv_flags=0xC0(STST|STEALTH) drv_status=0xC0000000 sg=0x0072 tstep=0xFFFF
```

---

## 12. 调试工具与验收

| 工具 | 用途 |
| --- | --- |
| `python firmware/tools/discover.py` | 逐网卡广播发现，打印 device_id / fw / mac / IP（多网卡机器必须用它，别用普通 socket 广播） |
| `python firmware/tools/jog.py status|enable|pos N|jog N|stop|limits MIN MAX|speed HZ ACCEL` | 手工点动；加 `--latch` 走单次锁存。注意 `pos N` 是**移动到** N（`a` 省略时为 0），读当前状态用 `status` —— 未使能时 `pos 0` 会被拒绝，并留下 `armed = 1` / `result = rejected` |
| `python test/udp_motion_acceptance.py [--host 192.168.4.1]` | 黑盒运动验收，9 组用例，`exit 0` = 全过 |
| `python test/repro_jog_truncation.py [--reps 3]` | 复现"单发 JOG 被 1 s 看门狗截断"：流式/锁存四种模式对照，`exit 0` = 与文档一致。会真实驱动电机 |

验收覆盖：发现/状态、使能前置与拒绝、限位夹紧、点动、停止、通信看门狗超时、**单次锁存**、
待机断电。

---

## 13. 未实现 / 占位 / 已知边界

| 项 | 现状 |
| --- | --- |
| `STATUS_V2.fault` | 恒 0，占位。故障看 `TMC_DUMP.drv_flags` / `uart_ok` |
| 位置持久化 | 无。重启后 `pos = 0`、`position_trusted = 0` |
| 待机 ≠ 清 `position_trusted` | 刻意保留（§8 已说明），上位机若要严格语义需自己处理 |
| 命令鉴权 / 会话 | 无。同一 AP 内任何客户端都能控制，靠 §1.1 的约定约束 |
| 固件签名/加密 | 无。AP 密码 `ffdebug1` 是唯一的门槛 |
| 多板同场 | 发现回复里有 `mac`/`device_id` 可区分，但控制目标需上位机自己选择 IP |
