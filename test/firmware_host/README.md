# FM03 固件主机模拟

直接编译生产 `motor.cpp` 和 `protocol.cpp`，模拟 TWAI、时间和 CAN 反馈，不连接硬件。

```sh
c++ -std=c++17 -Itest/firmware_host -Ifirmware/include test/firmware_host/fm03_test.cpp -o /tmp/olf-fm03-test
/tmp/olf-fm03-test
```

覆盖 CAN ID/分片/CRC、正反方向反馈控制、400ms稳定到位、软件限位、溢出增量、通信/反馈/无进展超时、TX失败/RX丢帧、软件置零、内部校准幂等、无法软件取消、校准后0～4096及UDP26/16字节回包。

模拟不证明实际电机角度、回差、齿轮啮合、对焦精度或接线正确。机械验收见根目录 HANDOFF.md。
