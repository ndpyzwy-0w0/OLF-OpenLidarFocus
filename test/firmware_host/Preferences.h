#pragma once
#include <stdint.h>
struct Preferences {
  bool begin(const char*,bool) { return true; }
  uint16_t getUShort(const char*,uint16_t v) { return v; }
  uint8_t getUChar(const char*,uint8_t v) { return v; }
  void putUShort(const char*,uint16_t) {}
  void putUChar(const char*,uint8_t) {}
  void end() {}
};
