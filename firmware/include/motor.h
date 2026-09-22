#pragma once

#include <stdint.h>

// Super Mini header is GPIO0–13 (+ USB 19/20, LED 48). Avoid 0 BOOT.
// TMC2209 single-wire UART: GPIO12 (same-pin half-duplex) -> module RX pad.
// GPIO11 unused; no series resistor. Verified: "U r12 t12 a0".
static const int PIN_STEP = 5;
static const int PIN_DIR = 6;
static const int PIN_EN = 7;
static const int PIN_TMC_TX = 11;
static const int PIN_TMC_RX = 12;

void motorBegin();
void motorUartBegin();
// 待机省电：静止一段时间后自动断使能（不发热、不震动）。
// 任何运动指令都会立刻唤醒；motorStandbyTick() 需要在 loop 里周期调用。
void motorStandbyTick();
bool motorStandbyOff();
void motorSetPos(int32_t steps);
void motorJog(int32_t delta);
void motorStop();
void motorSetEnabled(bool on);
void motorSetLimits(int32_t minSteps, int32_t maxSteps);
// hz 巡航速度（步/秒），accel 加速度（步/秒²）。
// 短行程跑不到巡航速度，峰值 ≈ sqrt(2*accel*距离)——想“更快”通常要加大 accel。
void motorSetSpeed(int32_t hz, int32_t accel);
int32_t motorPos();
int32_t motorTarget();
int32_t motorMin();
int32_t motorMax();
bool motorEnabled();
bool motorMoving();
bool motorLimitHit();
bool motorUartOk();
const char *motorUartHint();

enum TmcFlag : uint8_t {
  TMC_F_OT = 1,
  TMC_F_OTPW = 2,
  TMC_F_OLA = 4,
  TMC_F_OLB = 8,
  TMC_F_S2GA = 16,
  TMC_F_S2GB = 32,
  TMC_F_STST = 64,
  TMC_F_STEALTH = 128,
};

struct TmcSnap {
  bool uartOk;
  bool stealth;
  uint16_t rmsMa;
  uint16_t microsteps;
  uint8_t toff;
  uint8_t ihold;
  uint8_t irun;
  uint8_t version;
  uint8_t csActual;
  uint8_t flags;
  uint32_t drvStatus;
  uint16_t sg;
  uint16_t tstep;
};

void motorTmcSnap(TmcSnap *o);
void motorTmcSet(int32_t key, int32_t val);

enum MotorCommandResult : uint8_t {
  MOTOR_RESULT_IDLE = 0,
  MOTOR_RESULT_ACCEPTED = 1,
  MOTOR_RESULT_COMPLETED = 2,
  MOTOR_RESULT_LIMITED = 3,
  MOTOR_RESULT_REJECTED = 4,
  MOTOR_RESULT_STOPPED = 5,
};

MotorCommandResult motorCommandResult();
