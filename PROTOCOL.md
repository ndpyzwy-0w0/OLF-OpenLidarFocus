# ESP32 ↔ App UDP 协议 v2（FM03）

端口4210，magic=0x46，小端。请求严格12字节：`magic:u8 cmd:u8 flags:u8 sequence:u8 a:i32 b:i32`。sequence=1～255；运动请求 flags.bit0=1 表示锁存，否则必须持续发送 SET_POS/JOG，运动时1秒静默归零。QUERY 不喂运动看门狗。

v2 沿用通用运动命令号，但坐标单位改为 FM03 标定行程坐标。必须搭配 App2.x 和固件2.x，发现 protocol=2。0x08/0x09/0x82（旧 TMC）不再支持，不映射到新参数。

## 命令

- 0x01 SET_POS：a=目标坐标（软件置零后的坐标系），夹入软件限位和原始0～4096范围。
- 0x02 JOG：a=坐标增量，从最新反馈位置计算。
- 0x03 STOP：普通速度归零，目标设为当前位置；固件2.0.5起同时禁用普通运动，新ENABLE前拒绝SET_POS/JOG。不取消FM03内部自主校准。
- 0x04 ENABLE：a=0/1；开机不使能，有新鲜CAN反馈才允许使能。校准时无法重新使能。
- 0x05 SET_LIMITS：a/b=下/上限；lo>hi拒绝，不交换。
- 0x06 QUERY：依次回 STATUS（12字节）、STATUS_V2（16字节）。
- 0x07 SET_SPEED：a=最大拨轮速度1～256，b保留为0。不表示步频/角速度。
- 0x0A HOME：停止且阶段3有效时，将当前原始坐标设为软件0；不发送电机校准。回STATUS及V2。
- 0x0B DISCOVER：只回32字节0x84发现包，固件2.0.0、protocol=2。
- 0x0C CAL_START：sequence为run_id，a/b保留为0；同一run幂等，仅一次发送内部校准报文。
- 0x0D CAL_QUERY：a为run_id，只查询内部校准观察结果，不延长运动租约。
- 0x0E CAL_CANCEL：只退出本地结果；内部标定活动时回error=11并保留观察锁，不能取消机械动作。
- 0x10 FM03_QUERY：只回28字节0x86状态（固件2.1.0起）。
- 0x11 FM03_SET：a为key、b为value；1最大速度1～256、2容差1～64、3减速系数1～64、4启动加速1～64（每50ms增加的拨轮值，默认8）；运动/标定时拒绝配置。保存到NVS `fm03`。

普通运动及查询以外的配置默认回12字节STATUS。CAL命令只回32字节CAL_STATUS。FM03_SET回当前FM03_DUMP，拒绝时参数不变。未知命令回STATUS；非协议短包原样回显。

## 状态

STATUS（0x81，12字节）与请求同布局，a=反馈当前位置，b=目标。flags：bit0使能、bit1普通位置控制活动、bit2 CAN反馈新鲜、bit3保留0、bit4目标被限位、bit5～7结果。结果0 idle、1 accepted、2 completed、3 limited、4 rejected、5 stopped。

STATUS_V2（0x83，16字节）：前12字节同STATUS；offset12 position_trusted:u8、13 fault:u8、14 reserved:u16（bit0运动看门狗武装）。fault=0正常、1总线/发送/丢帧异常、2反馈无效/过期/epoch变化、3无进展/运动总超时、4控制通信超时（固件2.0.2起；旧固件归入2）。旧位置可在失联时保留，但 position_trusted=false，不能用于运动；OLED不可信位置显示`--`。

FM03_DUMP（0x86，固件2.1.0起28字节；旧固件26字节）：offset0 magic、1 cmd、2 online、3 stage（255未知、0未校准、1/2内部校准、3可用）；4 value:i16（最近发送拨轮值）；6 max_speed:u16；8 tolerance:u16；10 gain:u16；12 raw_position:i32；16 tx_failures:u32；20 rx_missed:u32；24 feedback_age:u16 ms（65535无反馈/饱和）。offset26 acceleration:u16（1～64，默认8）。新App兼容旧26字节回包，将启动加速标为不支持；旧App须同步升级才能解码28字节回包。原始阶段1/2哨兵不得当位置使用。

CAL_STATUS（0x85，32字节）保留布局：offset2 state、3 sequence、4 error、5 run_id、6保留0、7 valid；8 pos:i32；12 travel:i32；16 safe_min:i32；20 safe_max:i32；24保留u16；26 coordinate_scale:u16=1（旧名microsteps）；28 elapsed_ms:u32。

state=0 idle，1内部阶段1/等待启动，3内部阶段2，5 completed，6本地结果清除，7失败。成功需先观察请求之后的新阶段1/2，再看到有效阶段3；travel=4096、safe_min=0、safe_max=4096，完成位置可在任意0～4096处。error=0正常、1run_id为0或保留参数非0、2忙/未使能、3CAN异常、6超过60秒观察窗口、11内部取消不支持。error非零时仍可能在自主校准，不能依据错误码断言机械停止。

发现包与v1的32字节布局相同：offset2 kind=1、3 protocol=2、4 UDP端口u16、6～8固件版本、9～14 AP MAC、15～30设备ID、31保留。
