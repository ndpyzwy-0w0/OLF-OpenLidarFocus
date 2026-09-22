#include "device.h"

#include <Arduino.h>
#include <WiFi.h>
#include <string.h>

static char id[10] = "FF-000000";  // "FF-" + six hex digits + NUL
static char macText[18] = "00:00:00:00:00:00";
static uint8_t mac[6] = {0};

void deviceBegin() {
  // Use the AP interface MAC rather than the eFuse base MAC, so the id stays
  // correlatable with the BSSID a scan reports.
  WiFi.softAPmacAddress(mac);
  snprintf(id, sizeof(id), "FF-%02X%02X%02X", mac[3], mac[4], mac[5]);
  snprintf(macText, sizeof(macText), "%02X:%02X:%02X:%02X:%02X:%02X", mac[0],
           mac[1], mac[2], mac[3], mac[4], mac[5]);
}

const char *deviceId() { return id; }
const uint8_t *deviceMac() { return mac; }
const char *deviceMacText() { return macText; }
