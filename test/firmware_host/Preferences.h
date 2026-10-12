#pragma once
#include <stdint.h>
struct Preferences {
  inline static unsigned writes = 0;
  bool begin(const char*,bool) { return true; }
  uint16_t getUShort(const char*,uint16_t v) { return v; }
  uint8_t getUChar(const char*,uint8_t v) { return v; }
  void putUShort(const char*,uint16_t) { ++writes; }
  void putUChar(const char*,uint8_t) {}
  void end() {}
};
