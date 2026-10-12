#include <cassert>
#include <cstdio>
#include "../../firmware/src/motor.cpp"
#include "../../firmware/src/protocol.cpp"
#include "../../firmware/src/oled.cpp"
const char* deviceId() { return "FF-TEST"; }
const uint8_t* deviceMac() { static uint8_t m[6]{}; return m; }
static void feedback(int state,int32_t pos) {
  received={state,pos,(int64_t)fakeUs,1}; motorPoll();
}
static void advance(int ms,int state,int32_t pos) {
  for(int i=0;i<ms;i+=50) { fakeUs+=50000;feedback(state,pos); }
}
static void reset() {
  enabled=moving=watchdog=calibrating=calPending=calSeen=false;
  origin=0; minLim=0;maxLim=4096;target=0;cal={};fault=0;txFailures=0;
  speed=64;tolerance=4;gain=4;acceleration=8;parametersDirty=false;Preferences::writes=0;
  applied=0;lastDialAt=millis();previousPollAt=maxPollGap=maxPacketMs=0;
  lastTxError=ESP_OK;lastTxFailureAt="none";
  fakeBus={};failTx=false;txDelayUs=0;duringTxWait=nullptr;rxMissed=0;lastTx=0;txUrgent=false;transmitted.clear();
  feedback(3,2000); motorSetEnabled(true);
}
int main() {
  motorBegin(); reset();
  motorNoteControlPacket(true);motorSetPos(2200);advance(50,3,2000);
  assert(applied>0 && applied<=64 && motorMoving());
  // 检查真实生产发送路径的 13/19 字节模板、帧长度及 CRC。
  assert(transmitted.size()>=5);
  auto end=transmitted.end();
  assert((end-3)->identifier==0x503 && (end-3)->data_length_code==8);
  assert((end-2)->data_length_code==8 && (end-1)->data_length_code==3);
  uint8_t packet[19];memcpy(packet,(end-3)->data,8);memcpy(packet+8,(end-2)->data,8);memcpy(packet+16,(end-1)->data,3);
  assert(crc(packet,17,0x3692,0x8408)==(packet[17]|(packet[18]<<8)));
  advance(500,3,2200);assert(!motorMoving() && applied==0 && result==MOTOR_RESULT_COMPLETED);
  // Arrival is tolerant and duplicate heartbeats do not re-arm a completed move.
  reset();motorSetPos(2010);advance(500,3,2008);
  assert(!moving && target==2010 && result==MOTOR_RESULT_COMPLETED && applied==0);
  for (int i=0;i<12;++i) {
    motorNoteControlPacket(false);motorSetPos(2010);advance(50,3,2007);
    assert(!moving && applied==0 && result==MOTOR_RESULT_COMPLETED);
  }
  reset();motorSetPos(2004);assert(!moving && target==2004 && result==MOTOR_RESULT_COMPLETED);
  motorSetPos(2009);advance(50,3,2000);assert(moving && applied>0);
  motorFm03Set(2,12);assert(tolerance==12);advance(500,3,2000);
  assert(!moving && applied==0 && target==2009 && result==MOTOR_RESULT_COMPLETED);
  // Tiny feedback oscillation is not useful progress and cannot keep a goal alive.
  reset();motorSetPos(2009);
  for (int i=0;i<44;++i) { advance(50,3,2000+i%3);motorSetPos(2009); }
  assert(!moving && applied==0 && fault==3 && target==2009);
  motorSetPos(2200);advance(50,3,2000);assert(moving && fault==0);
  // Speed scales small-error response, not only a ceiling that is never reached.
  for (int v : {32,64,128}) {
    reset();motorFm03Set(1,v);motorFm03Set(4,64);motorSetPos(2100);advance(50,3,2000);
    assert(applied==(100*v+255)/256);
    motorSetPos(4096);advance(150,3,2000);assert(applied==v);
    motorFm03Set(1,16);advance(50,3,2000);assert(applied==16);
  }
  // Large target changes ramp up; reversing sends a full zero cycle first.
  reset();motorSetPos(4096);
  for(int expected=8;expected<=64;expected+=8) {
    advance(50,3,2000);assert(applied==expected && motorMoving());
  }
  motorSetPos(0);advance(50,3,2000);assert(applied==0 && moving);
  advance(50,3,2000);assert(applied==-8);
  // Tunable acceleration changes startup, never STOP/reversal behavior.
  reset();motorFm03Set(4,32);assert(acceleration==32);
  motorFm03Set(4,0);motorFm03Set(4,65);assert(acceleration==32);
  motorSetPos(4096);advance(50,3,2000);assert(applied==32);
  motorFm03Set(4,16);assert(acceleration==16 && parametersDirty);
  motorPersistParameters();assert(Preferences::writes==0); // No flash writes in motion.
  advance(50,3,2000);assert(applied==48);
  advance(50,3,2000);assert(applied==64);
  motorSetPos(0);advance(50,3,2000);assert(applied==0);
  advance(50,3,2000);assert(applied==-16);
  motorStop();motorPoll();motorPersistParameters();
  assert(!parametersDirty && Preferences::writes==4);
  reset();motorFm03Set(4,1);txDelayUs=1000;motorSetPos(4096);
  advance(50,3,2000);assert(applied==1);
  advance(50,3,2000);assert(applied==2); // Slowest ramp must not stall on CAN overhead.
  // A STOP during acceleration does not wait for a ramp down or the next 50ms slot.
  motorStop();motorPoll();assert(applied==0 && !moving && !enabled);
  motorSetPos(3000);motorJog(80);advance(100,3,2000);
  assert(!moving && applied==0 && result==MOTOR_RESULT_REJECTED); // Late motion cannot unlock STOP.
  motorSetEnabled(true);motorSetPos(3000);advance(50,3,2000);assert(moving && applied>0);
  reset();motorSetPos(4096);advance(100,3,2000);assert(applied==16);
  fakeUs+=200000;feedback(3,2000);assert(applied==24); // A late task cannot jump to full speed.
  reset();motorSetPos(4096);advance(150,3,2000);assert(applied==24);
  fakeUs+=350000;motorPoll();assert(applied==0 && !moving && fault==2);
  motorDiagnosticsPoll();
  reset();motorNoteControlPacket(true);motorSetPos(1800);advance(50,3,2000);assert(applied<0);
  motorStop();motorPoll();assert(applied==0 && !moving);
  reset();motorSetPos(INT32_MAX);assert(target==4096 && limited);
  motorStop();motorSetEnabled(true);motorSetLimits(100,300);motorSetPos(800);assert(target==300);
  reset();motorNoteControlPacket(false);motorSetPos(2500);advance(1050,3,2000);assert(!moving && applied==0 && motorFault()==4);
  reset();motorNoteControlPacket(true);motorSetPos(2500);fakeUs+=350000;motorPoll();assert(!moving && !motorPositionTrusted());
  reset();motorNoteControlPacket(true);motorSetPos(2500);advance(2100,3,2000);assert(!moving && motorFault()==3);
  reset();motorSetPos(2500);failTx=true;advance(50,3,2000);assert(!moving && !enabled && txFailures>0);failTx=false;
  reset();motorSetPos(2500);fakeBus.rx_missed_count=1;advance(50,3,2000);assert(!moving && !enabled);
  reset();assert(motorSetHome() && motorPos()==0);motorJog(INT32_MAX);assert(target==2096);
  motorStop();feedback(1,INT32_MIN);assert(!motorPositionTrusted() && motorPos()==2000);
  reset();assert(motorCalibrationStart(0,0,0)==CAL_BAD_PARAMETER);
  assert(motorCalibrationStart(8,60,6400)==CAL_BAD_PARAMETER);
  reset();assert(motorCalibrationStart(7,0,0)==CAL_OK);advance(50,0,0);
  assert(calibrating && calPending==false);
  motorFm03Set(2,32);assert(tolerance==4);
  const auto n=transmitted.size();assert(motorCalibrationStart(7,0,0)==CAL_OK);
  assert(transmitted.size()==n); // 重复 UDP START 不重发 CAN 标定。
  motorSetPos(100);assert(result==MOTOR_RESULT_REJECTED);
  advance(50,1,INT32_MAX);motorCalibrationCancel();assert(calibrating && cal.error==CAL_CANCEL_UNSUPPORTED);
  advance(50,2,INT32_MAX);advance(50,3,3789);assert(!calibrating && cal.valid && cal.travel==4096);
  assert(motorCalibrationSnapshot().state==CAL_COMPLETED);
  // 慢 CAN 发送不持有状态锁；期间 UDP QUERY 仍能立即回包。
  reset();txDelayUs=1000;
  WiFiUDP waitingUdp;protocolBegin(&waitingUdp);
  duringTxWait=[] {
    FfPacket q{kFfMagic,FF_QUERY,0,42,0,0};handle(q,{},4210);
  };
  advance(50,3,2000);
  assert(!waitingUdp.sent.empty() && enabled && txFailures==0);
  // Live settings received while waiting for CAN must affect the next dial frame.
  reset();motorSetPos(2500);advance(150,3,2000);assert(applied==24);
  txDelayUs=1000;duringTxWait=[] { motorFm03Set(1,4); };
  advance(50,3,2000);assert(applied==4);
  reset();motorSetPos(2010);txDelayUs=1000;
  duringTxWait=[] { motorFm03Set(2,12); };
  advance(50,3,2000);assert(applied==0);
  // STOP 在请求发完前到达，后面的速度帧必须归零，不能再发旧的非零速度。
  reset();motorSetPos(2500);txDelayUs=1000;
  duringTxWait=[] { motorStop(); };
  advance(50,3,2000);assert(applied==0 && !moving);
  // 校准请求在非零速度报文发送中到达，也必须先发完零速度再启动校准。
  reset();transmitted.clear();motorSetPos(2500);txDelayUs=1000;
  duringTxWait=[] {
    if (transmitted.size()==3) {
      duringTxWait=nullptr;motorStop();
      motorSetEnabled(true);
      assert(motorCalibrationStart(9,0,0)==CAL_OK);
    }
  };
  advance(50,3,2000);assert(calibrating && !calPending && applied==0);
  auto calEnd=transmitted.end();
  assert((calEnd-1)->data[10-8]==0x2f); // 最后的 16 字节包是内部校准命令。
  reset();txDelayUs=30000;
  uint32_t begin=millis();assert(!sendPacket(dial,sizeof(dial)));
  assert(millis()-begin==50); // 整包截止时间，而不是每个分片重新等 50ms。
  reset();
  // CAN 解码：分片、坏 CRC、哨兵、其他 CAN ID。
  MotorStatusDecoder d;uint8_t state[28]={0x55,28,4,0,0xbf,0xe5,0,0,0,4,0x2f,9,0,3};
  state[3]=crc(state,3,0x77,0x8c);int32_t coord=2187;memcpy(state+14,&coord,4);
  uint16_t c=crc(state,26,0x3692,0x8408);state[26]=c;state[27]=c>>8;
  for(int i=0;i<28;i+=8)d.feed(0x504,false,false,state+i,std::min(8,28-i),fakeUs+i);
  assert(d.valid() && d.coordinate==2187 && d.packets==1);
  state[27]^=1;for(int i=0;i<28;i+=8)d.feed(0x504,false,false,state+i,std::min(8,28-i),fakeUs+100+i);
  assert(d.packets==1);
  WiFiUDP u;protocolBegin(&u);FfPacket in{kFfMagic,FF_FM03_QUERY,0,1,0,0};handle(in,{},4210);
  assert(u.sent.size()==1 && u.sent[0].size()==28 && u.sent[0][1]==0x86);
  assert(u.sent[0][26]==8 && u.sent[0][27]==0);
  u.sent.clear();in.cmd=FF_FM03_SET;in.a=4;in.b=16;handle(in,{},4210);
  assert(acceleration==16 && u.sent[0][26]==16);
  u.sent.clear();in.cmd=FF_QUERY;handle(in,{},4210);assert(u.sent.size()==2 && u.sent[1].size()==16);
  // Discovery/unknown packets are not a live control link; timeout wraps safely.
  protocolBegin(&u);assert(!protocolLinkAlive());
  in.cmd=FF_DISCOVER;handle(in,{},4210);assert(!protocolLinkAlive());
  in.cmd=0x77;handle(in,{},4210);assert(!protocolLinkAlive());
  in.cmd=FF_QUERY;handle(in,{},4210);assert(protocolLinkAlive());
  fakeUs+=1501000;assert(!protocolLinkAlive());
  fakeUs=(uint64_t)UINT32_MAX*1000-500000;
  handle(in,{},4210);fakeUs+=1000000;assert(protocolLinkAlive());
  fakeUs+=501000;assert(!protocolLinkAlive());
  fakeUs=1000000;reset();protocolBegin(&u);

  oledBegin("change-me", "192.168.4.1");
  assert(u8g2.lines[0]=="FW 2.1.1" && u8g2.lines[1]==deviceId());
  assert(u8g2.lines[2]=="PW change-me" && u8g2.lines[3]=="192.168.4.1");
  const auto bootFrames=u8g2.frames;
  advance(5900,3,2000);oledPoll();assert(u8g2.frames==bootFrames);
  advance(100,3,2000);handle(in,{},4210);oledPoll();
  assert(u8g2.lines[0]=="V2.1.1 READY" && u8g2.lines[1]=="P 2000");
  assert(u8g2.lines[2]=="T 2000" && u8g2.lines[3]=="C:OK L:OK");
  fakeUs+=350000;motorPoll();oledPoll();
  assert(u8g2.lines[1]=="NO FEEDBACK" && u8g2.lines[2]=="P --");
  fakeUs+=1501000;oledPoll();assert(u8g2.lines[3]=="C:LOST L:LOST");

  reset();advance(250,3,2000);fault=1;oledPoll();assert(u8g2.lines[1]=="CAN ERROR");
  fault=2;advance(250,3,2000);oledPoll();assert(u8g2.lines[1]=="POSITION LOST");
  fault=3;advance(250,3,2000);oledPoll();assert(u8g2.lines[1]=="MOVE TIMEOUT");
  fault=4;advance(250,3,2000);oledPoll();assert(u8g2.lines[1]=="CTRL TIMEOUT");
  reset();assert(motorCalibrationStart(10,0,0)==CAL_OK);
  advance(250,1,INT32_MAX);oledPoll();
  assert(u8g2.lines[0]=="V2.1.1 CAL" && u8g2.lines[1]=="CAL 1");
  advance(250,2,INT32_MAX);oledPoll();assert(u8g2.lines[1]=="CAL 2");
  motorCalibrationCancel();advance(250,2,INT32_MAX);oledPoll();
  assert(u8g2.lines[2]=="CAL CONTINUES");
  cal.error=CAL_TIMEOUT;advance(250,2,INT32_MAX);oledPoll();
  assert(u8g2.lines[0]=="V2.1.1 ERR" && u8g2.lines[1]=="CAL TIMEOUT");
  // Movement, faults and calibration must not erase startup credentials early.
  for (int scenario=0; scenario<3; ++scenario) {
    reset();oledBegin("change-me", "192.168.4.1");
    const auto startupFrames=u8g2.frames;
    if (scenario==0) motorSetPos(2300);
    if (scenario==1) fault=1;
    if (scenario==2) assert(motorCalibrationStart(11,0,0)==CAL_OK);
    const auto beforePoll=fakeUs;
    oledPoll();assert(fakeUs==beforePoll); // No blocking delay in the 6s display.
    assert(u8g2.lines[0]=="FW 2.1.1" && u8g2.lines[2]=="PW change-me");
    handle(in,{},4210);assert(protocolLinkAlive()); // UDP remains usable.
    fakeUs+=5999000;oledPoll();assert(u8g2.frames==startupFrames);
    fakeUs+=1000;oledPoll();assert(u8g2.frames==startupFrames+1);
    assert(u8g2.lines[0].find("V2.1.1 ")==0);
  }
  puts("PASS: CAN/UDP control, timeouts, OLED boot credentials, live link, stale position, calibration, errors, 72x40 layout");
}
