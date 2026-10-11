#include "motor.h"
#include "fm03_status.h"
#include <Arduino.h>
#include <Preferences.h>
#include <algorithm>
#include <limits.h>
#include <cstring>
#include "driver/twai.h"
#include "esp_timer.h"
#include "freertos/semphr.h"

// 协议来源 DJI-FM03-can，2026-10-10 已验证 50ms 速度流及内部标定。
static const uint8_t request[] = {0x55,0x0D,0x04,0x33,0xE5,0xBF,0,0,0x40,0,1,0xDD,0xFE};
static const uint8_t dial[] = {0x55,0x13,0x04,3,0xE5,0xBF,0,0,0,4,0x69,0x0F,4,8,0x19,0,0,0x6B,0x56};
static const uint8_t calibrate[] = {0x55,0x10,4,0x56,0xE5,0xBF,0x21,0xDB,0,4,0x2F,2,0,1,0x7C,0xC9};
static SemaphoreHandle_t lock;
static portMUX_TYPE rxMux = portMUX_INITIALIZER_UNLOCKED;
static MotorStatusDecoder decoder;
struct Feedback { int stage; int32_t raw; int64_t stamp; uint32_t epoch; };
static Feedback received{-1,0,0,0};
static int stage = -1;
static int32_t rawPosition = 0, lastGoodRaw = 0;
static int64_t sampleUs = 0;
static uint32_t feedbackEpoch = 0, moveEpoch = 0;
static bool installed = false, enabled = false, moving = false, limited = false;
static bool watchdog = false, calibrating = false, calSeen = false, calPending = false;
static bool txUrgent = false;
static int32_t origin = 0, target = 0, minLim = 0, maxLim = 4096;
static int16_t applied = 0;
static uint16_t speed = 64, tolerance = 4, gain = 4;
static uint8_t fault = 0;
static uint32_t txFailures = 0, rxMissed = 0, lastControl = 0, lastTx = 0;
static uint32_t started = 0, progressAt = 0, settledAt = 0, calStarted = 0;
static int64_t calStartedUs = 0, lastSample = 0;
static int32_t progressPosition = 0;
static uint16_t calSequence = 0xDB21;
static CalibrationSnapshot cal{};
static MotorCommandResult result = MOTOR_RESULT_IDLE;
struct Guard {
  bool held = true;
  Guard() { xSemaphoreTakeRecursive(lock, portMAX_DELAY); }
  void unlock() { if (held) { held = false; xSemaphoreGiveRecursive(lock); } }
  ~Guard() { unlock(); }
};

static uint16_t crc(const uint8_t *p, unsigned n, uint16_t v, uint16_t poly) {
  while (n--) { v ^= *p++; for (int i=0;i<8;i++) v = v&1 ? (v>>1)^poly : v>>1; }
  return v;
}
// 整个 DUML 包共享 50ms 截止时间，不能每个 CAN 分片各等 50ms。
static bool waitTxIdle(uint32_t startedAt) {
  do {
    twai_status_info_t s{};
    if (twai_get_status_info(&s) != ESP_OK || s.state != TWAI_STATE_RUNNING) return false;
    if (!s.msgs_to_tx) return true;
    delay(1);
  } while (millis() - startedAt < 50);
  return false;
}
static bool sendPacket(const uint8_t *p, unsigned n) {
  if (!installed) return false;
  const uint32_t startedAt = millis();
  while (n) {
    // 只有 controlTask 发送 CAN；TX 队列关闭，逐帧等待实际完成。
    if (!waitTxIdle(startedAt)) { Guard g; ++txFailures; return false; }
    twai_message_t m{}; m.identifier = 0x503;
    m.data_length_code = std::min(n, 8u);
    memcpy(m.data, p, m.data_length_code);
    if (twai_transmit(&m, 0) != ESP_OK) { Guard g; ++txFailures; return false; }
    p += m.data_length_code; n -= m.data_length_code;
  }
  if (waitTxIdle(startedAt)) return true;
  Guard g; ++txFailures; return false;
}
static bool sendDial(int16_t value) {
  uint8_t p[sizeof(dial)]; memcpy(p,dial,sizeof(p));
  p[15] = (uint8_t)value; p[16] = (uint8_t)((uint16_t)value>>8);
  uint16_t c = crc(p,17,0x3692,0x8408); p[17]=c; p[18]=c>>8;
  if (!sendPacket(p,sizeof(p))) return false;
  Guard g; applied=value; return true;
}
static bool fresh() {
  return installed && sampleUs > 0 && esp_timer_get_time()-sampleUs <= 300000;
}
static bool trusted() { return fresh() && stage==3 && rawPosition>=0 && rawPosition<=4096 && !calibrating; }
static int32_t position() { return lastGoodRaw-origin; }
static void stopLocal(MotorCommandResult r) {
  txUrgent = txUrgent || moving;
  moving=false; watchdog=false; target=position(); settledAt=0; result=r;
}
static void save() {
  Preferences p; if (!p.begin("fm03",false)) return;
  p.putUShort("speed",speed); p.putUShort("tol",tolerance); p.putUShort("gain",gain); p.end();
}
static void rxTask(void *) {
  unsigned count=0;
  while (true) {
    twai_message_t m{};
    if (twai_receive(&m,pdMS_TO_TICKS(20)) == ESP_OK) {
      decoder.feed(m.identifier,m.extd,m.rtr,m.data,m.data_length_code,esp_timer_get_time());
      if (decoder.updated) {
        portENTER_CRITICAL(&rxMux);
        received={decoder.stage,decoder.coordinate,decoder.sample_us,decoder.epoch};
        portEXIT_CRITICAL(&rxMux); decoder.updated=false;
      }
      if (++count%64==0) vTaskDelay(pdMS_TO_TICKS(1));
    }
  }
}
static void controlTask(void *) { while (true) { motorPoll(); vTaskDelay(pdMS_TO_TICKS(5)); } }
void motorBegin() {
  lock=xSemaphoreCreateRecursiveMutex();
  Preferences p; if (p.begin("fm03",true)) {
    speed=std::max(1,std::min(256,(int)p.getUShort("speed",64)));
    tolerance=std::max(1,std::min(64,(int)p.getUShort("tol",4)));
    gain=std::max(1,std::min(64,(int)p.getUShort("gain",4))); p.end();
  }
  twai_general_config_t g=TWAI_GENERAL_CONFIG_DEFAULT((gpio_num_t)PIN_CAN_TX,(gpio_num_t)PIN_CAN_RX,TWAI_MODE_NORMAL);
  g.tx_queue_len=0; g.rx_queue_len=128;
  twai_timing_config_t t=TWAI_TIMING_CONFIG_1MBITS();
  twai_filter_config_t f=TWAI_FILTER_CONFIG_ACCEPT_ALL();
  installed=twai_driver_install(&g,&t,&f)==ESP_OK;
  if (installed && twai_start()!=ESP_OK) { twai_driver_uninstall(); installed=false; }
  if (!installed) { fault=1; Serial.println("FM03 CAN init failed"); return; }
  xTaskCreate(rxTask,"fm03_rx",4096,nullptr,4,nullptr);
  xTaskCreate(controlTask,"fm03_control",4096,nullptr,3,nullptr);
  Serial.println("FM03 CAN 1Mbps TX4 RX5; OLED unchanged");
}
void motorPoll() {
  Guard g;
  portENTER_CRITICAL(&rxMux);
  Feedback f=received;
  portEXIT_CRITICAL(&rxMux);
  const int previousStage=stage;
  stage=f.stage; rawPosition=f.raw; sampleUs=f.stamp; feedbackEpoch=f.epoch;
  if (stage==3 && rawPosition>=0 && rawPosition<=4096) lastGoodRaw=rawPosition;
  if ((stage==1 || stage==2) && previousStage!=1 && previousStage!=2 && !calibrating) {
    origin=0; minLim=0; maxLim=4096; cal.valid=false;
  }
  const uint32_t now=millis();
  twai_status_info_t s{};
  bool bus=installed && twai_get_status_info(&s)==ESP_OK && s.state==TWAI_STATE_RUNNING;
  if (!bus || s.rx_missed_count!=rxMissed) {
    rxMissed=s.rx_missed_count; fault=1; enabled=false; stopLocal(MOTOR_RESULT_REJECTED);
    // 恢复只重启总线；必须由新 ENABLE 重新取得控制，旧目标不恢复。
    if (installed && s.state==TWAI_STATE_BUS_OFF) twai_initiate_recovery();
    if (installed && s.state==TWAI_STATE_STOPPED) twai_start();
  }
  if (calibrating) {
    cal.elapsedMs=now-calStarted;
    if (fresh() && sampleUs>calStartedUs && (stage==1 || stage==2)) {
      calSeen=true; cal.state=stage==1 ? CAL_SEEK_NEGATIVE : CAL_SEEK_POSITIVE;
    }
    if (calSeen && fresh() && stage==3 && rawPosition>=0 && rawPosition<=4096) {
      calibrating=false; origin=0; minLim=0; maxLim=4096; target=rawPosition;
      cal.state=CAL_COMPLETED; cal.error=CAL_OK; cal.valid=true; cal.travel=4096; cal.microsteps=1;
    } else if (now-calStarted>60000) {
      // 内部标定没有已验证的取消指令。保留观察锁，直到真的看到阶段3。
      cal.error=CAL_TIMEOUT; enabled=false;
    }
  }
  if (moving) {
    if (!trusted() || feedbackEpoch!=moveEpoch || (watchdog && now-lastControl>1000)) {
      fault=2; stopLocal(MOTOR_RESULT_REJECTED);
    } else if (now-started>60000 || now-progressAt>2000) {
      fault=3; stopLocal(MOTOR_RESULT_REJECTED);
    }
  }
  if ((!txUrgent && now-lastTx<50) || !bus) return;
  txUrgent=false; lastTx=now;
  int16_t value=0;
  if (enabled && moving && trusted()) {
    const int64_t error=(int64_t)target-position();
    const int64_t magnitude=error<0 ? -error : error;
    if (sampleUs!=lastSample) {
      lastSample=sampleUs;
      if (position()!=progressPosition) { progressPosition=position(); progressAt=now; }
      if (magnitude<=tolerance) {
        if (!settledAt) settledAt=now;
        if (now-settledAt>=400) { moving=false; result=limited ? MOTOR_RESULT_LIMITED : MOTOR_RESULT_COMPLETED; }
      } else settledAt=0;
    }
    if (moving && magnitude>tolerance) {
      int64_t v=std::max((int64_t)1,std::min((int64_t)speed,(magnitude+gain-1)/gain));
      value=error<0 ? -v : v;
    }
  }
  // CAN 等待不能持有状态锁：UDP/OLED 读取和 STOP/ENABLE 必须随时能处理。
  g.unlock();
  // 归零流在禁用/失联时仍发送：DISARM 不能靠停止发送使电机停下。
  const bool requested = sendPacket(request,sizeof(request));
  { Guard stateGuard; if (!enabled || !moving || !trusted()) value=0; }
  if (!requested || !sendDial(value)) {
    { Guard stateGuard; fault=1; enabled=false; stopLocal(MOTOR_RESULT_REJECTED); }
    sendDial(0);
  }
  uint8_t p[sizeof(calibrate)];
  bool sendCal = false;
  {
    Guard stateGuard;
    if (calPending) {
      calPending=false;
      if (!enabled) { cal.error=CAL_CAN; }
      else {
        memcpy(p,calibrate,sizeof(p));
        uint16_t seq=calSequence++; p[6]=seq; p[7]=seq>>8;
        uint16_t c=crc(p,14,0x3692,0x8408); p[14]=c; p[15]=c>>8;
        sendCal=true;
      }
    }
  }
  // START 可能在上一条速度报文发送中到达，校准前必须实际发完零速度。
  if (sendCal && (!sendDial(0) || !sendPacket(p,sizeof(p)))) {
    Guard stateGuard; cal.error=CAL_CAN; enabled=false;
    // 部分发出也可能执行；不自动重发，不解除观察锁。
  }
}
void motorSetPos(int32_t v) {
  Guard g;
  if (!enabled || !trusted()) { result=MOTOR_RESULT_REJECTED; return; }
  int32_t lo=std::max(minLim,-origin), hi=std::min(maxLim,4096-origin);
  if (lo>hi) { result=MOTOR_RESULT_REJECTED; return; }
  int32_t next=std::max(lo,std::min(hi,v)); limited=next!=v;
  if (moving && next==target) return; // 心跳不得重置无进展/总超时。
  if (!moving) { started=progressAt=millis(); progressPosition=position(); }
  target=next; moving=true; fault=0; settledAt=0;
  lastSample=0; moveEpoch=feedbackEpoch;
  result=limited ? MOTOR_RESULT_LIMITED : MOTOR_RESULT_ACCEPTED;
}
void motorJog(int32_t delta) {
  Guard g; int64_t v=(int64_t)position()+delta;
  motorSetPos((int32_t)std::max((int64_t)INT32_MIN,std::min((int64_t)INT32_MAX,v)));
}
void motorStop() { Guard g; stopLocal(MOTOR_RESULT_STOPPED); txUrgent=true; }
void motorSetEnabled(bool on) {
  Guard g;
  if (on && (!installed || calibrating || !fresh())) { result=MOTOR_RESULT_REJECTED; return; }
  enabled=on; fault=0; stopLocal(MOTOR_RESULT_STOPPED); txUrgent=true;
}
bool motorSetHome() {
  Guard g; if (moving || !trusted()) { result=MOTOR_RESULT_REJECTED; return false; }
  origin=rawPosition; target=0; minLim=-origin; maxLim=4096-origin;
  cal.valid=false; watchdog=false; return true;
}
void motorSetLimits(int32_t lo,int32_t hi) {
  Guard g; if (lo>hi || calibrating) { result=MOTOR_RESULT_REJECTED; return; }
  minLim=lo; maxLim=hi;
  if (moving) { int32_t v=target; stopLocal(MOTOR_RESULT_STOPPED); motorSetPos(v); }
}
void motorSetSpeed(int32_t v,int32_t) { motorFm03Set(1,v); }
void motorFm03Set(int32_t key,int32_t v) {
  Guard g;
  if (moving || calibrating || (key==1 && (v<1 || v>256)) ||
      ((key==2 || key==3) && (v<1 || v>64)) || key<1 || key>3) {
    result=MOTOR_RESULT_REJECTED; return;
  }
  // 连接时 App 会重发参数；相同数值不重复写 flash，避免打断 CAN 收包。
  if ((key==1 && speed==v) || (key==2 && tolerance==v) || (key==3 && gain==v)) return;
  if (key==1) speed=v; if (key==2) tolerance=v; if (key==3) gain=v; save();
}
int32_t motorPos() { Guard g; return position(); }
int32_t motorTarget() { Guard g; return target; }
int32_t motorMin() { Guard g; return minLim; }
int32_t motorMax() { Guard g; return maxLim; }
bool motorEnabled() { Guard g; return enabled; }
bool motorMoving() { Guard g; return moving; }
bool motorLimitHit() { Guard g; return limited; }
bool motorCanOk() { Guard g; return fresh() && fault!=1; }
bool motorPositionTrusted() { Guard g; return trusted(); }
uint8_t motorFault() { Guard g; return fault; }
MotorCommandResult motorCommandResult() { Guard g; return result; }
void motorNoteControlPacket(bool latched) { Guard g; lastControl=millis(); watchdog=!latched; }
bool motorWatchdogArmed() { Guard g; return watchdog; }
Fm03Snapshot motorFm03Snapshot() {
  Guard g;
  int64_t age=sampleUs>0 ? (esp_timer_get_time()-sampleUs)/1000 : 65535;
  return {fresh(),enabled,moving,(uint8_t)(stage<0 ? 255 : stage),applied,speed,tolerance,gain,
    rawPosition,txFailures,rxMissed,(uint16_t)std::min((int64_t)65535,age)};
}
bool motorCalibrationActive() { Guard g; return calibrating; }
uint8_t motorCalibrationStart(uint8_t runId,int32_t a,int32_t b) {
  Guard g;
  if (!runId || a || b) return CAL_BAD_PARAMETER;
  if (cal.runId==runId && (calibrating || cal.state==CAL_COMPLETED)) return cal.error;
  if (!enabled || moving || calibrating) return CAL_BUSY;
  if (!fresh()) return CAL_CAN;
  stopLocal(MOTOR_RESULT_STOPPED); txUrgent=true;
  cal={}; cal.runId=runId; cal.microsteps=1; cal.state=CAL_SEEK_NEGATIVE;
  calStarted=millis(); calStartedUs=esp_timer_get_time();
  calSeen=false; calibrating=true; calPending=true; origin=0; minLim=0; maxLim=4096;
  return CAL_OK;
}
void motorCalibrationKeepalive(int32_t) {} // FM03 自主执行；App 查询不冒充可取消的租约。
void motorCalibrationCancel() {
  Guard g;
  if (calibrating) { cal.error=CAL_CANCEL_UNSUPPORTED; enabled=false; txUrgent=true; return; }
  cal.state=CAL_CANCELLED; cal.valid=false;
}
CalibrationSnapshot motorCalibrationSnapshot() { Guard g; return cal; }
