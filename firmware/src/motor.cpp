#include "motor.h"
#include "protocol.h"

#include <Arduino.h>
#include <Preferences.h>
#include <string.h>
#include <math.h>
#include "esp_arduino_version.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "freertos/FreeRTOS.h"

static const float kRSense = 0.11f;
static const uint16_t kRmsMa = 800;
static const uint16_t kHoldMa = 200;  // 保持电流：低一点，待机不那么烫、也不易有轻微嗡震
static const uint16_t kMicrosteps = 16;
static const uint32_t kDefaultHz = 8000;
static const int32_t kDefaultAccel = 20000;

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
static bool positionTrusted = false;
static bool communicationWatchdogArmed = false;
static uint32_t lastControlPacketMs = 0;
static const uint32_t kControlTimeoutMs = 1000;

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
// 寄存器读的重试参数，理由见 `tmcReadReg`。
static const int kTmcReadAttempts = 4;
static const uint32_t kTmcReadWaitMs = 15;
static const uint32_t kTmcReadRetryGapMs = 2;
// 配置写入 + IFCNT 校验的整块重试次数（丢写和读计数失败都靠它兜）。
static const int kTmcConfigAttempts = 3;
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

static CalibrationSnapshot calibration{};
static uint32_t calStartedMs, calPhaseMs, calKeepaliveMs, calSampleMs;
static int32_t calMaxTravel, calMargin, calSpeedSaved, calAccelSaved;
static uint8_t calStealthSaved;
static bool calSawFree;
/// 本轮标定里有没有"堵转后没问到驱动状态"的情况（见 calibrationTick）。
/// 有的话发布结果前会再补问一次；补问仍失败就放行，只在串口留痕。
static bool calFaultCheckPending;
/// 累计跳过的驱动状态检查次数，纯诊断（主机模拟会断言它）。
static uint32_t calFaultChecksSkipped;
static void calibrationTick();
static void calibrationFinish(uint8_t state, uint8_t error);

bool motorCalibrationActive() {
  return calibration.state >= CAL_SEEK_NEGATIVE && calibration.state <= CAL_BACKOFF_POSITIVE;
}

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
    if (Serial2.available()) {
      raw[n++] = (uint8_t)Serial2.read();
      if (n >= 8 && raw[n-8] == 0x05 && raw[n-7] == 0xFF &&
          raw[n-6] == reg && tmcCrc(raw+n-8, 7) == raw[n-1]) break;
    }
  }
  return n;
}

/// 半双工读失败的累计次数，只用于串口诊断（协议里没有多余位可以带这个信息）。
static uint32_t tmcReadFails = 0;

/// 丢掉 RX 里的残留字节。上一次请求的回包晚到（超时窗口之外）时会留在 FIFO 里，
/// 下一次读请求先收到的就是它 —— 虽然 `tmcFindReply` 会扫描偏移，但残留越长，
/// CRC 撞上的概率越低。所以重试前一定先排空。
static void tmcDrainRx() {
  while (Serial2.available()) Serial2.read();
}

static bool tmcFindReply(const uint8_t *raw, int n, uint8_t reg, uint32_t *val) {
  for (int i = 0; i + 7 < n; i++) {
    if (raw[i] == 0x05 && raw[i + 1] == 0xFF && raw[i + 2] == reg &&
        tmcCrc(raw + i, 7) == raw[i + 7]) {
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

/// 单次寄存器读。
///
/// 重试策略是现场调出来的（2026-09-29 真机：标定起手读 DRV_STATUS/IFCNT 大约
/// 一半的尝试拿到 0xFFFFFFFF，于是整轮标定被判成 CAL_UART = 3）：
/// - 每次失败后**排空 + 小延时**再发下一次，让晚到的回包先落地，不要污染下一轮；
/// - 尝试次数 4、窗口 15 ms：Wi-Fi 中断抢占下 12 ms 有时不够，四次全丢才认输；
/// - 只在**全部失败**时打印一次，避免在轮询里刷屏。
static uint32_t tmcReadReg(uint8_t addr) {
  for (int attempt = 0; attempt < kTmcReadAttempts; ++attempt) {
    if (attempt) {
      tmcDrainRx();
      delay(kTmcReadRetryGapMs);
    }
    uint8_t raw[24];
    int n = tmcReadRaw(tmcSlave, addr, raw, 24, kTmcReadWaitMs);
    uint32_t val = 0xFFFFFFFF;
    if (tmcFindReply(raw, n, addr, &val)) return val;
    ++tmcReadFails;
  }
  Serial.printf("tmc read fail addr=0x%02X (total=%lu)\n", addr,
                (unsigned long)tmcReadFails);
  return 0xFFFFFFFF;
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
  // GPIO12 is the verified single-wire UART. GPIO11 is reserved for DIAG;
  // never probe it as a UART output while it is connected to the driver.
  Serial.println("tmc: half-duplex UART on GPIO12, DIAG input on GPIO11");
  if (tmcTryPair(PIN_TMC_RX, PIN_TMC_RX, 115200)) return true;
  Serial2.end();
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

// Hardware timer pulse generator.  The ISR owns the actual position: one
// position unit is consumed only after a STEP pulse has been emitted.
static const uint32_t kTimerHz = 50000;
static hw_timer_t *stepTimer = nullptr;
static portMUX_TYPE stepMux = portMUX_INITIALIZER_UNLOCKED;
static volatile int32_t currentPos = 0;
static volatile int32_t stepTarget = 0;
static volatile uint32_t stepRate = 0;
static volatile int8_t stepSign = 1;
static volatile uint32_t phase = 0;
// ISR counts timer ticks rather than relying on a potentially blocked loop.
static volatile uint32_t calServiceTicks = 0;
static volatile bool calGuardArmed = false;
static volatile bool calGuardExpired = false;
static volatile uint32_t diagEdges = 0;
static volatile bool calDiagArmed = false;
static volatile bool calDiagTriggered = false;
static uint32_t calDiagSeen = 0;
static uint32_t calLastDiagMs = 0;
static int32_t calPhaseStartPos = 0;
static int8_t outputSign = -1;
static int32_t speedLimit = (int32_t)kDefaultHz;
static int32_t accelLimit = (int32_t)kDefaultAccel;
static float plannedRate = 0.0f;
static uint32_t lastPlanUs = 0;

static void IRAM_ATTR onDiagRise() {
  ++diagEdges;
  if (!calDiagArmed) return;
  portENTER_CRITICAL_ISR(&stepMux);
  stepRate = 0;
  stepTarget = currentPos;
  calDiagTriggered = true;
  portEXIT_CRITICAL_ISR(&stepMux);
}

static void IRAM_ATTR onStepTimer() {
  portENTER_CRITICAL_ISR(&stepMux);
  if (calGuardArmed && (calServiceTicks == 0 || --calServiceTicks == 0)) {
    stepRate = 0;
    stepTarget = currentPos;
    calGuardExpired = true;
  }
  const uint32_t rate = stepRate;
  const int8_t sign = stepSign;
  const int32_t pos = currentPos;
  const int32_t goal = stepTarget;
  if (rate == 0 || (sign > 0 && pos >= goal) || (sign < 0 && pos <= goal)) {
    phase = 0;
    portEXIT_CRITICAL_ISR(&stepMux);
    return;
  }
  phase += rate;
  if (phase < kTimerHz) {
    portEXIT_CRITICAL_ISR(&stepMux);
    return;
  }
  phase -= kTimerHz;
  gpio_set_level((gpio_num_t)PIN_STEP, 1);
  ets_delay_us(3);
  gpio_set_level((gpio_num_t)PIN_STEP, 0);
  currentPos += sign;
  portEXIT_CRITICAL_ISR(&stepMux);
}

static void setStepRate(int32_t rate) {
  bool forward = rate >= 0;
  uint32_t absolute = (uint32_t)(forward ? rate : -rate);
  if (absolute > (uint32_t)speedLimit) absolute = (uint32_t)speedLimit;
  const int8_t requestedSign = forward ? 1 : -1;
  if (absolute == 0) {
    portENTER_CRITICAL(&stepMux);
    stepRate = 0;
    phase = 0;
    portEXIT_CRITICAL(&stepMux);
    return;
  }
  portENTER_CRITICAL(&stepMux);
  const bool reversingWhileActive =
      stepRate != 0 && stepSign != requestedSign;
  const bool directionChanged = outputSign != requestedSign;
  if (reversingWhileActive) {
    stepRate = 0;
    phase = 0;
  }
  portEXIT_CRITICAL(&stepMux);
  if (reversingWhileActive) return;
  if (directionChanged) {
    digitalWrite(PIN_DIR, forward ? HIGH : LOW);
    delayMicroseconds(3);
    outputSign = requestedSign;
  }
  portENTER_CRITICAL(&stepMux);
  if (calGuardArmed && calGuardExpired) {
    portEXIT_CRITICAL(&stepMux);
    return;
  }
  stepSign = requestedSign;
  stepRate = absolute;
  portEXIT_CRITICAL(&stepMux);
}

static int32_t readPosition() {
  portENTER_CRITICAL(&stepMux);
  int32_t p = currentPos;
  portEXIT_CRITICAL(&stepMux);
  return p;
}

static void planMotion() {
  const uint32_t now = micros();
  if (lastPlanUs == 0) lastPlanUs = now;
  float dt = (float)(now - lastPlanUs) * 1e-6f;
  if (dt < 0.0005f) return;
  if (dt > 0.02f) dt = 0.02f;
  lastPlanUs = now;

  int32_t p, goal;
  portENTER_CRITICAL(&stepMux);
  p = currentPos;
  goal = stepTarget;
  portEXIT_CRITICAL(&stepMux);
  if (!enabled || standbyOff || p == goal) {
    plannedRate = 0;
    setStepRate(0);
    if (!motorCalibrationActive() && enabled && p == goal && commandResult == MOTOR_RESULT_ACCEPTED)
      commandResult = MOTOR_RESULT_COMPLETED;
    return;
  }

  const int32_t error = goal - p;
  const float distance = (float)abs(error);
  float desired = sqrtf(2.0f * (float)accelLimit * distance);
  if (desired > (float)speedLimit) desired = (float)speedLimit;
  if (error < 0) desired = -desired;
  const float delta = (float)accelLimit * dt;
  // Reverse only after the old direction has completely stopped, so DIR
  // always has setup time before the first pulse in the new direction.
  if (plannedRate != 0.0f && plannedRate * desired < 0.0f) {
    plannedRate += plannedRate > 0 ? -delta : delta;
    if (plannedRate * desired < 0.0f)
      plannedRate = 0.0f;
  } else if (plannedRate < desired) {
    plannedRate = min(plannedRate + delta, desired);
  } else if (plannedRate > desired) {
    plannedRate = max(plannedRate - delta, desired);
  }
  setStepRate((int32_t)(plannedRate >= 0 ? plannedRate + 0.5f : plannedRate - 0.5f));
}

static void applyEnable() {
  digitalWrite(PIN_EN, (enabled && !standbyOff) ? LOW : HIGH);
}

static void wake() {
  lastMoveMs = millis();
  if (!standbyOff) return;
  standbyOff = false;
  applyEnable();
}

void motorNoteControlPacket(bool latched) {
  if (motorCalibrationActive()) return;
  lastControlPacketMs = millis();
  communicationWatchdogArmed = !latched;
}

bool motorWatchdogArmed() { return communicationWatchdogArmed; }

void motorCommunicationTick() {
  if (!communicationWatchdogArmed || !enabled || !motorMoving()) return;
  if (millis() - lastControlPacketMs < kControlTimeoutMs) return;
  motorStop();
  communicationWatchdogArmed = false;
  Serial.println("control timeout: motion stopped");
}

void motorBegin() {
  pinMode(PIN_EN, OUTPUT);
  pinMode(PIN_STEP, OUTPUT);
  pinMode(PIN_DIR, OUTPUT);
  pinMode(PIN_TMC_DIAG, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(PIN_TMC_DIAG), onDiagRise, RISING);
  digitalWrite(PIN_EN, HIGH);
  digitalWrite(PIN_STEP, LOW);
  digitalWrite(PIN_DIR, LOW);
  tmcLoad();
  recomputeLimits();
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  stepTimer = timerBegin(kTimerHz);
  if (stepTimer) {
    timerAttachInterrupt(stepTimer, &onStepTimer);
    timerAlarm(stepTimer, 1, true, 0);
  }
#else
  stepTimer = timerBegin(1, 80, true);
  if (stepTimer) {
    timerAttachInterrupt(stepTimer, &onStepTimer, true);
    timerAlarmWrite(stepTimer, 1000000 / kTimerHz, true);
    timerAlarmEnable(stepTimer);
  }
#endif
  target = 0;
  portENTER_CRITICAL(&stepMux);
  currentPos = 0;
  stepTarget = 0;
  portEXIT_CRITICAL(&stepMux);
  lastPlanUs = micros();
  Serial.println(stepTimer ? "hardware timer stepper ok" : "step timer init failed");
}

void motorUartBegin() {
  uartOk = tmcBringUp();
  applyEnable();
}

void motorSetPos(int32_t steps) {
  if (motorCalibrationActive()) { commandResult = MOTOR_RESULT_REJECTED; return; }
  if (!enabled || !stepTimer) { commandResult = MOTOR_RESULT_REJECTED; return; }
  wake();
  const int32_t clamped = clampLim(steps);
  target = clamped;
  limitHit = clamped != steps;
  commandResult = limitHit ? MOTOR_RESULT_LIMITED : MOTOR_RESULT_ACCEPTED;
  portENTER_CRITICAL(&stepMux);
  stepTarget = clamped;
  portEXIT_CRITICAL(&stepMux);
}

void motorJog(int32_t delta) {
  if (motorCalibrationActive()) { commandResult = MOTOR_RESULT_REJECTED; return; }
  if (!enabled || !stepTimer) { commandResult = MOTOR_RESULT_REJECTED; return; }
  wake();
  const int32_t requested = readPosition() + delta;
  const int32_t clamped = clampLim(requested);
  target = clamped;
  limitHit = clamped != requested;
  commandResult = limitHit ? MOTOR_RESULT_LIMITED : MOTOR_RESULT_ACCEPTED;
  portENTER_CRITICAL(&stepMux);
  stepTarget = clamped;
  portEXIT_CRITICAL(&stepMux);
}

bool motorSetHome() {
  if (motorCalibrationActive() || !stepTimer || motorMoving()) {
    commandResult = MOTOR_RESULT_REJECTED;
    return false;
  }
  portENTER_CRITICAL(&stepMux);
  currentPos = 0;
  stepTarget = 0;
  stepRate = 0;
  phase = 0;
  portEXIT_CRITICAL(&stepMux);
  target = 0;
  limitHit = false;
  positionTrusted = true;
  calibration.valid = false;
  commandResult = MOTOR_RESULT_COMPLETED;
  communicationWatchdogArmed = false;
  return true;
}

void motorStop() {
  if (motorCalibrationActive()) { motorCalibrationCancel(); return; }
  if (!stepTimer) return;
  portENTER_CRITICAL(&stepMux);
  const int32_t p = currentPos;
  stepTarget = p;
  stepRate = 0;
  phase = 0;
  portEXIT_CRITICAL(&stepMux);
  plannedRate = 0;
  target = p;
  movePending = false;
  commandResult = MOTOR_RESULT_STOPPED;
  lastMoveMs = millis();
}

void motorSetEnabled(bool on) {
  if (on && motorCalibrationActive()) { commandResult = MOTOR_RESULT_REJECTED; return; }
  enabled = on;
  if (!on) {
    motorStop();
    positionTrusted = false;
    calibration.valid = false;
    communicationWatchdogArmed = false;
  }
  standbyOff = false;
  lastMoveMs = millis();
  applyEnable();
}

void motorStandbyTick() {
  calibrationTick();
  planMotion();
  motorCommunicationTick();
  if (motorCalibrationActive()) { lastMoveMs = millis(); return; }
  // Preserve the newly referenced lens position while the App chooses direction.
  // Explicit ENABLE(0) still releases immediately and invalidates calibration.
  if (calibration.valid) { lastMoveMs = millis(); return; }
  if (!enabled || !tmcStandby || standbyOff) return;
  if (motorMoving()) { lastMoveMs = millis(); return; }
  if (millis() - lastMoveMs < kStandbyDelayMs) return;
  standbyOff = true;
  if (calibration.valid) { calibration.valid = false; positionTrusted = false; }
  applyEnable();
  Serial.println("standby: driver released");
}

bool motorStandbyOff() { return standbyOff; }

void motorSetLimits(int32_t minSteps, int32_t maxSteps) {
  if (motorCalibrationActive()) { commandResult = MOTOR_RESULT_REJECTED; return; }
  calibration.valid = false;
  if (minSteps > maxSteps) { int32_t t = minSteps; minSteps = maxSteps; maxSteps = t; }
  minLim = minSteps; maxLim = maxSteps; limExplicit = true;
  const int32_t clamped = clampLim(target);
  target = clamped;
  limitHit = false;
  portENTER_CRITICAL(&stepMux);
  stepTarget = clamped;
  portEXIT_CRITICAL(&stepMux);
}

void motorSetSpeed(int32_t hz, int32_t accel) {
  if (motorCalibrationActive()) { commandResult = MOTOR_RESULT_REJECTED; return; }
  if (hz < 100) hz = 100;
  if (hz > 40000) hz = 40000;
  if (accel < 100) accel = 100;
  if (accel > 1000000) accel = 1000000;
  speedLimit = hz;
  accelLimit = accel;
}

int32_t motorPos() { return readPosition(); }
int32_t motorTarget() { return target; }
int32_t motorMin() { return minLim; }
int32_t motorMax() { return maxLim; }
bool motorEnabled() { return enabled; }
bool motorLimitHit() { return limitHit; }
bool motorMoving() {
  portENTER_CRITICAL(&stepMux);
  bool moving = stepRate != 0 || currentPos != stepTarget;
  portEXIT_CRITICAL(&stepMux);
  return moving;
}
bool motorUartOk() { return uartOk; }
bool motorPositionTrusted() { return positionTrusted; }
const char *motorUartHint() { return uartHint; }
uint32_t motorTmcReadFails() { return tmcReadFails; }
MotorCommandResult motorCommandResult() { return commandResult; }
void motorTmcSnap(TmcSnap *o) {
  memset(o, 0, sizeof(*o));
  o->uartOk = uartOk;
  if (!uartOk) return;
  if (!motorCalibrationActive()) tmcRefresh();
  o->stealth = tmcStealthSet != 0;
  o->rmsMa = tmcRmsMa;
  o->microsteps = tmcMs ? tmcMs : tmcMsSet;
  o->toff = tmcToff ? tmcToff : tmcToffSet;
  o->ihold = tmcIholdCs;
  o->irun = tmcIrunCs;
  o->version = tmcVer;
  o->csActual = tmcCs;
  o->drvStatusValid = tmcDrv != 0xFFFFFFFF;
  o->drvStatus = tmcDrv == 0xFFFFFFFF ? 0 : tmcDrv;
  o->sg = tmcSg;
  o->tstep = tmcTstep;
  o->diagEdges = diagEdges;
  o->diagLevel = digitalRead(PIN_TMC_DIAG) == HIGH;
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
  if (motorCalibrationActive()) { commandResult = MOTOR_RESULT_REJECTED; return; }
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
      if (val < 1 || val > 256 || (val & (val - 1)) != 0 || motorMoving()) return;
      if (tmcMsSet != val) { calibration.valid = false; positionTrusted = false; }
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

// Calibration owns coordinates while active. All moves still use the existing
// planner and timer ISR; there is no second pulse generator or blocking seek.
static void calibrationRebase(int32_t pos) {
  portENTER_CRITICAL(&stepMux);
  currentPos = stepTarget = pos;
  stepRate = phase = 0;
  portEXIT_CRITICAL(&stepMux);
  target = pos;
  plannedRate = 0;
  lastPlanUs = micros();
}

static void calibrationMove(uint8_t state, int32_t goal) {
  calDiagArmed = false;
  calDiagTriggered = false;
  calDiagSeen = diagEdges;
  calLastDiagMs = millis();
  calPhaseStartPos = motorPos();
  calibration.state = state;
  calPhaseMs = millis();
  calSawFree = false;
  target = goal;
  commandResult = MOTOR_RESULT_ACCEPTED;
  portENTER_CRITICAL(&stepMux);
  stepTarget = goal;
  portEXIT_CRITICAL(&stepMux);
  Serial.printf("cal run=%u phase=%u goal=%ld\n", calibration.runId, state, (long)goal);
}

static void calibrationFinish(uint8_t state, uint8_t error) {
  // Mark terminal before motorStop(), which otherwise calls cancel recursively.
  calibration.state = state;
  calibration.error = error;
  calibration.elapsedMs = millis() - calStartedMs;
  portENTER_CRITICAL(&stepMux);
  calGuardArmed = false;
  calDiagArmed = false;
  portEXIT_CRITICAL(&stepMux);
  motorStop();
  communicationWatchdogArmed = false;
  calibration.valid = state == CAL_COMPLETED;
  positionTrusted = calibration.valid;
  if (!calibration.valid) {
    minLim = maxLim = motorPos();
    limExplicit = true;
    enabled = false;
    standbyOff = false;
    applyEnable(); // release a stalled/faulted lens, even if UART is unavailable
  }
  tmcStealthSet = calStealthSaved;
  speedLimit = calSpeedSaved;
  accelLimit = calAccelSaved;
  tmcApply();
  tmcWriteReg(0x14, 0); // TCOOLTHRS: restore normal operation
  tmcWriteReg(0x40, 0); // SGTHRS
  commandResult = state == CAL_COMPLETED ? MOTOR_RESULT_COMPLETED : MOTOR_RESULT_STOPPED;
  Serial.printf("cal run=%u state=%u error=%u travel=%ld range=%ld..%ld\n",
                calibration.runId, state, error, (long)calibration.travel,
                (long)minLim, (long)maxLim);
}

static bool calibrationDiagConnected() {
  // A floating, unwired GPIO follows both weak pulls. The driver's DIAG
  // output drives a fixed level in both cases. Reject before any motion.
  pinMode(PIN_TMC_DIAG, INPUT_PULLUP);
  delayMicroseconds(100);
  const int up = digitalRead(PIN_TMC_DIAG);
  pinMode(PIN_TMC_DIAG, INPUT_PULLDOWN);
  delayMicroseconds(100);
  const int down = digitalRead(PIN_TMC_DIAG);
  // A disconnected wire reads active/high during motion and stops the scan.
  pinMode(PIN_TMC_DIAG, INPUT_PULLUP);
  Serial.printf("cal DIAG GPIO11 pullup=%d pulldown=%d\n", up, down);
  return up == down;
}

uint8_t motorCalibrationStart(uint8_t runId, int32_t threshold, int32_t maxTravel) {
  if (!runId) return CAL_BAD_PARAMETER;
  // UDP retransmission of the last accepted run is never a new motion command.
  if (calibration.runId == runId) return CAL_OK;
  if (motorCalibrationActive() || motorMoving() || !enabled || !stepTimer) return CAL_BUSY;
  if (!uartOk || tmcVer != 0x21) {
    Serial.printf("cal reject: UART init=%u ver=0x%02X\n", uartOk, tmcVer);
    return CAL_UART;
  }
  if (!calibrationDiagConnected()) return CAL_DIAG;
  if (tmcMsSet < 8 || tmcMsSet > 256 || (tmcMsSet & (tmcMsSet - 1))) return CAL_BAD_PARAMETER;
  if (threshold == 0) threshold = 60;
  if (maxTravel == 0) maxTravel = stepsPerRevFw() * 2;
  if (threshold < 1 || threshold > 255 || maxTravel < 128 * tmcMsSet ||
      maxTravel > stepsPerRevFw() * 10) return CAL_BAD_PARAMETER;
  const uint32_t drv = tmcReadReg(0x6F);
  if (drv == 0xFFFFFFFF) {
    Serial.println("cal reject: DRV_STATUS read failed");
    return CAL_UART;
  }
  if (drv & 0x3F) return CAL_DRIVER; // thermal prewarning/shutdown and both short types
  const uint32_t beforeWrites = tmcReadReg(0x02);
  if (beforeWrites == 0xFFFFFFFF) {
    Serial.println("cal reject: IFCNT read failed");
    return CAL_UART;
  }

  calSpeedSaved = speedLimit;
  calAccelSaved = accelLimit;
  calStealthSaved = tmcStealthSet;
  calibration = {};
  calibration.runId = runId;
  calibration.threshold = (uint8_t)threshold;
  calibration.microsteps = tmcMsSet;
  calMaxTravel = maxTravel;
  calMargin = 16 * tmcMsSet;
  calFaultCheckPending = false;
  calStartedMs = calKeepaliveMs = millis();
  positionTrusted = false;
  communicationWatchdogArmed = false;
  limitHit = false;
  wake();
  calibrationRebase(0);
  // SGTHRS/TCOOLTHRS/TPWMTHRS/COOLCONF 是**只写**寄存器，读不回来，只能靠 IFCNT
  // 的增量确认（九次写：tmcApply 五次 + 这里四次）。半双工丢包会同时影响写入和
  // 计数读取，所以整块重来，而不是一次不符就判 CAL_UART（真机现场就是这么被打回
  // 来的：GCONF 读到了、IFCNT 读回 0xFFFFFFFF）。
  bool configOk = false;
  uint32_t gc = 0xFFFFFFFF, afterWrites = 0xFFFFFFFF;
  for (int attempt = 0; attempt < kTmcConfigAttempts && !configOk; ++attempt) {
    if (attempt) {
      tmcDrainRx();
      delay(kTmcReadRetryGapMs);
    }
    tmcStealthSet = 1;
    tmcApply();
    tmcWriteReg(0x13, 0); // TPWMTHRS: no switch to SpreadCycle
    tmcWriteReg(0x14, 0xFFFFF);
    tmcWriteReg(0x40, threshold);
    tmcWriteReg(0x42, 0); // COOLCONF: constant current, no CoolStep
    gc = tmcReadReg(0x00);
    afterWrites = tmcReadReg(0x02);
    configOk = gc != 0xFFFFFFFF && !(gc & 4) && afterWrites != 0xFFFFFFFF &&
      (uint8_t)(afterWrites - beforeWrites) == 9;
    if (!configOk) {
      Serial.printf("cal config try=%d: GCONF=0x%08lX IFCNT=%lu->%lu expected +9\n",
                    attempt + 1, (unsigned long)gc, (unsigned long)beforeWrites,
                    (unsigned long)afterWrites);
    }
  }
  if (!configOk) {
    calibrationFinish(CAL_FAILED, CAL_UART);
    return CAL_OK;
  }
  if (digitalRead(PIN_TMC_DIAG) == HIGH) {
    calibrationFinish(CAL_FAILED, CAL_DRIVER);
    return CAL_OK;
  }
  speedLimit = 100 * tmcMsSet;
  accelLimit = 1000 * tmcMsSet;
  calSampleMs = millis();
  portENTER_CRITICAL(&stepMux);
  calGuardExpired = false;
  calServiceTicks = kTimerHz / 5; // 200 ms fail-closed pulse deadline
  calGuardArmed = true;
  portEXIT_CRITICAL(&stepMux);
  calibrationMove(CAL_SEEK_NEGATIVE, -calMaxTravel);
  return CAL_OK;
}

void motorCalibrationKeepalive(int32_t runId) {
  if (motorCalibrationActive() && runId == calibration.runId) calKeepaliveMs = millis();
}

void motorCalibrationCancel() {
  if (motorCalibrationActive()) calibrationFinish(CAL_CANCELLED, CAL_USER_CANCEL);
}

CalibrationSnapshot motorCalibrationSnapshot() {
  auto s = calibration;
  if (motorCalibrationActive()) s.elapsedMs = millis() - calStartedMs;
  return s;
}

static void calibrationTick() {
  if (!motorCalibrationActive()) return;
  const uint32_t now = millis();
  if (calGuardExpired) { calibrationFinish(CAL_FAILED, CAL_SAMPLE_TIMEOUT); return; }
  if (now - calKeepaliveMs >= 1000) { calibrationFinish(CAL_FAILED, CAL_LINK_TIMEOUT); return; }
  if (now - calPhaseMs >= 60000) { calibrationFinish(CAL_FAILED, CAL_TIMEOUT); return; }
  if (now - calSampleMs < 20) return;
  calSampleMs = now;
  const uint32_t edges = diagEdges;
  if (edges != calDiagSeen) {
    calDiagSeen = edges;
    calLastDiagMs = now;
  }
  portENTER_CRITICAL(&stepMux);
  const bool expired = calGuardExpired;
  if (!expired) calServiceTicks = kTimerHz / 5;
  portEXIT_CRITICAL(&stepMux);
  if (expired) { calibrationFinish(CAL_FAILED, CAL_SAMPLE_TIMEOUT); return; }
  const int32_t pos = motorPos();
  const bool arrived = pos == target;

  if (calDiagTriggered || (calDiagArmed && digitalRead(PIN_TMC_DIAG) == HIGH)) {
    // Stop first, then use UART once while stationary to distinguish a driver
    // fault from a StallGuard pulse. UART is never polled during a scan.
    calibrationRebase(pos);
    calDiagArmed = false;
    const uint32_t drv = tmcReadReg(0x6F);
    Serial.printf("cal DIAG run=%u phase=%u pos=%ld drv=0x%08lX\n",
                  calibration.runId, calibration.state, (long)pos, (unsigned long)drv);
    // 读不到**不等于**不是堵转：DIAG 已经响了，UART 只是"顺便问一句有没有故障"。
    // 真机 2026-09-29：6 次标定里 4 次就死在这一读上（停下瞬间半双工丢回包），
    // 于是明确是端点的一次识别被判成 CAL_UART=3。现在改成记账后继续，完成前再补问。
    if (drv == 0xFFFFFFFF) {
      calFaultCheckPending = true;
      ++calFaultChecksSkipped;
    } else if (drv & 0x3F) {
      calibrationFinish(CAL_FAILED, CAL_DRIVER); return;
    }
    if (calibration.state == CAL_BACKOFF_NEGATIVE ||
        calibration.state == CAL_BACKOFF_POSITIVE ||
        (calibration.state == CAL_SEEK_POSITIVE &&
         (!calSawFree || pos <= 4 * calMargin))) {
      calibrationFinish(CAL_FAILED, CAL_SHORT_TRAVEL); return;
    }
    if (calibration.state == CAL_SEEK_NEGATIVE) {
      calibrationRebase(0);
      calibrationMove(CAL_BACKOFF_NEGATIVE, calMargin);
    } else {
      calibration.travel = pos;
      calibrationMove(CAL_BACKOFF_POSITIVE, pos - calMargin);
    }
    return;
  }

  const bool freeMotion = now - calLastDiagMs >= 100 &&
      abs(pos - calPhaseStartPos) >= 4 * tmcMsSet;
  if (freeMotion) calSawFree = true;
  if (calibration.state == CAL_BACKOFF_NEGATIVE) {
    if (arrived) {
      calibrationRebase(pos);
      calibrationMove(CAL_SEEK_POSITIVE, calMaxTravel);
    }
    return;
  }
  if (calibration.state == CAL_BACKOFF_POSITIVE) {
    if (arrived) {
      if (!calSawFree) { calibrationFinish(CAL_FAILED, CAL_SHORT_TRAVEL); return; }
      // 发布结果前补一次驱动状态：这时电机已停、总线空闲，是整轮里最问得通的时刻。
      // 问到故障就作废（不发布可能来自故障的假行程）；仍然问不到才放行，
      // 并在串口留下 drv_valid=0 的痕迹，由 App 侧人工确认兜底。
      if (calFaultCheckPending) {
        const uint32_t drv = tmcReadReg(0x6F);
        Serial.printf("cal final drv check drv=0x%08lX\n", (unsigned long)drv);
        if (drv != 0xFFFFFFFF && (drv & 0x3F)) {
          calibrationFinish(CAL_FAILED, CAL_DRIVER); return;
        }
      }
      const int32_t safeSpan = calibration.travel - 2 * calMargin;
      calibrationRebase(safeSpan);
      minLim = 0; maxLim = safeSpan; limExplicit = true;
      calibrationFinish(CAL_COMPLETED, CAL_OK);
    }
    return;
  }
  if (arrived) { calibrationFinish(CAL_FAILED, CAL_DISTANCE); return; }
  // Ignore startup pulses until speed is stable, then let the DIAG interrupt
  // halt the step timer at the first stall pulse. The distance cap still applies.
  if (!calDiagArmed && now - calPhaseMs >= 200 &&
      fabsf(plannedRate) >= speedLimit * 0.9f) {
    calDiagArmed = true;
  }
}
