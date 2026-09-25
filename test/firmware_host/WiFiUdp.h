#pragma once
#include <stdint.h>
#include <string>
#include <vector>
class IPAddress { public: std::string toString() const { return "192.168.4.2"; } };
class WiFiUDP {
public:
  std::vector<std::vector<uint8_t>> sent;
  void beginPacket(const IPAddress&,uint16_t) { sent.emplace_back(); }
  void write(const uint8_t* p,size_t n) { sent.back().assign(p,p+n); }
  void endPacket() {}
  int parsePacket() { return 0; }
  int read(uint8_t*,int) { return 0; }
  IPAddress remoteIP() { return {}; }
  uint16_t remotePort() { return 4210; }
};
