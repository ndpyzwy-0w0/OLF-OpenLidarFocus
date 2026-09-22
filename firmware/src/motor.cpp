#include "motor.h"
#include "protocol.h"

#include <Arduino.h>
#include <Preferences.h>
#include <string.h>
#include <FastAccelStepper.h>
#include "driver/gpio.h"
#include "driver/uart.h"
#include "freertos/FreeRTOS.h"

static const float kRSense = 0.11f;
static const uint16_t kRmsMa = 800;
static const uint16_t kHoldMa = 200;  // 保持电流：低一点，待机不那么烫、也不易有轻微嗡震
static const uint16_t kMicrosteps = 16;
static const uint32_t kDefaultHz = 8000;
static const int32_t kDefaultAccel = 20000;

static FastAccelStepperEngine engine;
static FastAccelStepper *stepper = nullptr;
static char uartHint[24] = "UART ?";

// 软限位默认按“圈”算，随细分自动缩放。
// 为什么不能写死步数：1/16 时 20000 步 = 3.1 圈，1/256 时同样 20000 步只有 0.2 圈——
// 换细分后行程会被无声地夹没，表现就是“点了没反应”。
// App 标定后会下发 SET_LIMITS（按步数）覆盖这个默认值。
static const int32_t kFullStepsPerRev = 400;  // 0.9°/步 电机 → 400 整步/圈
static const int32_t kDefaultLimitRevs = 20;  // 未标定时的默认软限位（电机圈数）
static bool limExplicit = false;              // true = App 已下发过步数限位
static int32_t minLim = -20000;
static int32_t maxLim = 20000;
static int32_t target = 0;
static bool enabled = false;
static bool uartOk = false;
static bool limitHit = false;
static MotorCommandResult commandResult = MOTOR_RESULT_IDLE;

// 待机断电：用户仍处于“使能”意图，但物理上已释放驱动，避免静止时发热和轻微震动。
static bool standbyOff = false;
static uint8_t tmcStandby = 1;  // 1 = 开启待机断电
static uint32_t lastMoveMs = 0;
static const uint32_t kStandbyDelayMs = 2500;
static bool movePending = false;
static int32_t pendingTarget = 0;
static uint32_t pendingSince = 0;
static const uint32_t kMoveUpdateDelayMs = 50;

static uint8_t tmcSlave = 0;
static uint8_t tmcVer = 0;
static uint16_t tmcRmsMa = kRmsMa;
static uint16_t tmcHoldMa = kHoldMa;
static uint16_t tmcMsSet = kMicrosteps;
static uint8_t tmcToffSet = 4;
static uint8_t tmcStealthSet = 1;
static uint8_t tmcIntpolSet = 1;
static uint8_t tmcIholdCs = 0;
static uint8_t tmcIrunCs = 0;
static uint8_t tmcToff = 0;
static uint8_t tmcCs = 0;
static uint16_t tmcMs = kMicrosteps;
static uint32_t tmcDrv = 0;
static uint16_t tmcSg = 0;
static uint16_t tmcTstep = 0;

// 脉冲/圈 = 400 × 细分。
static int32_t stepsPerRevFw() {
  int32_t ms = tmcMsSet ? (int32_t)tmcMsSet : 1;
  return kFullStepsPerRev * ms;
}

// 未标定时把软限位重算成 ±kDefaultLimitRevs 圈，跟随当前细分。
static void recomputeLimits() {
  if (limExplicit) return;
  int32_t span = stepsPerRevFw() * kDefaultLimitRevs;
  minLim = -span;
  maxLim = span;
}

// ---- 参数持久化（NVS）----
// TMC 参数存进 flash，重启后不再回到默认值。
// 不持久化 enabled：开机自动使能电机是危险的，改由 App 在连上后自己重新使能。
static void tmcLoad() {
  Preferences p;
  if (!p.begin("tmc", true)) return;
  tmcRmsMa = p.getUShort("rms", kRmsMa);
  tmcHoldMa = p.getUShort("hold", kHoldMa);
  tmcMsSet = p.getUShort("ms", kMicrosteps);
  tmcToffSet = (uint8_t)p.getUChar("toff", 4);
  tmcStealthSet = (uint8_t)p.getUChar("stealth", 1);
  tmcIntpolSet = (uint8_t)p.getUChar("intpol", 1);
  tmcStandby = (uint8_t)p.getUChar("standby", 1);
  p.end();
}

static void tmcSave() {
  Preferences p;
  if (!p.begin("tmc", false)) return;
  p.putUShort("rms", tmcRmsMa);
  p.putUShort("hold", tmcHoldMa);
  p.putUShort("ms", tmcMsSet);
  p.putUChar("toff", tmcToffSet);
  p.putUChar("stealth", tmcStealthSet);
  p.putUChar("intpol", tmcIntpolSet);
  p.putUChar("standby", tmcStandby);
  p.end();
}

static uint8_t tmcCrc(const uint8_t *d, uint8_t len) {
  uint8_t crc = 0;
  for (uint8_t i = 0; i < len; i++) {
    uint8_t b = d[i];
    for (uint8_t j = 0; j < 8; j++) {
      if ((crc >> 7) ^ (b & 1)) crc = (uint8_t)((crc << 1) ^ 0x07);
      else crc <<= 1;
      b >>= 1;
    }
  }
  return crc;
}

static void tmcTxWait() {
  uart_wait_tx_done(UART_NUM_2, pdMS_TO_TICKS(20));
}

static void tmcUartOpen(int rx, int tx, uint32_t baud) {
  pinMode(PIN_TMC_TX, INPUT);
  pinMode(PIN_TMC_RX, INPUT);
  Serial2.end();
  delay(5);
  Serial2.begin(baud, SERIAL_8N1, rx, tx);
  if (rx == tx) {
    uart_set_mode(UART_NUM_2, UART_MODE_RS485_HALF_DUPLEX);
    gpio_set_drive_capability((gpio_num_t)tx, GPIO_DRIVE_CAP_0);
  } else {
    uart_set_mode(UART_NUM_2, UART_MODE_UART);
  }
  gpio_set_pull_mode((gpio_num_t)tx, GPIO_PULLUP_ONLY);
  if (rx != tx) gpio_set_pull_mode((gpio_num_t)rx, GPIO_PULLUP_ONLY);
  delay(30);
  while (Serial2.available()) Serial2.read();
}

static int tmcReadRaw(uint8_t slave, uint8_t reg, uint8_t *raw, int rawMax, uint32_t waitMs) {
  uint8_t req[4] = {0x05, slave, reg, 0};
  req[3] = tmcCrc(req, 3);
  while (Serial2.available()) Serial2.read();
  Serial2.write(req, 4);
  tmcTxWait();
  uint32_t t0 = millis();
  int n = 0;
  while ((millis() - t0) < waitMs && n < rawMax) {
    if (Serial2.available()) raw[n++] = (uint8_t)Serial2.read();
  }
  return n;
}

static bool tmcFindReply(const uint8_t *raw, int n, uint8_t reg, uint32_t *val) {
  for (int i = 0; i + 7 < n; i++) {
    if (raw[i] == 0x05 && raw[i + 1] == 0xFF && raw[i + 2] == reg) {
      if (val) {
        *val = ((uint32_t)raw[i + 3] << 24) | ((uint32_t)raw[i + 4] << 16) |
               ((uint32_t)raw[i + 5] << 8) | raw[i + 6];
      }
      return true;
    }
  }
  return false;
}

static void tmcWriteReg(uint8_t addr, uint32_t val) {
  uint8_t d[8] = {
      0x05, tmcSlave, (uint8_t)(addr | 0x80),
      (uint8_t)(val >> 24), (uint8_t)(val >> 16),
      (uint8_t)(val >> 8), (uint8_t)val, 0};
  d[7] = tmcCrc(d, 7);
  Serial2.write(d, 8);
  tmcTxWait();
  delay(3);
}

static uint32_t tmcReadReg(uint8_t addr) {
  uint8_t raw[24];
  int n = tmcReadRaw(tmcSlave, addr, raw, 24, 12);
  uint32_t val = 0xFFFFFFFF;
  tmcFindReply(raw, n, addr, &val);
  return val;
}

static uint8_t maToCs(uint16_t ma) {
  if (ma == 0) return 0;
  float cs = 32.0f * 1.41421f * ((float)ma / 1000.0f) * (kRSense + 0.02f) / 0.325f - 1.0f;
  if (cs < 0) cs = 0;
  if (cs > 31) cs = 31;
  return (uint8_t)(cs + 0.5f);
}

static uint8_t msToMres(uint16_t ms) {
  if (ms >= 256) return 0;
  if (ms >= 128) return 1;
  if (ms >= 64) return 2;
  if (ms >= 32) return 3;
  if (ms >= 16) return 4;
  if (ms >= 8) return 5;
  if (ms >= 4) return 6;
  if (ms >= 2) return 7;
  return 8;
}

// 把当前参数写进 TMC2209。寄存器含义：
//   0x00 GCONF       bit6 pdn_disable(用 UART 必须置1) bit7 mstep_reg(细分走寄存器)
//                    bit8 multistep_filt(滤波) bit2 en_spreadCycle(0=StealthChop 静音)
//   0x10 IHOLD_IRUN  bit0-4 IHOLD 保持电流档 bit8-12 IRUN 运行电流档 bit16-19 IHOLDDELAY
//   0x11 TPOWERDOWN  静止多久后把电流降到 IHOLD（单位约 2^18 tCLK，这里约 0.1 s 级）
//   0x6C CHOPCONF    bit0-3 toff 关断时间 bit4-6 hstrt bit7-10 hend bit15 vsense
//                    bit24-27 MRES 细分 bit28 intpol 微步插值
//   0x70 PWMCONF     自动缩放/频率等，0xC10D0024 是 StealthChop 的常用推荐值
static void tmcApply() {
  tmcIrunCs = maToCs(tmcRmsMa);
  tmcIholdCs = maToCs(tmcHoldMa);
  if (tmcIholdCs > tmcIrunCs) tmcIholdCs = tmcIrunCs;
  if (tmcToffSet < 1) tmcToffSet = 1;
  if (tmcToffSet > 15) tmcToffSet = 15;

  uint32_t gconf = (1u << 6) | (1u << 7) | (1u << 8);
  if (!tmcStealthSet) gconf |= (1u << 2);

  uint32_t chop = (uint32_t)tmcToffSet | (5u << 4) | (1u << 15) |
                  ((uint32_t)msToMres(tmcMsSet) << 24);
  if (tmcIntpolSet) chop |= (1u << 28);

  tmcWriteReg(0x00, gconf);
  tmcWriteReg(0x10, (uint32_t)tmcIholdCs | ((uint32_t)tmcIrunCs << 8) | (1u << 16));
  tmcWriteReg(0x11, 2);
  tmcWriteReg(0x6C, chop);
  tmcWriteReg(0x70, 0xC10D0024);
}

static void tmcRefresh() {
  uint32_t gconf = tmcReadReg(0x00);
  uint32_t chop = tmcReadReg(0x6C);
  tmcDrv = tmcReadReg(0x6F);
  uint32_t sg = tmcReadReg(0x41);
  uint32_t ts = tmcReadReg(0x12);
  if (chop != 0xFFFFFFFF) {
    tmcToff = (uint8_t)(chop & 0x0F);
    uint8_t mres = (uint8_t)((chop >> 24) & 0x0F);
    tmcMs = mres >= 8 ? 1 : (uint16_t)(256 >> mres);
  }
  if (gconf != 0xFFFFFFFF) tmcStealthSet = (uint8_t)(((gconf >> 2) & 1) == 0);
  if (sg != 0xFFFFFFFF) tmcSg = (uint16_t)(sg & 0x3FF);
  if (ts != 0xFFFFFFFF) tmcTstep = ts > 0xffff ? 0xffff : (uint16_t)ts;
  if (tmcDrv != 0xFFFFFFFF) tmcCs = (uint8_t)((tmcDrv >> 16) & 0x1F);
}

static bool tmcGotChip(const uint8_t *raw, int n, uint8_t *ver) {
  uint32_t v = 0;
  if (tmcFindReply(raw, n, 0x06, &v)) {
    *ver = (uint8_t)(v >> 24);
    return (*ver == 0x21 || *ver == 0x20);
  }
  if (tmcFindReply(raw, n, 0x00, &v)) {
    *ver = 0x21;
    return true;
  }
  return false;
}

static bool tmcTryPair(int rx, int tx, uint32_t baud) {
  tmcUartOpen(rx, tx, baud);
  uint8_t raw[24];
  Serial.printf("tmc try r%d t%d %lu\n", rx, tx, (unsigned long)baud);
  const uint8_t addrs[] = {0, 1, 2, 3};
  for (uint8_t addr : addrs) {
    int tries = addr == 0 ? 8 : 2;
    for (int i = 0; i < tries; i++) {
      int n = tmcReadRaw(addr, 0x06, raw, 24, 40);
      uint8_t ver = 0;
      if (!tmcGotChip(raw, n, &ver)) {
        if (n) {
          Serial.printf("  a%u n=%d:", addr, n);
          for (int k = 0; k < n && k < 24; k++) Serial.printf(" %02x", raw[k]);
          Serial.println();
        }
        delay(10);
        continue;
      }
      tmcSlave = addr;
      tmcVer = ver;
      tmcApply();
      tmcRefresh();
      snprintf(uartHint, sizeof(uartHint), "U r%d t%d a%u", rx, tx, addr);
      Serial.printf("tmc ok ver=0x%02X rx=%d tx=%d addr=%u baud=%lu\n", ver, rx, tx, addr,
                    (unsigned long)baud);
      return true;
    }
  }
  return false;
}

static bool tmcBringUp() {
  // GPIO12 is wired to the module's RX pad (verified); talk on that pin like the
  // working IO17 setup in esp32s3-tb6600-stepper. GPIO11 stays Hi-Z.
  Serial.println("tmc: half-duplex on GPIO12 -> module RX pad, GPIO11 unused");
  if (tmcTryPair(PIN_TMC_RX, PIN_TMC_RX, 115200)) return true;
  if (tmcTryPair(PIN_TMC_TX, PIN_TMC_TX, 115200)) return true;
  if (tmcTryPair(PIN_TMC_RX, PIN_TMC_TX, 19200)) return true;
  Serial2.end();
  pinMode(PIN_TMC_TX, INPUT);
  pinMode(PIN_TMC_RX, INPUT);
  snprintf(uartHint, sizeof(uartHint), "chk RX");
  Serial.println("tmc uart fail: GPIO12 to module RX, VDD=3.3V, VM on");
  return false;
}

static int32_t clampLim(int32_t v) {
  if (v < minLim) return minLim;
  if (v > maxLim) return maxLim;
  return v;
}

static void applyEnable() {
  bool on = enabled && !standbyOff;
  digitalWrite(PIN_EN, on ? LOW : HIGH);
  if (!stepper) return;
  if (on) stepper->enableOutputs();
  else stepper->disableOutputs();
}

// 运动前先唤醒：待机断电后再发位置，必须重新使能，否则只会记数不动轴。
static void wake() {
  lastMoveMs = millis();
  if (!standbyOff) return;
  standbyOff = false;
  applyEnable();
}

static void recoverRunningAtTarget();
static void resetStepperOutput(int32_t position);
static const int32_t kTargetPositionSlack = 4;

static bool positionNearTarget(int32_t position) {
  int32_t distance = position - target;
  return distance >= -kTargetPositionSlack && distance <= kTargetPositionSlack;
}

static void queueMoveTo(int32_t position) {
  int8_t result = stepper->moveTo(position);
  Serial.printf("moveTo pos=%ld rc=%d run=%d queue=%d ramp=%u future=%ld\n",
                (long)position, result, stepper->isRunning() ? 1 : 0,
                stepper->isQueueRunning() ? 1 : 0, stepper->rampState(),
                (long)stepper->getPositionAfterCommandsCompleted());
}

void motorBegin() {
  pinMode(PIN_EN, OUTPUT);
  digitalWrite(PIN_EN, HIGH);

  tmcLoad();  // 必须在 tmcApply() 之前：把上次保存的参数读回来
  recomputeLimits();  // 软限位跟随读回来的细分

  engine.init(1);
#if defined(SUPPORT_SELECT_DRIVER_TYPE)
  stepper = engine.stepperConnectToPin(PIN_STEP, DRIVER_RMT);
#else
  stepper = engine.stepperConnectToPin(PIN_STEP);
#endif
  if (!stepper) {
    Serial.println("step pin busy");
    return;
  }
  stepper->setDirectionPin(PIN_DIR);
  stepper->setEnablePin(PIN_EN, true);
  stepper->setAutoEnable(false);
  stepper->setSpeedInHz(kDefaultHz);
  stepper->setAcceleration(kDefaultAccel);
  stepper->disableOutputs();
  stepper->setCurrentPosition(0);
  target = 0;
  Serial.println("stepper ok");
}

void motorUartBegin() {
  uartOk = tmcBringUp();
  applyEnable();
}

void motorSetPos(int32_t steps) {
  if (!stepper || !enabled) {
    commandResult = MOTOR_RESULT_REJECTED;
    return;
  }
  wake();
  const bool needsRecovery =
      stepper->isRunning() && positionNearTarget(stepper->getCurrentPosition());
  if (needsRecovery) {
    recoverRunningAtTarget();
  }
  target = clampLim(steps);
  limitHit = target != steps;
  commandResult = limitHit ? MOTOR_RESULT_LIMITED : MOTOR_RESULT_ACCEPTED;
  if (needsRecovery || stepper->isRunning()) {
    pendingTarget = target;
    pendingSince = millis();
    movePending = true;
    return;
  }
  movePending = false;
  queueMoveTo(target);
}

void motorJog(int32_t delta) {
  if (!stepper || !enabled) {
    commandResult = MOTOR_RESULT_REJECTED;
    return;
  }
  wake();
  const int32_t current = stepper->getCurrentPosition();
  if (stepper->isRunning()) {
    // Cancel the previous move without rebuilding the RMT channel. Reattaching
    // the pin here can leave a new jog accepted in software but without pulses.
    stepper->forceStopAndNewPosition(current);
  }
  const int32_t requested = current + delta;
  target = clampLim(requested);
  limitHit = target != requested;
  commandResult = limitHit ? MOTOR_RESULT_LIMITED : MOTOR_RESULT_ACCEPTED;
  movePending = false;
  queueMoveTo(target);
}

// ---- 楔死看门狗 ----
// 实测 FastAccelStepper 的 RMT 通道偶尔会进入一种状态：
// isRunning() 一直是 true、位置却不再推进（RMT 还在输出慢速脉冲），
// 表现就是“电机一直慢慢转、停不下来”，此时 stopMove() 也压不住。
// 判据：位置连续 kWedgedMs 没变、isRunning() 仍为真、且未到目标。
// 处理：forceStopAndNewPosition() 硬停并对齐，然后把目标对齐到当前位置，
// 让它停下而不是继续空转。App／自动跟焦需要时会重新下发目标。
// 必须定义在 motorStandbyTick() 之前。
static const uint32_t kWedgedMs = 700;
static const uint32_t kRunningAtTargetMs = 1000;
static int32_t wdPos = 0x7fffffff;
static uint32_t wdSince = 0;
static uint16_t wdCount = 0;

static void resetStepperOutput(int32_t position) {
  stepper->forceStopAndNewPosition(position);
  stepper->detachFromPin();
  stepper->reAttachToPin();
  if (enabled && !standbyOff) stepper->enableOutputs();
}

static void wedgedTick() {
  if (!stepper) return;
  int32_t p = stepper->getCurrentPosition();
  uint32_t now = millis();
  if (p == target && wdPos != p) {
    wdPos = p;
    wdSince = now;
  } else if (p != wdPos) {
    wdPos = p;
    wdSince = now;
    return;
  }
  if (!stepper->isRunning()) return;
  if (positionNearTarget(p)) {
    stepper->stopMove();
    if (!stepper->isRunning() || now - wdSince < kRunningAtTargetMs) return;
    wdCount++;
    resetStepperOutput(target);
    p = target;
    wdSince = now;
    Serial.printf("stepper running at target %ld - force stop #%u\n", (long)p,
                  wdCount);
    return;
  }
  if (now - wdSince < kWedgedMs) return;
  wdCount++;
  Serial.printf("stepper wedged at %ld (target %ld) - force stop #%u\n", (long)p,
                (long)target, wdCount);
  resetStepperOutput(p);
  target = p;
  wdPos = p;
  wdSince = now;
  lastMoveMs = now;
}

static void recoverRunningAtTarget() {
  if (!stepper || !stepper->isRunning()) return;
  const int32_t p = stepper->getCurrentPosition();
  if (!positionNearTarget(p)) return;
  resetStepperOutput(target);
  wdPos = target;
  wdSince = millis();
  Serial.printf("stepper running near target %ld - force stop\n", (long)target);
}

uint16_t motorRecoverCount() { return wdCount; }

void motorStop() {
  if (!stepper) return;
  movePending = false;
  stepper->stopMove();
  target = stepper->getCurrentPosition();
  commandResult = MOTOR_RESULT_STOPPED;
  lastMoveMs = millis();
}

void motorSetEnabled(bool on) {
  enabled = on;
  if (!on) motorStop();
  standbyOff = false;
  lastMoveMs = millis();
  applyEnable();
}

void motorStandbyTick() {
  engine.manageSteppers();
  wedgedTick();  // 每 loop 都要跑，与待机无关
  if (movePending && stepper && millis() - pendingSince >= kMoveUpdateDelayMs) {
    movePending = false;
    queueMoveTo(pendingTarget);
  }
  if (!enabled || !tmcStandby || standbyOff) return;
  if (motorMoving()) {
    lastMoveMs = millis();
    return;
  }
  if (millis() - lastMoveMs < kStandbyDelayMs) return;
  standbyOff = true;
  applyEnable();
  Serial.println("standby: driver released");
}

bool motorStandbyOff() { return standbyOff; }

void motorSetLimits(int32_t minSteps, int32_t maxSteps) {
  if (minSteps > maxSteps) {
    int32_t t = minSteps;
    minSteps = maxSteps;
    maxSteps = t;
  }
  minLim = minSteps;
  maxLim = maxSteps;
  limExplicit = true;
  if (stepper && enabled) {
    movePending = false;
    target = clampLim(target);
    limitHit = false;
    queueMoveTo(target);
  }
}

void motorSetSpeed(int32_t hz, int32_t accel) {
  if (!stepper) return;
  if (hz < 100) hz = 100;
  if (hz > 40000) hz = 40000;
  if (accel < 100) accel = 100;
  if (accel > 1000000) accel = 1000000;
  stepper->setSpeedInHz((uint32_t)hz);
  stepper->setAcceleration((uint32_t)accel);
}

int32_t motorPos() { return stepper ? stepper->getCurrentPosition() : 0; }
int32_t motorTarget() { return target; }
int32_t motorMin() { return minLim; }
int32_t motorMax() { return maxLim; }
bool motorEnabled() { return enabled; }
bool motorLimitHit() { return limitHit; }
// 用 FastAccelStepper 自己的运行状态。不要用“位置 != 目标”判断：
// stopMove() 减速后位置永远到不了旧目标，会一直显示在动；
// 而“位置 300ms 没变就对齐目标”的做法会把慢速进行中的动作截断（实测少走 14 步）。
bool motorMoving() { return stepper && stepper->isRunning(); }
bool motorUartOk() { return uartOk; }
const char *motorUartHint() { return uartHint; }
MotorCommandResult motorCommandResult() { return commandResult; }

void motorTmcSnap(TmcSnap *o) {
  memset(o, 0, sizeof(*o));
  o->uartOk = uartOk;
  if (!uartOk) return;
  tmcRefresh();
  o->stealth = tmcStealthSet != 0;
  o->rmsMa = tmcRmsMa;
  o->microsteps = tmcMs ? tmcMs : tmcMsSet;
  o->toff = tmcToff ? tmcToff : tmcToffSet;
  o->ihold = tmcIholdCs;
  o->irun = tmcIrunCs;
  o->version = tmcVer;
  o->csActual = tmcCs;
  o->drvStatus = tmcDrv == 0xFFFFFFFF ? 0 : tmcDrv;
  o->sg = tmcSg;
  o->tstep = tmcTstep;
  if (tmcDrv == 0xFFFFFFFF) return;
  if (tmcDrv & 2) o->flags |= TMC_F_OT;
  if (tmcDrv & 1) o->flags |= TMC_F_OTPW;
  if (tmcDrv & (1u << 6)) o->flags |= TMC_F_OLA;
  if (tmcDrv & (1u << 7)) o->flags |= TMC_F_OLB;
  if (tmcDrv & (1u << 2)) o->flags |= TMC_F_S2GA;
  if (tmcDrv & (1u << 3)) o->flags |= TMC_F_S2GB;
  if (tmcDrv & (1u << 31)) o->flags |= TMC_F_STST;
  if (tmcDrv & (1u << 30)) o->flags |= TMC_F_STEALTH;
}

void motorTmcSet(int32_t key, int32_t val) {
  // 待机断电不是芯片寄存器，UART 没通也要能用。
  if (key == TMC_STANDBY) {
    tmcStandby = val ? 1 : 0;
    if (!tmcStandby && standbyOff) {
      standbyOff = false;
      applyEnable();
    }
    tmcSave();
    return;
  }
  if (!uartOk) return;
  switch (key) {
    case TMC_RMS:
      if (val < 100) val = 100;
      if (val > 2000) val = 2000;
      tmcRmsMa = (uint16_t)val;
      break;
    case TMC_MICROSTEPS:
      tmcMsSet = (uint16_t)val;
      recomputeLimits();  // 行程上限按圈算，换细分要跟着变
      break;
    case TMC_STEALTH:
      tmcStealthSet = val ? 1 : 0;
      break;
    case TMC_TOFF:
      if (val < 1) val = 1;
      if (val > 15) val = 15;
      tmcToffSet = (uint8_t)val;
      break;
    case TMC_IHOLD:
      if (val < 0) val = 0;
      if (val > 31) val = 31;
      tmcHoldMa = (uint16_t)((float)val / 31.0f * (float)tmcRmsMa);
      break;
    case TMC_IRUN:
      if (val < 0) val = 0;
      if (val > 31) val = 31;
      tmcRmsMa = (uint16_t)((float)(val + 1) / 32.0f * 0.325f / (kRSense + 0.02f) / 1.41421f * 1000.0f);
      if (tmcRmsMa < 100) tmcRmsMa = 100;
      break;
    default:
      return;
  }
  tmcApply();
  tmcSave();
}
