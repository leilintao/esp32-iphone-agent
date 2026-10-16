#include "boot_voice.h"
#if defined(STATUS_DISPLAY_ES3C28P)
#include <Arduino.h>
#include <ESP_I2S.h>
#include <Wire.h>
#include <atomic>
#include "welcome_audio.h"

static std::atomic<unsigned> state{0};
static portMUX_TYPE replayLock = portMUX_INITIALIZER_UNLOCKED;
static bool active = false, acceptingRepeat = false;
static unsigned requestedRepeats = 1;
static const char *states[] = {"pending", "waiting", "playing", "done", "i2c-error", "codec-error", "i2s-error", "write-error", "task-error"};
static constexpr uint8_t CODEC = 0x18;
static constexpr int AMP = 1;
static constexpr uint32_t RATE = 16000;
static constexpr uint32_t START_MS = 5000;

static bool regWrite(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(CODEC);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

static bool regMask(uint8_t reg, uint8_t keep, uint8_t bits) {
  Wire.beginTransmission(CODEC);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0 || Wire.requestFrom(CODEC, (uint8_t)1) != 1) return false;
  return regWrite(reg, (Wire.read() & keep) | bits);
}

// Fixed 16 kHz, 16-bit stereo I2S, 4.096 MHz MCLK, codec slave mode.
// Register sequence and divider coefficients follow Espressif's ES8311 driver:
// https://github.com/espressif/esp-bsp/blob/f259a6abd5808019b1903a422092a4234ca95a51/components/es8311/es8311.c
static bool codecBegin() {
  if (!regWrite(0x00, 0x1f)) return false;
  delay(20);
  if (!regWrite(0x00, 0x00) || !regWrite(0x00, 0x80) || !regWrite(0x01, 0x3f)) return false;
  if (!regMask(0x02, 0x07, 0x00) || !regWrite(0x03, 0x10) || !regWrite(0x04, 0x10) ||
      !regWrite(0x05, 0x00) || !regMask(0x06, 0xc0, 0x03) ||
      !regMask(0x07, 0xc0, 0x00) || !regWrite(0x08, 0xff) || !regMask(0x00, 0xbf, 0x00)) return false;
  const uint8_t settings[][2] = {
    {0x09, 0x0c}, {0x0a, 0x0c}, // 16-bit I2S data in / out
    {0x0d, 0x01}, {0x0e, 0x02}, {0x12, 0x00}, {0x13, 0x10}, // analog / DAC power
    {0x1c, 0x6a}, {0x37, 0x08}, // EQ bypass
    {0x32, 0xe5}, {0x31, 0x00}  // DAC gain (90% register scale), unmute
  };
  for (const auto &pair : settings) if (!regWrite(pair[0], pair[1])) return false;
  return true;
}

static int16_t decode(uint8_t value) {
  uint8_t u = ~value;
  int sample = (((u & 0x0f) << 3) + 0x84) << ((u & 0x70) >> 4);
  return (u & 0x80) ? 0x84 - sample : sample - 0x84;
}

static void voiceTask(void *immediate) {
  // LCDWIKI schematic: GPIO8 -> codec DSDIN; GPIO6 is the codec's ADC output.
  // No microphone recording is enabled. Duplicate mono into both DAC slots.
  I2SClass audio;
  bool bus = false, i2s = false;
  pinMode(AMP, OUTPUT);
  digitalWrite(AMP, HIGH);
  do {
    bus = Wire.begin(16, 15, 100000);
    Wire.setTimeOut(100);
    if (!bus) { state = 4; break; }
    Wire.beginTransmission(CODEC);
    if (Wire.endTransmission() != 0) { state = 5; break; }
    audio.setPins(5, 7, 8, -1, 4);
    audio.setTimeout(1000);
    i2s = audio.begin(I2S_MODE_STD, RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
    if (!i2s) { state = 6; break; }
    if (!codecBegin()) { state = 5; break; }
    state = 1;
    int32_t remaining = immediate ? 0 : (int32_t)(START_MS - millis());
    if (remaining > 0) vTaskDelay(pdMS_TO_TICKS(remaining));
    state = 2;
    Serial.printf("voice: start at %lu ms\n", millis());
    digitalWrite(AMP, LOW);
    bool ok = true;
    int16_t frames[512];
    unsigned played = 0;
    while (ok) {
      portENTER_CRITICAL(&replayLock);
      bool again = played < requestedRepeats;
      if (!again) acceptingRepeat = false;
      portEXIT_CRITICAL(&replayLock);
      if (!again) break;
      Serial.printf("voice: pass %u at %lu ms\n", played + 1, millis());
      for (size_t pos = 0; pos < sizeof WELCOME_AUDIO && ok;) {
        size_t samples = min((size_t)256, sizeof WELCOME_AUDIO - pos);
        for (size_t i = 0; i < samples; i++) {
          int16_t sample = decode(pgm_read_byte(WELCOME_AUDIO + pos + i));
          frames[i * 2] = frames[i * 2 + 1] = sample;
        }
        ok = audio.write((uint8_t *)frames, samples * 4) == samples * 4;
        pos += samples;
      }
      played++;
    }
    // Send enough silence to drain the DMA queue before switching off the amp.
    memset(frames, 0, sizeof frames);
    if (ok) for (int i = 0; i < 10 && ok; i++) ok = audio.write((uint8_t *)frames, sizeof frames) == sizeof frames;
    delay(120);
    if (!ok) state = 7;
    Serial.printf("voice: delivered %u pass(es)\n", played);
  } while (false);
  digitalWrite(AMP, HIGH);
  if (bus) regMask(0x31, 0xff, 0x60); // mute before removing the I2S clock
  if (i2s) audio.end();
  if (bus) Wire.end();
  portENTER_CRITICAL(&replayLock);
  acceptingRepeat = false;
  active = false;
  if (state == 2) state = 3;
  portEXIT_CRITICAL(&replayLock);
  Serial.printf("voice: %s at %lu ms\n", boot_voice_status(), millis());
  vTaskDelete(NULL);
}

void boot_voice_begin() {
  active = acceptingRepeat = true;
  if (xTaskCreate(voiceTask, "welcome", 6144, NULL, 1, NULL) != pdPASS) {
    active = acceptingRepeat = false;
    state = 8;
  }
}
bool boot_voice_twice() {
  portENTER_CRITICAL(&replayLock);
  bool busy = active;
  bool accepted = !busy || acceptingRepeat;
  if (accepted) {
    requestedRepeats = 2;
    if (!busy) { active = acceptingRepeat = true; state = 0; }
  }
  portEXIT_CRITICAL(&replayLock);
  if (!accepted) return false;
  if (!busy && xTaskCreate(voiceTask, "welcome", 6144, (void *)1, 1, NULL) != pdPASS) {
    portENTER_CRITICAL(&replayLock);
    active = acceptingRepeat = false;
    state = 8;
    portEXIT_CRITICAL(&replayLock);
    return false;
  }
  return true;
}
const char *boot_voice_status() { return states[state.load()]; }
#else
void boot_voice_begin() {}
const char *boot_voice_status() { return "disabled"; }
bool boot_voice_twice() { return false; }
#endif
