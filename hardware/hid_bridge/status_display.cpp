#include "status_display.h"

#if defined(STATUS_DISPLAY_ES3C28P)
#include <Adafruit_ILI9341.h>
#include <SPI.h>
#include <esp_heap_caps.h>
#include "phone_title.h"
#include "ble_link.h"
#include "netcfg.h"
#include "video_link.h"
#include "src/airplay/airplay.h"

// LCDWIKI ES3C28P: reset is shared with CHIP_PU, so never drive a reset GPIO.
static SPIClass lcdSPI(FSPI);
static Adafruit_ILI9341 lcd(&lcdSPI, 46, 10, -1);
static GFXcanvas16 row(228, 20);
static String previous[8];
static String lastVerb = "none";
static uint32_t nextRefresh;
static bool ready;
static int previousUsb = -1, previousBlocks = -1;
static constexpr uint16_t BG = 0x2145, FG = 0xF739, MUTED = 0xADB6;
static constexpr uint16_t AMBER = 0xEDCA, TRACK = 0x4AAB, CARD = 0x29A7;

static void line(int index, int x, int y, const String &value,
                 uint16_t color = FG, uint16_t bg = BG, int size = 1,
                 int width = 212, bool centered = false, int height = 20) {
  if (previous[index] == value) return;
  previous[index] = value;
  row.fillScreen(bg);
  row.setCursor(centered ? (width - (int)value.length() * 6 * size) / 2 : 0, 2);
  row.setTextColor(color);
  row.setTextSize(size);
  row.setTextWrap(false);
  row.print(value);
  // Canvas stride is 228; crop by drawing each scanline of the requested region.
  for (int dy = 0; dy < min(height, 320 - y); dy++)
    lcd.drawRGBBitmap(x, y + dy, row.getBuffer() + dy * 228, width, 1);
}

static void text(int x, int y, const char *value, uint16_t color = MUTED) {
  lcd.setTextSize(1);
  lcd.setTextColor(color);
  lcd.setCursor(x, y);
  lcd.print(value);
}

static void gauge(int state) {
  if (state == previousUsb) return;
  previousUsb = state;
  // A connection indicator, not a fabricated progress or confidence percentage.
  // Fill the annulus with scanline spans. Radial lines leave holes between
  // rounded endpoints; this integer mask matches the approved simulator.
  uint16_t color = state == 2 ? AMBER : TRACK;
  for (int y = 77; y <= 187; y++) {
    int span = -1;
    for (int x = 65; x <= 176; x++) {
      int dx = x - 120, dy = y - 132;
      int r2 = dx * dx + dy * dy;
      bool inside = r2 >= 48 * 48 && r2 <= 55 * 55 && (dy <= 0 || abs(dx) >= dy);
      if (inside && span < 0) span = x;
      if (!inside && span >= 0) {
        lcd.drawFastHLine(span, y, x - span, color);
        span = -1;
      }
    }
  }
}

void display_begin() {
  pinMode(45, OUTPUT);
  digitalWrite(45, LOW);
  // Disable unused audio amplifier; it is active-low on this board.
  pinMode(1, OUTPUT);
  digitalWrite(1, HIGH);
  if (!row.getBuffer()) {
    Serial.println("display: insufficient RAM");
    return;
  }
  lcdSPI.begin(12, 13, 11, 10);
  lcd.begin(20000000);
  lcd.setRotation(0);
  // This IPS panel needs INVON for normal colors. The library's generic default
  // otherwise shows complementary colors (dark -> pale, amber -> blue).
  lcd.invertDisplay(true);
  lcd.fillScreen(BG);
  lcd.setTextWrap(false);
  lcd.drawBitmap(14, 10, PHONE_TITLE, 180, 28, FG);
  text(14, 43, "USB HID CONTROLLER");
  lcd.drawFastHLine(14, 60, 212, TRACK);
  lcd.fillRoundRect(14, 194, 99, 45, 3, CARD);
  lcd.fillRoundRect(127, 194, 99, 45, 3, CARD);
  text(23, 202, "BLE");
  text(136, 202, "VIDEO");
  text(14, 251, "PSRAM");
  // 20% PWM brightness limits extra USB current. Do not touch USB GPIO19/20.
  if (ledcAttach(45, 5000, 8)) ledcWrite(45, 51);
  else digitalWrite(45, HIGH);
  ready = true;
}

void display_command(const String &verb) {
  // Only the command verb; never show typed text, API keys or network passwords.
  if (verb != "ping" && verb != "log" && verb != "app")
    lastVerb = verb.substring(0, 12);
}

void display_poll(const char *usb, const char *reset) {
  if (!ready || (int32_t)(millis() - nextRefresh) < 0) return;
  nextRefresh = millis() + 1000;
  VideoStats v = video_stats();
  const int ap = airplay_state();
  int state = !strcmp(usb, "ok") ? 2 : !strcmp(usb, "asleep") ? 1 : 0;
  gauge(state);
  // Restrict text erase rectangles to the hole inside the gauge.
  line(0, 84, 111, state == 2 ? "ONLINE" : state == 1 ? "ASLEEP" : "NO USB",
       state == 2 ? AMBER : MUTED, BG, 2, 72, true);
  line(1, 84, 141, String("USB / ") + usb, MUTED, BG, 1, 72, true);
  line(2, 14, 175, String("Wi-Fi ") + net_mode() + " " + net_ip(), MUTED, BG, 1, 212, false, 16);
  line(3, 23, 214, ble_connected() ? "LINKED" : "WAIT", FG, CARD, 2, 80);
  // Keep values within the 80-pixel card at 2x font size.
  String video = ap == AIRPLAY_STREAMING ? String((int)(v.fps + 0.5f)) + " FPS" :
                 ap == AIRPLAY_CONNECTED ? "READY" : "IDLE";
  line(4, 136, 214, video, FG, CARD, 2, 80);
  uint32_t freeRam = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
  uint32_t totalRam = ESP.getPsramSize();
  line(5, 152, 249, String(freeRam / 1048576.0f, 1) + " MB", AMBER, BG, 2, 78);
  int blocks = totalRam ? min(20, (int)((uint64_t)freeRam * 20 / totalRam)) : 0;
  if (blocks != previousBlocks) {
    previousBlocks = blocks;
    for (int i = 0; i < 20; i++)
      lcd.fillRect(14 + i * 11, 273, 7, 8, i < blocks ? AMBER : TRACK);
  }
  String action = lastVerb;
  action.toUpperCase();
  line(6, 14, 297, action, FG, BG, action.length() <= 10 ? 2 : 1, 148);
  uint32_t seconds = millis() / 1000;
  char footer[16];
  if (seconds / 60 < 1000)
    snprintf(footer, sizeof footer, "%lum%02lus", (unsigned long)(seconds / 60),
             (unsigned long)(seconds % 60));
  else
    snprintf(footer, sizeof footer, "%luh", (unsigned long)(seconds / 3600));
  line(7, 176, 301, footer, MUTED, BG, 1, 50);
}
#else
void display_begin() {}
void display_poll(const char *, const char *) {}
void display_command(const String &) {}
#endif
