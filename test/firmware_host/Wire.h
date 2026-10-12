#pragma once
#include <stdint.h>
struct FakeWire {
  void begin(int, int) {}
  void setClock(uint32_t) {}
  void beginTransmission(uint8_t) {}
  int endTransmission() { return 0; }
};
inline FakeWire Wire;
