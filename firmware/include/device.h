#pragma once

#include <stdint.h>

// Reported in discovery; firmware releases are independent of App versions.
static const uint8_t kFwMajor = 2;
static const uint8_t kFwMinor = 0;
static const uint8_t kFwPatch = 4;

// Identity of this board, derived from the AP interface MAC. Call after
// WiFi.mode(WIFI_AP) and before starting the AP, because deviceId() is the SSID.
void deviceBegin();
const char *deviceId();       // "FF-75A578"
const uint8_t *deviceMac();   // 6 bytes; matches the BSSID that a scan reports
const char *deviceMacText();  // "92:DA:72:75:A5:78"
