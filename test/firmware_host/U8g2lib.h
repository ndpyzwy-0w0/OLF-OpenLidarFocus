#pragma once
#include <array>
#include <string>
#include <cassert>
#define U8G2_R0 0
#define U8X8_PIN_NONE 255
inline const char u8g2_font_5x7_tr[] = "";
class U8G2_SSD1306_72X40_ER_F_HW_I2C {
public:
  std::array<std::string, 4> lines{};
  unsigned frames = 0;
  U8G2_SSD1306_72X40_ER_F_HW_I2C(int, int) {}
  void setI2CAddress(uint8_t) {}
  bool begin() { return true; }
  void setFont(const char *) {}
  void setFontMode(int) {}
  void clearBuffer() { lines = {}; }
  void setCursor(int x, int y) {
    assert(x == 0 && y >= 7 && y <= 37 && (y - 7) % 10 == 0);
    row = (y - 7) / 10;
  }
  void print(const char *v) { lines[row] += v; }
  void print(char v) { lines[row] += v; }
  template<class T> void print(T v) { lines[row] += std::to_string(v); }
  void sendBuffer() {
    for (const auto &line : lines) assert(line.size() * 5 <= 72);
    ++frames;
  }
private:
  unsigned row = 0;
};
