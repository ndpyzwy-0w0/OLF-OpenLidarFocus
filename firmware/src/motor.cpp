#include "motor.h"

#include <Arduino.h>
#include <string.h>
#include <FastAccelStepper.h>
#include "driver/gpio.h"
#include "driver/uart.h"
#include "freertos/FreeRTOS.h"

static const float kRSense = 0.11f;
static const uint16_t kRmsMa = 800;
static const uint16_t kHoldMa = 400;
static const uint16_t kMicrosteps = 16;
static const uint32_t kDefaultHz = 8000;
static const int32_t kDefaultAccel = 20000;

static FastAccelStepperEngine engine;
static FastAccelStepper *stepper = nullptr;
static char uartHint[24] = "UART ?";

static int32_t minLim = -1000000;
static int32_t maxLim = 1000000;
static int32_t target = 0;
static bool enabled = false;
static bool uartOk = false;

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
  // GPIO12 is wired straight to TMC TX; talk on that pin like the working IO17 setup.
  Serial.println("tmc: half-duplex on GPIO12 (direct TMC TX), GPIO11 Hi-Z");
  if (tmcTryPair(PIN_TMC_RX, PIN_TMC_RX, 115200)) return true;
  if (tmcTryPair(PIN_TMC_TX, PIN_TMC_TX, 115200)) return true;
  if (tmcTryPair(PIN_TMC_RX, PIN_TMC_TX, 19200)) return true;
  Serial2.end();
  pinMode(PIN_TMC_TX, INPUT);
  pinMode(PIN_TMC_RX, INPUT);
  snprintf(uartHint, sizeof(uartHint), "chk TX");
  Serial.println("tmc uart fail");
  return false;
}

static int32_t clampLim(int32_t v) {
  if (v < minLim) return minLim;
  if (v > maxLim) return maxLim;
  return v;
}

static void applyEnable() {
  digitalWrite(PIN_EN, enabled ? LOW : HIGH);
  if (!stepper) return;
  if (enabled) stepper->enableOutputs();
  else stepper->disableOutputs();
}

void motorBegin() {
  pinMode(PIN_EN, OUTPUT);
  digitalWrite(PIN_EN, HIGH);

  engine.init();
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
  if (!stepper || !enabled) return;
  target = clampLim(steps);
  stepper->moveTo(target);
}

void motorJog(int32_t delta) {
  if (!stepper || !enabled) return;
  target = clampLim(target + delta);
  stepper->moveTo(target);
}

void motorStop() {
  if (!stepper) return;
  stepper->stopMove();
  target = stepper->getCurrentPosition();
}

void motorSetEnabled(bool on) {
  enabled = on;
  if (!on) motorStop();
  applyEnable();
}

void motorSetLimits(int32_t minSteps, int32_t maxSteps) {
  if (minSteps > maxSteps) {
    int32_t t = minSteps;
    minSteps = maxSteps;
    maxSteps = t;
  }
  minLim = minSteps;
  maxLim = maxSteps;
  if (stepper && enabled) {
    target = clampLim(target);
    stepper->moveTo(target);
  }
}

void motorSetSpeed(int32_t hz, int32_t accel) {
  if (!stepper) return;
  if (hz < 100) hz = 100;
  if (hz > 40000) hz = 40000;
  if (accel < 100) accel = 100;
  stepper->setSpeedInHz((uint32_t)hz);
  stepper->setAcceleration((uint32_t)accel);
}

int32_t motorPos() { return stepper ? stepper->getCurrentPosition() : 0; }
int32_t motorTarget() { return target; }
int32_t motorMin() { return minLim; }
int32_t motorMax() { return maxLim; }
bool motorEnabled() { return enabled; }
bool motorMoving() { return stepper && stepper->isRunning(); }
bool motorUartOk() { return uartOk; }
const char *motorUartHint() { return uartHint; }

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
  if (!uartOk) return;
  switch (key) {
    case 1:
      if (val < 100) val = 100;
      if (val > 2000) val = 2000;
      tmcRmsMa = (uint16_t)val;
      break;
    case 2:
      tmcMsSet = (uint16_t)val;
      break;
    case 3:
      tmcStealthSet = val ? 1 : 0;
      break;
    case 4:
      if (val < 1) val = 1;
      if (val > 15) val = 15;
      tmcToffSet = (uint8_t)val;
      break;
    case 5:
      if (val < 0) val = 0;
      if (val > 31) val = 31;
      tmcHoldMa = (uint16_t)((float)val / 31.0f * (float)tmcRmsMa);
      break;
    case 6:
      if (val < 0) val = 0;
      if (val > 31) val = 31;
      tmcRmsMa = (uint16_t)((float)(val + 1) / 32.0f * 0.325f / (kRSense + 0.02f) / 1.41421f * 1000.0f);
      if (tmcRmsMa < 100) tmcRmsMa = 100;
      break;
    default:
      return;
  }
  tmcApply();
}
