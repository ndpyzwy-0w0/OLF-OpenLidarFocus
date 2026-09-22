#include "protocol.h"
#include "motor.h"

#include <Arduino.h>
#include <string.h>

static WiFiUDP *udp = nullptr;
static uint8_t buf[64];

static void fillStatus(FfPacket *p, uint8_t sequence = 0) {
  p->magic = kFfMagic;
  p->cmd = FF_STATUS;
  p->flags = 0;
  if (motorEnabled()) p->flags |= FF_FLAG_ENABLED;
  if (motorMoving()) p->flags |= FF_FLAG_MOVING;
  if (motorUartOk()) p->flags |= FF_FLAG_UART_OK;
  if (motorStandbyOff()) p->flags |= FF_FLAG_STANDBY;
  if (motorLimitHit()) p->flags |= FF_FLAG_LIMITED;
  MotorCommandResult result = motorCommandResult();
  if (result == MOTOR_RESULT_ACCEPTED && !motorMoving() &&
      motorPos() == motorTarget()) {
    result = MOTOR_RESULT_COMPLETED;
  }
  p->flags |= (static_cast<uint8_t>(result) << FF_RESULT_SHIFT) & FF_RESULT_MASK;
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
  p.flags |= (static_cast<uint8_t>(motorCommandResult()) << FF_RESULT_SHIFT) &
             FF_RESULT_MASK;
  p.pos = motorPos();
  p.target = motorTarget();
  p.position_trusted = motorPositionTrusted() ? 1 : 0;
  p.fault = 0;
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

static void handle(const FfPacket &in, const IPAddress &ip, uint16_t port) {
  switch (in.cmd) {
    case FF_SET_POS:
      motorNoteControlPacket();
      motorSetPos(in.a);
      break;
    case FF_JOG:
      motorNoteControlPacket();
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
