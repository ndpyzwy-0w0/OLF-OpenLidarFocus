#include <cassert>
#include <cstdio>
#include "../../firmware/src/motor.cpp"
#include "../../firmware/src/protocol.cpp"
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
  origin=0; minLim=0;maxLim=4096;target=0;cal={};fault=0;
  fakeBus={};failTx=false;rxMissed=0;lastTx=0;transmitted.clear();
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
  reset();motorNoteControlPacket(true);motorSetPos(1800);advance(50,3,2000);assert(applied<0);
  motorStop();assert(applied==0 && !moving);
  reset();motorSetPos(INT32_MAX);assert(target==4096 && limited);
  motorStop();motorSetLimits(100,300);motorSetPos(800);assert(target==300);
  reset();motorNoteControlPacket(false);motorSetPos(2500);advance(1050,3,2000);assert(!moving && applied==0);
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
  const auto n=transmitted.size();assert(motorCalibrationStart(7,0,0)==CAL_OK);
  assert(transmitted.size()==n); // 重复 UDP START 不重发 CAN 标定。
  motorSetPos(100);assert(result==MOTOR_RESULT_REJECTED);
  advance(50,1,INT32_MAX);motorCalibrationCancel();assert(calibrating && cal.error==CAL_CANCEL_UNSUPPORTED);
  advance(50,2,INT32_MAX);advance(50,3,3789);assert(!calibrating && cal.valid && cal.travel==4096);
  assert(motorCalibrationSnapshot().state==CAL_COMPLETED);
  // CAN 解码：分片、坏 CRC、哨兵、其他 CAN ID。
  MotorStatusDecoder d;uint8_t state[28]={0x55,28,4,0,0xbf,0xe5,0,0,0,4,0x2f,9,0,3};
  state[3]=crc(state,3,0x77,0x8c);int32_t coord=2187;memcpy(state+14,&coord,4);
  uint16_t c=crc(state,26,0x3692,0x8408);state[26]=c;state[27]=c>>8;
  for(int i=0;i<28;i+=8)d.feed(0x504,false,false,state+i,std::min(8,28-i),fakeUs+i);
  assert(d.valid() && d.coordinate==2187 && d.packets==1);
  state[27]^=1;for(int i=0;i<28;i+=8)d.feed(0x504,false,false,state+i,std::min(8,28-i),fakeUs+100+i);
  assert(d.packets==1);
  WiFiUDP u;protocolBegin(&u);FfPacket in{kFfMagic,FF_FM03_QUERY,0,1,0,0};handle(in,{},4210);
  assert(u.sent.size()==1 && u.sent[0].size()==26 && u.sent[0][1]==0x86);
  u.sent.clear();in.cmd=FF_QUERY;handle(in,{},4210);assert(u.sent.size()==2 && u.sent[1].size()==16);
  puts("PASS: CAN framing/CRC, feedback positioning, limits, timeouts, tx/rx failure, home, calibration, UDP");
}
