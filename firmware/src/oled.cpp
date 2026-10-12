#include "oled.h"
#include "motor.h"
#include "device.h"
#include "protocol.h"

#include <Arduino.h>
#include <Wire.h>
#include <U8g2lib.h>

static U8G2_SSD1306_72X40_ER_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE);
static bool present = false;
static uint32_t lastMs = 0;
static uint32_t bootMs = 0;
static bool showingBoot = false;

static bool probe(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

void oledBegin(const char *password, const char *ip) {
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
  u8g2.clearBuffer();
  u8g2.setCursor(0, 7);
  u8g2.print("FW ");
  u8g2.print(kFwMajor); u8g2.print('.');
  u8g2.print(kFwMinor); u8g2.print('.'); u8g2.print(kFwPatch);
  u8g2.setCursor(0, 17);
  u8g2.print(deviceId());
  u8g2.setCursor(0, 27);
  u8g2.print("PW "); u8g2.print(password);
  u8g2.setCursor(0, 37);
  u8g2.print(ip);
  u8g2.sendBuffer();
  bootMs = lastMs = millis();
  showingBoot = true;
}

void oledPoll() {
  if (!present) return;
  uint32_t now = millis();
  // Hold credentials for the full 6s; UDP/CAN and motor protection keep running.
  if (showingBoot && now - bootMs < 6000) return;
  if (!showingBoot && now - lastMs < 250) return;
  if (showingBoot) Serial.printf("oled startup elapsed=%lu ms\n", (unsigned long)(now - bootMs));
  showingBoot = false;
  lastMs = now;

  const uint8_t motorError = motorFault();
  const auto fm = motorFm03Snapshot();
  const auto cal = motorCalibrationSnapshot();
  const bool trusted = motorPositionTrusted();
  const bool can = motorCanOk();
  const bool calibrating = motorCalibrationActive() || fm.stage == 1 || fm.stage == 2;
  const char *error = nullptr;
  if (cal.error == CAL_TIMEOUT) error = "CAL TIMEOUT";
  else if (motorError == 1) error = "CAN ERROR";
  else if (motorError == 2) error = "POSITION LOST";
  else if (motorError == 3) error = "MOVE TIMEOUT";
  else if (motorError == 4) error = "CTRL TIMEOUT";
  else if (!can) error = "NO FEEDBACK";
  const char *st = error ? "ERR" : calibrating ? "CAL" :
    !motorEnabled() ? "OFF" : !trusted ? "WAIT" : motorMoving() ? "RUN" : "READY";
  u8g2.clearBuffer();
  u8g2.setCursor(0, 7);
  u8g2.print('V');
  u8g2.print(kFwMajor); u8g2.print('.');
  u8g2.print(kFwMinor); u8g2.print('.'); u8g2.print(kFwPatch);
  u8g2.print(' ');
  u8g2.print(st);
  u8g2.setCursor(0, 17);
  if (error) u8g2.print(error);
  else if (calibrating) {
    u8g2.print("CAL ");
    if (fm.stage == 1 || fm.stage == 2) u8g2.print(fm.stage);
    else u8g2.print("WAIT");
  } else {
    u8g2.print("P ");
    if (trusted) u8g2.print(motorPos()); else u8g2.print("--");
  }
  u8g2.setCursor(0, 27);
  if (calibrating) u8g2.print(cal.error == CAL_CANCEL_UNSUPPORTED ? "CAL CONTINUES" : "WAIT FM03");
  else if (error) {
    u8g2.print("P ");
    if (trusted) u8g2.print(motorPos()); else u8g2.print("--");
  } else {
    u8g2.print("T ");
    if (trusted) u8g2.print(motorTarget()); else u8g2.print("--");
  }
  u8g2.setCursor(0, 37);
  u8g2.print(can ? "C:OK " : "C:LOST ");
  u8g2.print(protocolLinkAlive() ? "L:OK" : "L:LOST");
  u8g2.sendBuffer();
}
