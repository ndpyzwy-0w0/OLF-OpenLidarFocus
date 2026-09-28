#pragma once
#include <Arduino.h>
using gpio_num_t=int;
#define GPIO_DRIVE_CAP_0 0
#define GPIO_PULLUP_ONLY 0
inline void gpio_set_drive_capability(int,int) {}
inline void gpio_set_pull_mode(int,int) {}
inline void gpio_set_level(int pin,int level) {
  if(pin==5 && level) {
    ++pulses;
    const int before = physical;
    physical = std::clamp(physical+direction,physicalMin,physicalMax);
    // 撞到挡块就是堵转：真实板子上 TMC 的 DIAG 输出会拉高，固件靠这条线找端点。
    if (physical == before && (physical == physicalMin || physical == physicalMax)) {
      fakeSetDiag(true);
    } else if (physical != before) {
      fakeSetDiag(false); // 离开挡块，DIAG 回落
    }
  }
}
