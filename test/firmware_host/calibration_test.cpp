// Runs the production motor.cpp against deterministic UART, GPIO and timer fakes.
#include <cassert>
#ifdef _MSC_VER
#include <Arduino.h>
#include <WiFiUdp.h>
#define __attribute__(x)
#pragma pack(push, 1)
#include "protocol.h"
#pragma pack(pop)
#endif
#include "../../firmware/src/motor.cpp"
#include "../../firmware/src/protocol.cpp"
const char* deviceId() { return "FF-TEST"; }
const uint8_t* deviceMac() { static uint8_t mac[6]{}; return mac; }

static uint8_t lastCalState = 0;
static void advance(int ms, bool keepalive=true, bool service=true) {
  for (int i=0;i<ms;++i) {
    fakeUs+=1000;
    for(int j=0;j<50;++j) onStepTimer();
    if (diagStallAfterMs >= 0) {
      // 阶段一换就把 DIAG 放下，模拟"这一段结束、堵转消失"。
      if (calibration.state != lastCalState) { lastCalState = calibration.state; fakeSetDiag(false); }
      if (motorCalibrationActive() && millis() - calPhaseMs >= (uint32_t)diagStallAfterMs) {
        fakeSetDiag(true);
      }
    }
    if (keepalive) motorCalibrationKeepalive(calibration.runId);
    if (service) motorStandbyTick();
  }
}
static void fresh() {
  failUart=corruptCrc=dropWrite=false; fakeFault=0;
  calGuardArmed=calGuardExpired=false;
  calibration={}; motorBegin(); uartOk=true; tmcVer=0x21;
  physical=1500; physicalMin=0; physicalMax=3000;
  diagWired=true; diagDriven=false; diagStallAfterMs=-1; lastCalState=0;
  motorSetEnabled(true);
  motorSetSpeed(8000,20000);
  registers[2]=250; // exercise IFCNT wrap
  tmcStealthSet=0;
}
static void start() { assert(motorCalibrationStart(1,60,6400)==CAL_OK); }
static void finished(uint8_t state,uint8_t error) {
  // 失败时先打一行现场再 assert：主机模拟里 assert 直接把进程 abort 掉，
  // 没有这行输出就只能靠猜是哪一步不对。
  if (calibration.state != state || calibration.error != error) {
    printf("MISMATCH: want state=%u err=%u, got state=%u err=%u "
           "(travel=%d pos=%d physical=%d min=%d max=%d pulses=%u)\n",
           state, error, calibration.state, calibration.error,
           (int)calibration.travel, (int)motorPos(), physical, physicalMin,
           physicalMax, pulses);
  }
  assert(calibration.state==state); assert(calibration.error==error);
  assert(!motorMoving()); assert(!calGuardArmed);
  assert(tmcStealthSet==0 && speedLimit==8000 && accelLimit==20000);
}
int main() {
  fresh();
  assert(motorCalibrationStart(0,60,6400)==CAL_BAD_PARAMETER);
  assert(motorCalibrationStart(1,256,6400)==CAL_BAD_PARAMETER);
  motorSetEnabled(false);
  assert(motorCalibrationStart(1,60,6400)==CAL_BUSY);
  assert(!calibration.runId);

  fresh(); start();
  int32_t goal=motorTarget();
  motorSetPos(50); motorJog(50); motorSetLimits(-1,1); motorSetSpeed(1,1);
  motorTmcSet(TMC_MICROSTEPS,32); motorSetEnabled(true);
  assert(!motorSetHome() && motorTarget()==goal && tmcMsSet==16);
  assert(motorCalibrationStart(2,60,6400)==CAL_BUSY);
  assert(motorCalibrationStart(1,60,6400)==CAL_OK);
  advance(7000);
  finished(CAL_COMPLETED,CAL_OK);
  // 两端各撞一次挡块 → DIAG 至少两个上升沿（这就是"找端点"的全部依据）。
  assert(diagEdges>=2);
  assert(calibration.valid && positionTrusted);
  assert(minLim==0 && maxLim==calibration.travel-512 && motorPos()==maxLim);
  assert(physical>physicalMin && physical<physicalMax);
  assert(calibration.travel>=2900 && calibration.travel<=3250);
  const auto p=motorPos();
  advance(3000); assert(calibration.valid && !standbyOff);
  assert(motorCalibrationStart(1,60,6400)==CAL_OK && motorPos()==p);
  motorSetEnabled(false); assert(!calibration.valid && !positionTrusted);

  fresh(); start(); advance(50); motorStop(); finished(CAL_CANCELLED,CAL_USER_CANCEL);
  assert(!positionTrusted && minLim==maxLim);
  fresh(); start(); advance(50); motorSetEnabled(false); finished(CAL_CANCELLED,CAL_USER_CANCEL);
  fresh(); start(); advance(1100,false); finished(CAL_FAILED,CAL_LINK_TIMEOUT);
  fresh(); start(); advance(100); advance(250,true,false);
  assert(calGuardExpired); auto count=pulses; advance(100,true,false); assert(pulses==count);
  advance(1); finished(CAL_FAILED,CAL_SAMPLE_TIMEOUT);
  // UART 在**启动前**就坏：起手读 DRV_STATUS 四次全败 → CAL_UART。
  fresh(); failUart=true; assert(motorCalibrationStart(1,60,6400)==CAL_UART);
  // 扫描期间**不轮询 UART**（PROTOCOL §14）：运动中来包/坏 CRC 不该中途打断标定。
  // 而且堵转后那次 DRV_STATUS 读失败**不再作废整轮**（真机 6 次里 4 次死在这）：
  // 读不到就记账继续，完成前再补问一次，仍问不到才放行。
  fresh(); start(); failUart=true; advance(7000); finished(CAL_COMPLETED,CAL_OK);
  assert(calFaultChecksSkipped>=2); // 两端各跳过一次
  fresh(); start(); corruptCrc=true; advance(7000); finished(CAL_COMPLETED,CAL_OK);
  assert(calFaultChecksSkipped>=2);
  // 驱动故障同理：只在堵转后的 DRV_STATUS 里才看得到（读到故障就作废）。
  fresh(); start(); fakeFault=4; advance(1200); finished(CAL_FAILED,CAL_DRIVER);
  fresh(); dropWrite=true; start(); finished(CAL_FAILED,CAL_UART);
  fresh(); physicalMin=-100000; physicalMax=100000; start(); advance(6000);
  finished(CAL_FAILED,CAL_DISTANCE);
  // 堵转误判/真卡死：每段刚过 200 ms 屏蔽就报堵转（现场 SGTHRS 过大时的样子，
  // 真机上表现为"每段只走 ~317 步"）。结果同样是行程过短，不是新故障。
  fresh(); diagStallAfterMs=200; start(); advance(4000); finished(CAL_FAILED,CAL_SHORT_TRAVEL);
  // DIAG 没接线（GPIO11 悬空）必须在运动前拒绝：现场就是这条被 App 误报成
  // "标定保活超时"的（固件其实回了 CAL_DIAG=11）。
  fresh(); diagWired=false;
  assert(motorCalibrationStart(1,60,6400)==CAL_DIAG);
  assert(!motorCalibrationActive() && !motorMoving() && motorTarget()==0);
  assert(calibration.error==CAL_OK && !calibration.runId);
  advance(200); assert(!motorMoving());
  fresh(); start(); calPhaseMs=millis()-60000; advance(1); finished(CAL_FAILED,CAL_TIMEOUT);
  fresh(); start(); motorCalibrationKeepalive(99); advance(1100,false); finished(CAL_FAILED,CAL_LINK_TIMEOUT);
  // Wire regression: new commands have one 32-byte reply; legacy sizes/counts
  // and request sequence echo remain intact even while calibration owns motion.
  fresh(); WiFiUDP link; protocolBegin(&link);
  auto request = [&](uint8_t cmd, int a=0, int b=0, uint8_t seq=42) {
    link.sent.clear(); FfPacket p{kFfMagic,cmd,0,seq,a,b}; handle(p,IPAddress{},4210);
  };
  request(FF_CAL_START,60,6400,1);
  assert(link.sent.size()==1 && link.sent[0].size()==32 && link.sent[0][1]==0x85);
  assert(link.sent[0][2]==CAL_SEEK_NEGATIVE && link.sent[0][5]==1);
  request(FF_QUERY); assert(link.sent.size()==2 && link.sent[0].size()==12 && link.sent[1].size()==16);
  request(FF_TMC_QUERY); assert(link.sent.size()==1 && link.sent[0].size()==22);
  request(FF_DISCOVER); assert(link.sent.size()==1 && link.sent[0].size()==32 && link.sent[0][1]==0x84);
  request(FF_CAL_START,60,6400,2); assert(link.sent[0][4]==CAL_BUSY && calibration.runId==1);
  request(FF_CAL_QUERY,1); assert(link.sent[0][3]==42 && link.sent[0][5]==1 && link.sent[0][4]==0);
  request(FF_CAL_CANCEL); assert(link.sent[0][2]==CAL_CANCELLED && link.sent[0][4]==CAL_USER_CANCEL);
  request(FF_CAL_START,60,6400,1); assert(link.sent[0][2]==CAL_CANCELLED);
  request(FF_HOME); assert(link.sent.size()==2 && link.sent[1].size()==16);
  puts("PASS: calibration success, guards, cancellation, UART/CRC, IFCNT, faults, bounds, timeout, idempotency");
  puts("PASS: CAL wire layout, sequence, rejection, replay and legacy reply regression");
}
