#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <WiFiUdp.h>
#include <DNSServer.h>

#include "motor.h"
#include "protocol.h"
#include "oled.h"

static const int PIN_LED = 48;
static const int PIN_BTN = 0;

static const char *kSsid = "FF-debug";
static const char *kPass = "ffdebug1";

static const uint8_t B = 80;

static DNSServer dns;
static WebServer http(80);
static WiFiUDP udp;
static bool lastBtn = true;
static uint8_t lastLed = 255;

static void setLed(uint8_t r, uint8_t g, uint8_t b) {
  uint8_t key = (uint8_t)((r ? 1 : 0) | (g ? 2 : 0) | (b ? 4 : 0));
  if (key == lastLed) return;
  lastLed = key;
  neopixelWrite(PIN_LED, r, g, b);
}

static void updateLed() {
  if (!motorEnabled()) setLed(B, 0, 0);
  else if (motorMoving()) setLed(B, B, 0);
  else setLed(0, B, 0);
}

static const char kPage[] = R"html(
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FF WiFi</title>
<style>
 body{font-family:-apple-system,sans-serif;padding:24px;max-width:28em}
 button{font-size:18px;padding:.6em 1.2em}
 pre{background:#f4f4f4;padding:12px;white-space:pre-wrap}
</style>
<h1>跟焦器</h1>
<p>UDP 4210。STEP5 DIR6 EN7 UART GPIO11 TX--1k--PDN GPIO12 RX OLED SDA8 SCL9</p>
<button onclick="ping()">测延迟</button>
<pre id="out">点按钮测 HTTP 往返。</pre>
<script>
async function ping(){
  const n=20, t=[];
  out.textContent = "测量中…";
  for(let i=0;i<n;i++){
    const a=performance.now();
    await fetch("/ping?n="+i,{cache:"no-store"});
    t.push(performance.now()-a);
  }
  t.sort((a,b)=>a-b);
  const avg=t.reduce((a,b)=>a+b)/n;
  out.textContent = t.map(x=>x.toFixed(1)+" ms").join("\n")
    +"\n\n平均 "+avg.toFixed(1)+" ms\n最小 "+t[0].toFixed(1)+" ms";
}
</script>
)html";

static void handleRoot() { http.send(200, "text/html; charset=utf-8", kPage); }
static void handlePing() { http.send(200, "text/plain", "ok"); }
static void handleCaptive() { http.sendHeader("Location", "/", true); http.send(302, "text/plain", ""); }

void setup() {
  Serial.begin(115200);
  pinMode(PIN_BTN, INPUT_PULLUP);

  motorBegin();
  neopixelWrite(PIN_LED, 80, 0, 0);
  delay(50);
  oledBegin();

  btStop();
  WiFi.persistent(false);
  WiFi.mode(WIFI_AP);
  WiFi.setTxPower(WIFI_POWER_8_5dBm);
  WiFi.softAP(kSsid, kPass);
  delay(100);

  IPAddress ip = WiFi.softAPIP();
  dns.start(53, "*", ip);
  http.on("/", handleRoot);
  http.on("/ping", handlePing);
  http.on("/hotspot-detect.html", handleRoot);
  http.on("/library/test/success.html", handleRoot);
  http.on("/generate_204", handlePing);
  http.onNotFound(handleCaptive);
  http.begin();
  udp.begin(kUdpPort);
  protocolBegin(&udp);

  updateLed();
  Serial.printf("AP %s  pass %s  http://%s  udp %u\n",
                kSsid, kPass, ip.toString().c_str(), kUdpPort);
}

void loop() {
  static bool uartTried = false;
  if (!uartTried) {
    uartTried = true;
    motorUartBegin();
  }
  static bool usbOnce = false;
  if (Serial && !usbOnce) {
    usbOnce = true;
    Serial.printf("uart %s ok=%d\n", motorUartHint(), motorUartOk() ? 1 : 0);
  }
  dns.processNextRequest();
  http.handleClient();
  protocolPoll();
  updateLed();
  oledPoll();

  bool btn = digitalRead(PIN_BTN);
  if (lastBtn && !btn) {
    motorSetEnabled(!motorEnabled());
    Serial.printf("en %d\n", motorEnabled() ? 1 : 0);
    delay(40);
  }
  lastBtn = btn;
}
