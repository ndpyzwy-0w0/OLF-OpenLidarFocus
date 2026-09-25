#pragma once
#include <Arduino.h>
using gpio_num_t=int;
#define GPIO_DRIVE_CAP_0 0
#define GPIO_PULLUP_ONLY 0
inline void gpio_set_drive_capability(int,int) {}
inline void gpio_set_pull_mode(int,int) {}
inline void gpio_set_level(int pin,int level) {
  if(pin==5 && level) { ++pulses; physical=std::clamp(physical+direction,physicalMin,physicalMax); }
}
