#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <algorithm>
#include <deque>
#include <string>
using std::min;
using std::max;
inline uint64_t fakeUs = 0;
inline uint32_t registers[128]{};
inline bool failUart = false, corruptCrc = false, dropWrite = false;
inline int physical = 1500, physicalMin = 0, physicalMax = 3000, direction = 1;
inline unsigned pulses = 0;
inline uint32_t fakeFault = 0;

// ---- DIAG / GPIO 模拟（GPIO11）---------------------------------------------
//
// DIAG 是 TMC 的**输出**：静止或正常负载时被拉低，堵转（StallGuard）或驱动故障
// 时拉高。固件用它做两端寻位，所以主机模拟必须给出这条线，否则连编译都过不去
// （2026-09-29 之前这里只有 pinMode/digitalWrite，DIAG 版固件是没跑过主机模拟的）。
//
// - `diagWired=false`：模拟"DIAG 没接"。引脚悬空 → 跟随内部上拉/下拉，
//   固件正是靠"上拉读 1、下拉读 0"判定未接线并拒绝启动（CAL_DIAG）。
// - `diagStallAfterMs >= 0`：本阶段跑满这么多毫秒后拉高 DIAG，模拟"堵转误判"，
//   也就是现场 SGTHRS 过大时每段只走 ~200 ms 就停的样子。
inline bool diagWired = true;
inline bool diagDriven = false;
inline int diagPull = 1;  // 当前 pinMode 的上/下拉模式
inline int diagStallAfterMs = -1;
inline void (*diagIsr)() = nullptr;
inline void fakeSetDiag(bool high) {
  if (high == diagDriven) return;
  diagDriven = high;
  if (high && diagIsr) diagIsr();  // 上升沿
}
inline uint8_t crc(const uint8_t* d, int n) {
  uint8_t c = 0;
  for (int i=0; i<n; ++i) {
    uint8_t b=d[i];
    for (int j=0; j<8; ++j) { c = ((c>>7)^(b&1)) ? (c<<1)^7 : c<<1; b >>= 1; }
  }
  return c;
}
struct FakeSerial {
  std::deque<uint8_t> bytes;
  void begin(int, int=0, int=0, int=0) {}
  void end() {}
  int available() { if (bytes.empty()) fakeUs += 100; return (int)bytes.size(); }
  int read() { int b=bytes.front(); bytes.pop_front(); return b; }
  void write(const uint8_t* d, size_t n) {
    if (failUart) return;
    if (n==8) {
      if (dropWrite) return;
      registers[d[2]&127] = uint32_t(d[3])<<24 | uint32_t(d[4])<<16 | uint32_t(d[5])<<8 | d[6];
      registers[2] = (registers[2]+1)&255;
    } else if (n==4) {
      uint32_t v=registers[d[2]];
      if (d[2]==0x6F) v=(1u<<30)|fakeFault;
      // SG_RESULT：只影响读数显示，标定端点已经改由 DIAG 判定。
      if (d[2]==0x41) v=(physical<=physicalMin || physical>=physicalMax) ? 40 : 240;
      if (d[2]==0x12) v=470;
      // These are write-only on the real chip; never fake readback support.
      if (d[2]==0x13 || d[2]==0x14 || d[2]==0x40 || d[2]==0x42) return;
      uint8_t r[8]={5,255,d[2],uint8_t(v>>24),uint8_t(v>>16),uint8_t(v>>8),uint8_t(v),0};
      r[7]=crc(r,7) ^ (corruptCrc ? 1 : 0);
      for (auto b:r) bytes.push_back(b);
    }
  }
  template<class... T> void printf(const char*, T...) {}
  template<class T> void println(T) {}
  void println() {}
};
inline FakeSerial Serial, Serial2;
inline uint32_t millis() { return uint32_t(fakeUs/1000); }
inline uint32_t micros() { return uint32_t(fakeUs); }
inline void delay(uint32_t n) { fakeUs+=n*1000; }
inline void delayMicroseconds(uint32_t n) { fakeUs+=n; }
inline void ets_delay_us(uint32_t) {}
// 引脚模式宏要在用它们的函数之前（原来这些 #define 排在文件末尾）。
#define INPUT 0
#define OUTPUT 1
#define INPUT_PULLUP 2
#define INPUT_PULLDOWN 3
#define RISING 4
#define FALLING 5
#define CHANGE 6
#define HIGH 1
#define LOW 0
/// 只关心 GPIO11（DIAG）的上/下拉：固件用它判断 DIAG 有没有接线。
inline void pinMode(int pin,int mode) { if(pin==11) diagPull=mode; }
inline int digitalRead(int pin) {
  if (pin != 11) return LOW;
  if (!diagWired) return diagPull == INPUT_PULLUP ? HIGH : LOW;
  return diagDriven ? HIGH : LOW;
}
inline void digitalWrite(int pin,int v) { if(pin==6) direction=v?1:-1; }
inline int digitalPinToInterrupt(int pin) { return pin; }
inline void attachInterrupt(int,void(*fn)(),int) { diagIsr=fn; }
inline void detachInterrupt(int) { diagIsr=nullptr; }
using portMUX_TYPE=int;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(x) ((void)0)
#define portEXIT_CRITICAL(x) ((void)0)
#define portENTER_CRITICAL_ISR(x) ((void)0)
#define portEXIT_CRITICAL_ISR(x) ((void)0)
#define IRAM_ATTR
#define SERIAL_8N1 0
struct hw_timer_t {};
inline hw_timer_t timer;
inline hw_timer_t* timerBegin(int,int,bool) { return &timer; }
inline void timerAttachInterrupt(hw_timer_t*, void(*)(), bool) {}
inline void timerAlarmWrite(hw_timer_t*,int,bool) {}
inline void timerAlarmEnable(hw_timer_t*) {}
