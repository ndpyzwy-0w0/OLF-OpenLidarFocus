#pragma once

#include <stdint.h>

// Super Mini header is GPIO0–13 (+ USB 19/20, LED 48). Avoid 0 BOOT.
// TMC2209 single-wire UART: GPIO12 (same-pin half-duplex) -> module RX pad.
// GPIO11 <- TMC2209 DIAG; GPIO12 remains the verified UART pin.
static const int PIN_STEP = 5;
static const int PIN_DIR = 6;
static const int PIN_EN = 7;
static const int PIN_TMC_DIAG = 11;
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
bool motorSetHome();
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
bool motorPositionTrusted();
// 记录一次控制包到达。latched=false（流式）会重新武装通信看门狗，要求 App 持续发包；
// latched=true（单次锁存）只更新时间戳并解除看门狗，本次移动由固件跑完。
void motorNoteControlPacket(bool latched = false);
// 通信看门狗是否武装：武装 + 运动中 + 静默超过阈值 => 固件刹停。
bool motorWatchdogArmed();
void motorCommunicationTick();
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
  /// 最近一次 DRV_STATUS 读成功了吗。**只对串口诊断有意义**：协议里的
  /// `drv_status` 读失败时按 0 发，和“真读到 0”在线上分不开（见 §14）。
  bool drvStatusValid;
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
  /// DIAG（GPIO11）的累计上升沿数与当前电平，**只用于串口诊断**。
  ///
  /// 用途：堵转判定依赖这根线。静止时边沿数若还在涨 = 纯噪声；只有电机运动时涨 =
  /// 接错脚/与步进线串扰；两边都不涨而标定仍一动就停 = 芯片真的在报（阈值问题）。
  uint32_t diagEdges;
  bool diagLevel;
};

void motorTmcSnap(TmcSnap *o);
void motorTmcSet(int32_t key, int32_t val);
/// 寄存器读的累计失败次数（串口诊断用，协议里没有多余位能带它）。
uint32_t motorTmcReadFails();

enum MotorCommandResult : uint8_t {
  MOTOR_RESULT_IDLE = 0,
  MOTOR_RESULT_ACCEPTED = 1,
  MOTOR_RESULT_COMPLETED = 2,
  MOTOR_RESULT_LIMITED = 3,
  MOTOR_RESULT_REJECTED = 4,
  MOTOR_RESULT_STOPPED = 5,
};

MotorCommandResult motorCommandResult();

enum CalibrationState : uint8_t {
  CAL_IDLE, CAL_SEEK_NEGATIVE, CAL_BACKOFF_NEGATIVE, CAL_SEEK_POSITIVE,
  CAL_BACKOFF_POSITIVE, CAL_COMPLETED, CAL_CANCELLED, CAL_FAILED,
};
enum CalibrationError : uint8_t {
  CAL_OK, CAL_BAD_PARAMETER, CAL_BUSY, CAL_UART, CAL_DRIVER, CAL_DISTANCE,
  CAL_TIMEOUT, CAL_LINK_TIMEOUT, CAL_SAMPLE_TIMEOUT, CAL_SHORT_TRAVEL, CAL_USER_CANCEL,
  CAL_DIAG,
};
struct CalibrationSnapshot {
  uint8_t state, error, runId, threshold;
  bool valid;
  int32_t travel;
  uint16_t sg, microsteps;
  uint32_t elapsedMs;
};
bool motorCalibrationActive();
uint8_t motorCalibrationStart(uint8_t runId, int32_t threshold, int32_t maxTravel);
void motorCalibrationKeepalive(int32_t runId);
void motorCalibrationCancel();
CalibrationSnapshot motorCalibrationSnapshot();
