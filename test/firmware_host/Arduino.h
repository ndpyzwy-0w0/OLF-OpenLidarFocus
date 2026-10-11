#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <cstring>
#include <cassert>
#include "freertos/semphr.h"
inline uint64_t fakeUs=1000000;
inline uint32_t millis() { return fakeUs/1000; }
inline void delay(uint32_t ms) { assert(stateLockDepth==0); fakeUs+=ms*1000; }
struct FakeSerial {
  template<class... T> void printf(const char*, T...) {}
  template<class T> void println(T) {}
};
inline FakeSerial Serial;
using portMUX_TYPE=int;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(x) ((void)0)
#define portEXIT_CRITICAL(x) ((void)0)
#define pdMS_TO_TICKS(x) (x)
#define portMAX_DELAY 0xffffffff
inline int xTaskCreate(void(*)(void*),const char*,int,void*,int,void*) { return 1; }
inline void vTaskDelay(int) {}
