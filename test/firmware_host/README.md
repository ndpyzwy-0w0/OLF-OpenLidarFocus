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
CRC/通信失败、驱动故障、超行程、过短/全低 SG、阶段/保活/ISR 超时、
STOP/取消使能、指令互斥、重复 START 幂等及新旧协议的长度/回包数量。
