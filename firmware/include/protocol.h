#pragma once

#include <stdint.h>
#include <WiFiUdp.h>

// UDP v2: strict 12-byte request. Coordinates are FM03 feedback units.
enum FfCmd : uint8_t {
  FF_SET_POS = 0x01,
  FF_JOG = 0x02,
  FF_STOP = 0x03,
  FF_ENABLE = 0x04,
  FF_SET_LIMITS = 0x05,
  FF_QUERY = 0x06,
  FF_SET_SPEED = 0x07,
  FF_FM03_QUERY = 0x10,
  FF_FM03_SET = 0x11,
  FF_HOME = 0x0A,  // Establish the current stopped position as the trusted origin.
  FF_DISCOVER = 0x0B,  // Identify the board; answered with FF_DISCOVER_REPLY.
  FF_CAL_START = 0x0C,
  FF_CAL_QUERY = 0x0D,
  FF_CAL_CANCEL = 0x0E,
  FF_STATUS = 0x81,
  FF_FM03_DUMP = 0x86,
  FF_STATUS_V2 = 0x83,
  FF_DISCOVER_REPLY = 0x84,
  FF_CAL_STATUS = 0x85,
};

enum FfFm03Key : int32_t { FM03_MAX_SPEED=1, FM03_TOLERANCE=2, FM03_GAIN=3, FM03_ACCELERATION=4 };

enum FfFlag : uint8_t {
  FF_FLAG_ENABLED = 1,
  FF_FLAG_MOVING = 2,
  FF_FLAG_CAN_OK = 4,
  FF_FLAG_STANDBY = 8,  // v2 保留，始终为0
  FF_FLAG_LIMITED = 16, // 最近一次位置命令被软限位夹紧
};

// 请求包的 flags 字节（偏移 2）在命令方向另有含义，回包仍用 FfFlag：
//   位 0 为 0 = 流式（默认）。命令纳入通信看门狗：运动期间 App 必须持续发新的
//               控制包，静默超过看门狗阈值即被刹停。
//   位 0 为 1 = 单次锁存。本次移动不纳入看门狗，App 发一次即可，固件自行跑完；
//               此时若 App 失联，移动会走到目标再停下（软限位照常生效）。
// 只有 SET_POS / JOG 解释该字节，其它命令忽略。未定义的位保留，固件忽略未知位。
static const uint8_t FF_REQ_LATCH = 0x01;

// FfStatusV2.reserved 位定义。
// 1 = 通信看门狗已武装：运动期间 App 寂静超过阈值就会被刹停，必须持续发包。
// 武装后要等 STOP / ENABLE(0) / HOME / 看门狗超时才会解除，所以静止时也可能读到 1，
// 判断“现在必须持续发包吗”要与 FF_FLAG_MOVING 一起看。
static const uint16_t FF_V2_WATCHDOG_ARMED = 0x0001;

bool protocolLinkAlive();

// Upper three flag bits carry the latest command result.
static const uint8_t FF_RESULT_SHIFT = 5;
static const uint8_t FF_RESULT_MASK = 0xE0;

struct FfPacket {
  uint8_t magic;
  uint8_t cmd;
  uint8_t flags;
  uint8_t pad;
  int32_t a;
  int32_t b;
} __attribute__((packed));

static_assert(sizeof(FfPacket) == 12, "FfPacket must be 12 bytes");

struct FfFm03Dump {
  uint8_t magic, cmd, online, stage;
  int16_t value;
  uint16_t max_speed, tolerance, gain;
  int32_t raw_position;
  uint32_t tx_failures, rx_missed;
  uint16_t feedback_age;
  uint16_t acceleration;
} __attribute__((packed));
static_assert(sizeof(FfFm03Dump)==28, "FfFm03Dump must be 28 bytes");

struct FfStatusV2 {
  uint8_t magic;
  uint8_t cmd;
  uint8_t flags;
  uint8_t sequence;
  int32_t pos;
  int32_t target;
  uint8_t position_trusted;
  uint8_t fault;
  uint16_t reserved;
} __attribute__((packed));

static_assert(sizeof(FfStatusV2) == 16, "FfStatusV2 must be 16 bytes");

struct FfCalibrationStatus {
  uint8_t magic, cmd, state, sequence;
  uint8_t error, run_id, threshold, valid;
  int32_t pos, travel, safe_min, safe_max;
  uint16_t sg, microsteps;
  uint32_t elapsed_ms;
} __attribute__((packed));
static_assert(sizeof(FfCalibrationStatus) == 32, "FfCalibrationStatus must be 32 bytes");

// Discovery reply. A host that has just associated with an AP uses this to tell
// whether it is talking to this firmware and which board it is. `mac` matches
// the BSSID a scan reports and `device_id` matches the SSID, so a scan result,
// a device id and a control connection can all be tied to the same board.
static const uint8_t kFfKindFollowFocus = 1;
static const uint8_t kFfProtocolVersion = 2;

struct FfDiscovery {
  uint8_t magic;
  uint8_t cmd;
  uint8_t kind;      // kFfKindFollowFocus
  uint8_t protocol;  // kFfProtocolVersion
  uint16_t udp_port;
  uint8_t fw_major;
  uint8_t fw_minor;
  uint8_t fw_patch;
  uint8_t mac[6];
  char device_id[16];  // NUL terminated, e.g. "FF-75A578"
  uint8_t reserved;
} __attribute__((packed));

static_assert(sizeof(FfDiscovery) == 32, "FfDiscovery must be 32 bytes");

static const uint8_t kFfMagic = 0x46;
static const uint16_t kUdpPort = 4210;

void protocolBegin(WiFiUDP *udp);
void protocolPoll();
// The packet pad byte is an optional request sequence. Legacy clients may send 0.
void protocolSendStatus(const IPAddress &ip, uint16_t port, uint8_t sequence = 0);
void protocolSendStatusV2(const IPAddress &ip, uint16_t port, uint8_t sequence = 0);
void protocolSendDiscovery(const IPAddress &ip, uint16_t port);
