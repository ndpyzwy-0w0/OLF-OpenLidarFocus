#include "oled.h"
#include "motor.h"

#include <Arduino.h>
#include <Wire.h>
#include <U8g2lib.h>

static U8G2_SSD1306_72X40_ER_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE);
static bool present = false;
static uint32_t lastMs = 0;
static int32_t lastPos = 0x7fffffff;
static int32_t lastTarget = 0x7fffffff;
static uint8_t lastBits = 0xff;

static bool probe(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

void oledBegin() {
  Wire.begin(PIN_OLED_SDA, PIN_OLED_SCL);
  Wire.setClock(400000);
  delay(20);
  uint8_t addr = 0;
  if (probe(0x3C)) addr = 0x3C;
  else if (probe(0x3D)) addr = 0x3D;
  if (!addr) {
    Serial.println("oled skip");
    return;
  }
  u8g2.setI2CAddress(addr << 1);
  if (!u8g2.begin()) {
    Serial.println("oled begin fail");
    return;
  }
  present = true;
  u8g2.setFont(u8g2_font_5x7_tr);
  u8g2.setFontMode(0);
  Serial.printf("oled 0x%02x\n", addr);
  oledPoll();
}

void oledPoll() {
  if (!present) return;
  uint32_t now = millis();
  uint8_t bits = (motorEnabled() ? 1 : 0) | (motorMoving() ? 2 : 0) | (motorUartOk() ? 4 : 0);
  int32_t pos = motorPos();
  int32_t tgt = motorTarget();
  if (bits == lastBits && pos == lastPos && tgt == lastTarget && now - lastMs < 250) return;
  lastBits = bits;
  lastPos = pos;
  lastTarget = tgt;
  lastMs = now;

  const char *st = !motorEnabled() ? "OFF" : (motorStandbyOff() ? "SLP" : (motorMoving() ? "RUN" : "EN"));
  u8g2.clearBuffer();
  u8g2.setCursor(0, 7);
  u8g2.print("FF ");
  u8g2.print(st);
  if (motorUartOk()) u8g2.print(" U");
  u8g2.setCursor(0, 18);
  u8g2.print("P ");
  u8g2.print(pos);
  u8g2.setCursor(0, 29);
  u8g2.print("T ");
  u8g2.print(tgt);
  u8g2.setCursor(0, 40);
  u8g2.print(motorUartHint());
  u8g2.sendBuffer();
}
