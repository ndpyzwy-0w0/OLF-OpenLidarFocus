#pragma once
#include <stdint.h>

// ESP32-S3 Super Mini 保留；3.3V CAN 收发器 D/TXD→GPIO4，R/RXD→GPIO5。
static const int PIN_CAN_TX = 4;
static const int PIN_CAN_RX = 5;
void motorBegin();
void motorPoll();
void motorSetPos(int32_t coordinate);
void motorJog(int32_t delta);
void motorStop();
void motorSetEnabled(bool on);
bool motorSetHome();
void motorSetLimits(int32_t lo, int32_t hi);
// a 为最大拨轮速度 1..256；b 保留。不表示角速度。
void motorSetSpeed(int32_t value, int32_t reserved);
int32_t motorPos();
int32_t motorTarget();
int32_t motorMin();
int32_t motorMax();
bool motorEnabled();
bool motorMoving();
bool motorLimitHit();
bool motorCanOk();
bool motorPositionTrusted();
void motorNoteControlPacket(bool latched = false);
bool motorWatchdogArmed();
uint8_t motorFault();
struct Fm03Snapshot {
  bool online, enabled, moving;
  uint8_t stage;
  int16_t value;
  uint16_t maxSpeed, tolerance, gain;
  int32_t rawPosition;
  uint32_t txFailures, rxMissed;
  uint16_t feedbackAge;
};
Fm03Snapshot motorFm03Snapshot();
void motorFm03Set(int32_t key, int32_t value);
enum MotorCommandResult : uint8_t {
  MOTOR_RESULT_IDLE, MOTOR_RESULT_ACCEPTED, MOTOR_RESULT_COMPLETED,
  MOTOR_RESULT_LIMITED, MOTOR_RESULT_REJECTED, MOTOR_RESULT_STOPPED,
};
MotorCommandResult motorCommandResult();
enum CalibrationState : uint8_t {
  CAL_IDLE, CAL_SEEK_NEGATIVE, CAL_BACKOFF_NEGATIVE, CAL_SEEK_POSITIVE,
  CAL_BACKOFF_POSITIVE, CAL_COMPLETED, CAL_CANCELLED, CAL_FAILED,
};
enum CalibrationError : uint8_t {
  CAL_OK, CAL_BAD_PARAMETER, CAL_BUSY, CAL_CAN, CAL_DRIVER, CAL_DISTANCE,
  CAL_TIMEOUT, CAL_LINK_TIMEOUT, CAL_SAMPLE_TIMEOUT, CAL_SHORT_TRAVEL,
  CAL_USER_CANCEL, CAL_CANCEL_UNSUPPORTED,
};
struct CalibrationSnapshot {
  uint8_t state, error, runId, threshold;
  bool valid;
  int32_t travel;
  uint16_t sg, microsteps;
  uint32_t elapsedMs;
};
bool motorCalibrationActive();
uint8_t motorCalibrationStart(uint8_t runId, int32_t reservedA, int32_t reservedB);
void motorCalibrationKeepalive(int32_t runId);
void motorCalibrationCancel();
CalibrationSnapshot motorCalibrationSnapshot();
