#pragma once
#include <vector>
#include <cassert>
#include "Arduino.h"
#include "freertos/semphr.h"
#include <stdint.h>
#define ESP_OK 0
#define ESP_ERR_INVALID_STATE 0x103
#define ESP_ERR_TIMEOUT 0x107
using esp_err_t=int;
#define TWAI_MODE_NORMAL 0
#define TWAI_STATE_RUNNING 1
#define TWAI_STATE_BUS_OFF 2
#define TWAI_STATE_STOPPED 0
using gpio_num_t=int;
struct twai_general_config_t { int tx_queue_len,rx_queue_len; };
struct twai_timing_config_t { int bitrate; };
struct twai_filter_config_t { int mask; };
#define TWAI_GENERAL_CONFIG_DEFAULT(tx,rx,mode) {5,5}
#define TWAI_TIMING_CONFIG_1MBITS() {1000000}
#define TWAI_FILTER_CONFIG_ACCEPT_ALL() {0}
struct twai_status_info_t {
  int state=1; unsigned msgs_to_tx=0;
  uint32_t rx_missed_count=0,tx_error_counter=0,rx_error_counter=0,tx_failed_count=0;
  uint32_t rx_overrun_count=0,bus_error_count=0,arb_lost_count=0;
};
struct twai_message_t { uint32_t identifier=0; bool extd=false,rtr=false; uint8_t data_length_code=0,data[8]{}; };
inline std::vector<twai_message_t> transmitted;
inline bool failTx=false;
inline uint64_t txCompleteAt=0;
inline uint32_t txDelayUs=0;
inline void (*duringTxWait)()=nullptr;
inline twai_status_info_t fakeBus;
inline int twai_driver_install(twai_general_config_t* g,twai_timing_config_t* t,twai_filter_config_t*) {
  return g->tx_queue_len==0 && t->bitrate==1000000 ? 0 : -1;
}
inline int twai_start() { fakeBus.state=1; return 0; }
inline int twai_driver_uninstall() { return 0; }
inline int twai_initiate_recovery() { fakeBus.state=0; return 0; }
inline int twai_get_status_info(twai_status_info_t* s) {
  if (fakeBus.msgs_to_tx) {
    if (duringTxWait && stateLockDepth==0) duringTxWait();
    if (fakeUs>=txCompleteAt) fakeBus.msgs_to_tx=0;
  }
  *s=fakeBus;return 0;
}
inline int twai_transmit(twai_message_t* m,int) {
  assert(stateLockDepth==0);
  if(failTx) return -1;
  transmitted.push_back(*m);
  if (txDelayUs) { fakeBus.msgs_to_tx=1; txCompleteAt=fakeUs+txDelayUs; }
  return 0;
}
inline int twai_receive(twai_message_t*,int) { return -1; }
