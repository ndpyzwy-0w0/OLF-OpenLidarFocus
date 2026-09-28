# 固件主机模拟测试

直接编译生产 `motor.cpp` 和 `protocol.cpp`，用模拟 UART/机械挡块/GPIO/定时器运行。
测试不连接设备，不代表真实镜头的 StallGuard 灵敏度或测量精度验收。

Windows（VS x64 Native Tools 命令提示符，从仓库根目录）：

```bat
cl /nologo /utf-8 /std:c++17 /EHsc /Itest/firmware_host /Ifirmware/include test/firmware_host/calibration_test.cpp /Fofirmware/.pio/calibration_test.obj /Fefirmware/.pio/calibration_test.exe
firmware\.pio\calibration_test.exe
```

macOS/Linux（已有 C++17 编译器，先创建 `firmware/.pio`）：

```sh
c++ -std=c++17 -Itest/firmware_host -Ifirmware/include test/firmware_host/calibration_test.cpp -o firmware/.pio/calibration_test
firmware/.pio/calibration_test
```

覆盖成功寻双端、留余量、保持坐标、恢复模式/速度、IFCNT 回绕/丢写、
CRC/通信失败、驱动故障、超行程、过短行程、阶段/保活/ISR 超时、
STOP/取消使能、指令互斥、重复 START 幂等及新旧协议的长度/回包数量。

## DIAG（GPIO11）模拟

2026-09-28 起端点判定从"读 SG_RESULT"改成"DIAG 上升沿 + 电平"，`Arduino.h` 里补了
`digitalRead`/`pinMode` 上拉下拉/`attachInterrupt` 的模拟。三个旋钮：

| 旋钮 | 作用 |
| --- | --- |
| `diagWired`（默认 true） | false = 引脚悬空 → 跟随内部上拉/下拉，固件据此拒绝启动（`CAL_DIAG=11`） |
| 撞挡块自动拉高 | `driver/gpio.h` 里位置被夹在 `physicalMin/Max` 时 `fakeSetDiag(true)`，离开挡块自动回落 |
| `diagStallAfterMs`（默认 -1） | ≥0 = 每段跑满这么多毫秒就拉高 DIAG，模拟**堵转误判**（阈值过大）：现场真机就是这样每段只走 ~317 步 → `CAL_SHORT_TRAVEL` |

由此钉住的三条现场结论：DIAG 没接线必须在**运动前**拒绝；扫描期间**不轮询 UART**，
所以丢包/坏 CRC 不会中途打断，只在堵转后那次读里报 `CAL_UART`；堵转误判的后果是
`CAL_SHORT_TRAVEL`，不是新故障。

