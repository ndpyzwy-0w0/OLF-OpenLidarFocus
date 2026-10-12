#pragma once

// 0.42" 72x40 SSD1306 I2C. VCC=3.3V, not 5V.
static const int PIN_OLED_SDA = 8;
static const int PIN_OLED_SCL = 9;

void oledBegin(const char *password, const char *ip);
void oledPoll();
