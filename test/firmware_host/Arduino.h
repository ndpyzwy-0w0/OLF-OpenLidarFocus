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
inline bool allLow = false;
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
      if (d[2]==0x41) v=(allLow || physical<=physicalMin || physical>=physicalMax) ? 40 : 240;
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
inline void pinMode(int,int) {}
inline void digitalWrite(int pin,int v) { if(pin==6) direction=v?1:-1; }
using portMUX_TYPE=int;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(x) ((void)0)
#define portEXIT_CRITICAL(x) ((void)0)
#define portENTER_CRITICAL_ISR(x) ((void)0)
#define portEXIT_CRITICAL_ISR(x) ((void)0)
#define IRAM_ATTR
#define INPUT 0
#define OUTPUT 1
#define HIGH 1
#define LOW 0
#define SERIAL_8N1 0
struct hw_timer_t {};
inline hw_timer_t timer;
inline hw_timer_t* timerBegin(int,int,bool) { return &timer; }
inline void timerAttachInterrupt(hw_timer_t*, void(*)(), bool) {}
inline void timerAlarmWrite(hw_timer_t*,int,bool) {}
inline void timerAlarmEnable(hw_timer_t*) {}
