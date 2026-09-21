#pragma once

#include <stdint.h>
#include <WiFiUdp.h>

// 12-byte little-endian packet. Magic 0x46 ('F'). Unknown packets are echoed.
enum FfCmd : uint8_t {
  FF_SET_POS = 0x01,
  FF_JOG = 0x02,
  FF_STOP = 0x03,
  FF_ENABLE = 0x04,
  FF_SET_LIMITS = 0x05,
  FF_QUERY = 0x06,
  FF_SET_SPEED = 0x07,
  FF_TMC_QUERY = 0x08,
  FF_TMC_SET = 0x09,
  FF_STATUS = 0x81,
  FF_TMC_DUMP = 0x82,
};

enum FfTmcKey : int32_t {
  TMC_RMS = 1,
  TMC_MICROSTEPS = 2,
  TMC_STEALTH = 3,
  TMC_TOFF = 4,
  TMC_IHOLD = 5,
  TMC_IRUN = 6,
};

enum FfFlag : uint8_t {
  FF_FLAG_ENABLED = 1,
  FF_FLAG_MOVING = 2,
  FF_FLAG_UART_OK = 4,
};

struct FfPacket {
  uint8_t magic;
  uint8_t cmd;
  uint8_t flags;
  uint8_t pad;
  int32_t a;
  int32_t b;
} __attribute__((packed));

static_assert(sizeof(FfPacket) == 12, "FfPacket must be 12 bytes");

struct FfTmcDump {
  uint8_t magic;
  uint8_t cmd;
  uint8_t uart_ok;
  uint8_t stealth;
  uint16_t rms_ma;
  uint16_t microsteps;
  uint8_t toff;
  uint8_t ihold;
  uint8_t irun;
  uint8_t version;
  uint8_t cs_actual;
  uint8_t drv_flags;
  uint32_t drv_status;
  uint16_t sg;
  uint16_t tstep;
} __attribute__((packed));

static_assert(sizeof(FfTmcDump) == 22, "FfTmcDump must be 22 bytes");

static const uint8_t kFfMagic = 0x46;
static const uint16_t kUdpPort = 4210;

void protocolBegin(WiFiUDP *udp);
void protocolPoll();
void protocolSendStatus(const IPAddress &ip, uint16_t port);
