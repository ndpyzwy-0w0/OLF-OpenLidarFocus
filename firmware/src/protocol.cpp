#include "protocol.h"
#include "device.h"
#include "motor.h"

#include <Arduino.h>
#include <string.h>

static WiFiUDP *udp = nullptr;
static uint8_t buf[64];

// Shared by STATUS and STATUS_V2 so both report the same command result: a move
// that actually finished must not still look "accepted".
static MotorCommandResult effectiveResult() {
  if (motorCalibrationActive()) return motorCommandResult();
  MotorCommandResult result = motorCommandResult();
  if (result == MOTOR_RESULT_ACCEPTED && !motorMoving() &&
      motorPos() == motorTarget()) {
    return MOTOR_RESULT_COMPLETED;
  }
  return result;
}

static void fillStatus(FfPacket *p, uint8_t sequence = 0) {
  p->magic = kFfMagic;
  p->cmd = FF_STATUS;
  p->flags = 0;
  if (motorEnabled()) p->flags |= FF_FLAG_ENABLED;
  if (motorMoving()) p->flags |= FF_FLAG_MOVING;
  if (motorUartOk()) p->flags |= FF_FLAG_UART_OK;
  if (motorStandbyOff()) p->flags |= FF_FLAG_STANDBY;
  if (motorLimitHit()) p->flags |= FF_FLAG_LIMITED;
  p->flags |= (static_cast<uint8_t>(effectiveResult()) << FF_RESULT_SHIFT) &
              FF_RESULT_MASK;
  p->pad = sequence;
  p->a = motorPos();
  p->b = motorTarget();
}

void protocolSendStatusV2(const IPAddress &ip, uint16_t port, uint8_t sequence) {
  if (!udp) return;
  FfStatusV2 p{};
  p.magic = kFfMagic;
  p.cmd = FF_STATUS_V2;
  p.sequence = sequence;
  p.flags = 0;
  if (motorEnabled()) p.flags |= FF_FLAG_ENABLED;
  if (motorMoving()) p.flags |= FF_FLAG_MOVING;
  if (motorUartOk()) p.flags |= FF_FLAG_UART_OK;
  if (motorStandbyOff()) p.flags |= FF_FLAG_STANDBY;
  if (motorLimitHit()) p.flags |= FF_FLAG_LIMITED;
  p.flags |= (static_cast<uint8_t>(effectiveResult()) << FF_RESULT_SHIFT) &
             FF_RESULT_MASK;
  p.pos = motorPos();
  p.target = motorTarget();
  p.position_trusted = motorPositionTrusted() ? 1 : 0;
  p.fault = 0;
  p.reserved = motorWatchdogArmed() ? FF_V2_WATCHDOG_ARMED : 0;
  udp->beginPacket(ip, port);
  udp->write(reinterpret_cast<uint8_t *>(&p), sizeof(p));
  udp->endPacket();
}

void protocolSendStatus(const IPAddress &ip, uint16_t port, uint8_t sequence) {
  if (!udp) return;
  FfPacket p;
  fillStatus(&p, sequence);
  udp->beginPacket(ip, port);
  udp->write(reinterpret_cast<uint8_t *>(&p), sizeof(p));
  udp->endPacket();
}

void protocolSendDiscovery(const IPAddress &ip, uint16_t port) {
  if (!udp) return;
  FfDiscovery d{};
  d.magic = kFfMagic;
  d.cmd = FF_DISCOVER_REPLY;
  d.kind = kFfKindFollowFocus;
  d.protocol = kFfProtocolVersion;
  d.udp_port = kUdpPort;
  d.fw_major = kFwMajor;
  d.fw_minor = kFwMinor;
  d.fw_patch = kFwPatch;
  memcpy(d.mac, deviceMac(), sizeof(d.mac));
  strncpy(d.device_id, deviceId(), sizeof(d.device_id) - 1);
  udp->beginPacket(ip, port);
  udp->write(reinterpret_cast<uint8_t *>(&d), sizeof(d));
  udp->endPacket();
  Serial.printf("discover %s -> %s:%u\n", d.device_id, ip.toString().c_str(),
                port);
}

static void protocolSendTmc(const IPAddress &ip, uint16_t port) {
  if (!udp) return;
  TmcSnap s;
  motorTmcSnap(&s);
  FfTmcDump d{};
  d.magic = kFfMagic;
  d.cmd = FF_TMC_DUMP;
  d.uart_ok = s.uartOk ? 1 : 0;
  d.stealth = s.stealth ? 1 : 0;
  d.rms_ma = s.rmsMa;
  d.microsteps = s.microsteps;
  d.toff = s.toff;
  d.ihold = s.ihold;
  d.irun = s.irun;
  d.version = s.version;
  d.cs_actual = s.csActual;
  d.drv_flags = s.flags;
  d.drv_status = s.drvStatus;
  d.sg = s.sg;
  d.tstep = s.tstep;
  udp->beginPacket(ip, port);
  udp->write(reinterpret_cast<uint8_t *>(&d), sizeof(d));
  udp->endPacket();
  Serial.printf(
      "tmc uart=%u stealth=%u rms=%u ms=%u toff=%u ihold=%u irun=%u ver=%u cs=%u "
      "sg=%u tstep=%u drv=0x%08lx flags=0x%02x\n",
      d.uart_ok, d.stealth, d.rms_ma, d.microsteps, d.toff, d.ihold, d.irun,
      d.version, d.cs_actual, d.sg, d.tstep, (unsigned long)d.drv_status, d.drv_flags);
}

static void sendCalibration(const IPAddress &ip, uint16_t port, uint8_t sequence,
                            uint8_t error = CAL_OK) {
  const auto s = motorCalibrationSnapshot();
  FfCalibrationStatus p{};
  p.magic = kFfMagic; p.cmd = FF_CAL_STATUS;
  p.state = s.state; p.sequence = sequence;
  p.error = error ? error : s.error;
  p.run_id = s.runId; p.threshold = s.threshold; p.valid = s.valid;
  p.pos = motorPos(); p.travel = s.travel;
  p.safe_min = motorMin(); p.safe_max = motorMax();
  p.sg = s.sg; p.microsteps = s.microsteps; p.elapsed_ms = s.elapsedMs;
  udp->beginPacket(ip, port);
  udp->write(reinterpret_cast<uint8_t *>(&p), sizeof(p));
  udp->endPacket();
}

static void handle(const FfPacket &in, const IPAddress &ip, uint16_t port) {
  switch (in.cmd) {
    case FF_CAL_START: {
      const uint8_t error = motorCalibrationStart(in.pad, in.a, in.b);
      sendCalibration(ip, port, in.pad, error);
      return;
    }
    case FF_CAL_QUERY:
      motorCalibrationKeepalive(in.a);
      sendCalibration(ip, port, in.pad);
      return;
    case FF_CAL_CANCEL:
      motorCalibrationCancel();
      sendCalibration(ip, port, in.pad);
      return;
    case FF_SET_POS:
      motorNoteControlPacket((in.flags & FF_REQ_LATCH) != 0);
      motorSetPos(in.a);
      break;
    case FF_JOG:
      motorNoteControlPacket((in.flags & FF_REQ_LATCH) != 0);
      motorJog(in.a);
      break;
    case FF_STOP:
      motorStop();
      break;
    case FF_ENABLE:
      motorSetEnabled(in.a != 0);
      break;
    case FF_HOME:
      motorSetHome();
      protocolSendStatus(ip, port, in.pad);
      protocolSendStatusV2(ip, port, in.pad);
      return;
    case FF_SET_LIMITS:
      motorSetLimits(in.a, in.b);
      break;
    case FF_SET_SPEED:
      motorSetSpeed(in.a, in.b);
      break;
    case FF_TMC_QUERY:
      protocolSendTmc(ip, port);
      return;
    case FF_TMC_SET:
      Serial.printf("tmc set key=%ld val=%ld\n", (long)in.a, (long)in.b);
      motorTmcSet(in.a, in.b);
      protocolSendTmc(ip, port);
      return;
    case FF_DISCOVER:
      protocolSendDiscovery(ip, port);
      return;  // Motion state is irrelevant here; skip the status replies.
    case FF_QUERY:
      break;
    default:
      break;
  }
  protocolSendStatus(ip, port, in.pad);
  if (in.cmd == FF_QUERY) {
    protocolSendStatusV2(ip, port, in.pad);
  }
}

void protocolBegin(WiFiUDP *u) {
  udp = u;
}

void protocolPoll() {
  if (!udp) return;
  int n = udp->parsePacket();
  if (n <= 0) return;
  if (n > (int)sizeof(buf)) n = sizeof(buf);
  n = udp->read(buf, n);
  IPAddress ip = udp->remoteIP();
  uint16_t port = udp->remotePort();
  if (n >= (int)sizeof(FfPacket) && buf[0] == kFfMagic) {
    FfPacket pkt;
    memcpy(&pkt, buf, sizeof(pkt));
    handle(pkt, ip, port);
    return;
  }
  udp->beginPacket(ip, port);
  udp->write(buf, n);
  udp->endPacket();
}
