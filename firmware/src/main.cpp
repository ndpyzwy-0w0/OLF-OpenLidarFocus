#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <WiFiUdp.h>
#include <DNSServer.h>
#include <esp_system.h>

#include "device.h"
#include "motor.h"
#include "protocol.h"
#include "oled.h"

static const int PIN_BTN = 0;

static const char *kPass = "ffdebug1";
static const uint8_t kApChannel = 1;
// 允许多台设备同时接入（手机 + 调试机），协议仍约定同一时刻只有一个控制器在发命令。
static const uint8_t kApMaxStations = 4;

static DNSServer dns;
static WebServer http(80);
static WiFiUDP udp;
static bool lastBtn = true;

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
<p>UDP 4210。STEP5 DIR6 EN7 UART GPIO12→TMC RX OLED SDA8 SCL9</p>
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

// iOS/Android 的联网探测必须按各自规范回答，否则系统会判定本 AP 是强制门户并弹
// “登录网络”面板，干扰 App 的 UDP 连接。人类随便输网址仍由 onNotFound 跳到根页面。
static void handleAppleProbe() {
  http.send(200, "text/html",
            "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>");
}
static void handleAndroidProbe() { http.send(204, "text/plain", ""); }

static void onWiFiEvent(WiFiEvent_t event) {
  switch (event) {
    case ARDUINO_EVENT_WIFI_AP_START:
      Serial.println("wifi ap started");
      break;
    case ARDUINO_EVENT_WIFI_AP_STOP:
      Serial.println("wifi ap stopped");
      break;
    case ARDUINO_EVENT_WIFI_AP_STACONNECTED:
      Serial.printf("wifi client connected count=%d\n", WiFi.softAPgetStationNum());
      break;
    case ARDUINO_EVENT_WIFI_AP_STADISCONNECTED:
      Serial.printf("wifi client disconnected count=%d\n", WiFi.softAPgetStationNum());
      break;
    default:
      break;
  }
}

static void logWiFiState() {
  static uint8_t lastStations = 255;
  static uint32_t lastLogMs = 0;
  const uint32_t now = millis();
  const uint8_t stations = WiFi.softAPgetStationNum();
  if (stations != lastStations || now - lastLogMs >= 30000) {
    lastStations = stations;
    lastLogMs = now;
    Serial.printf("wifi ap=%d clients=%u channel=%u ip=%s\n",
                  WiFi.getMode() == WIFI_AP ? 1 : 0, stations, kApChannel,
                  WiFi.softAPIP().toString().c_str());
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_BTN, INPUT_PULLUP);

  Serial.printf("reset reason=%d\n", (int)esp_reset_reason());
  motorBegin();
  oledBegin();

  btStop();
  WiFi.persistent(false);
  WiFi.onEvent(onWiFiEvent);
  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
  deviceBegin();
  WiFi.softAP(deviceId(), kPass, kApChannel, false, kApMaxStations);
  delay(100);

  IPAddress ip = WiFi.softAPIP();
  dns.start(53, "*", ip);
  http.on("/", handleRoot);
  http.on("/ping", handlePing);
  http.on("/hotspot-detect.html", handleAppleProbe);
  http.on("/library/test/success.html", handleAppleProbe);
  http.on("/generate_204", handleAndroidProbe);
  http.onNotFound(handleCaptive);
  http.begin();
  udp.begin(kUdpPort);
  protocolBegin(&udp);

  Serial.printf("AP %s  pass %s  mac %s  http://%s  udp %u\n", deviceId(), kPass,
                deviceMacText(), ip.toString().c_str(), kUdpPort);
  logWiFiState();
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
  motorStandbyTick();
  oledPoll();
  logWiFiState();

  bool btn = digitalRead(PIN_BTN);
  if (lastBtn && !btn) {
    motorSetEnabled(!motorEnabled());
    Serial.printf("en %d\n", motorEnabled() ? 1 : 0);
    delay(40);
  }
  lastBtn = btn;
}
