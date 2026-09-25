#pragma once
#define UART_NUM_2 2
#define UART_MODE_RS485_HALF_DUPLEX 0
#define UART_MODE_UART 1
#define pdMS_TO_TICKS(x) (x)
inline void uart_wait_tx_done(int,int) {}
inline void uart_set_mode(int,int) {}
