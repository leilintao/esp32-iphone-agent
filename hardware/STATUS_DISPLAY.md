# ES3C28P / ES3N28P status screen

The optional 240x320 ILI9341 display uses the selected dark amber instrument
layout, titled `天宝Phone`. It shows USB state, BLE connectivity, Wi-Fi mode/IP,
AirPlay state or frame rate, free PSRAM, uptime, reset reason,
and the most recent meaningful board command verb. It does not claim that an AI
task has completed: that information is owned by the agent, not the board.
Typed text and Wi-Fi passwords are never displayed.
Keepalive and log commands do not replace the last meaningful command verb.
The arc indicates USB connectivity; it is not task
progress. The memory meter indicates the fraction of total PSRAM that is free.

Install dependencies and compile:

```sh
arduino-cli lib install "Adafruit ILI9341@1.6.4" "Adafruit GFX Library@1.12.6" "Adafruit BusIO@1.17.4"
hardware/flash.sh --display-es3c28p --build-only
```

After connecting the board to the Mac, flash with:

```sh
hardware/flash.sh --display-es3c28p /dev/cu.usbmodemYOUR_PORT
```

Without `--display-es3c28p`, display support is disabled and no display library
is needed. Do not enable it for other boards without verifying their wiring.

Wiring from the [LCDWIKI board documentation](https://www.lcdwiki.com/2.8inch_ESP32-S3_Display_E32C28P/E32N28P):

| Signal | GPIO |
| --- | --- |
| CS | 10 |
| DC | 46 |
| SCLK | 12 |
| MOSI | 11 |
| MISO | 13 |
| Backlight (active high) | 45 |
| Reset | Shared with ESP32 reset; no software reset pin |

The screen uses a 20 MHz SPI bus and refreshes changed rows at most once per
second, in the Arduino loop task. It uses a 228x20 pixel row buffer (~9 KB), not
a full-screen framebuffer. The backlight is set to 20% PWM duty to limit added
power consumption; brightness and current are not necessarily linear with duty.
The active-low audio amplifier is disabled except during the offline power-on
greeting (see `audio/README.md`). GPIO19/20 (USB),
touch and SD pins are left alone.

The IPS panel is initialized with `lcd.invertDisplay(true)` (ILI9341 INVON).
With the generic library default, the observed panel displayed complementary
colors: the dark background became pale and amber became blue. This controller
mode corrects panel polarity; RGB565 palette values remain unchanged. Confirm
the colors on the physical screen after flashing.

Hardware acceptance after flashing:

1. The screen shows `天宝Phone` after reset, with readable, correctly oriented text.
2. USB changes to `ok` when connected to an active host; BLE changes when paired.
3. A board command updates the large footer action label, without exposing its arguments.
4. AirPlay streaming updates video fps, and existing HID actions still work.
5. Verify that enabling the backlight does not cause brownouts or repeated resets
   when powered by the iPhone.

The title is a fixed 180x28 monochrome bitmap (644 bytes) in `phone_title.h`.
Status text is ASCII English, so a full Chinese font library is unnecessary.
This is a status dashboard, not an iPhone video preview or touch UI.

The approved revised layout fills the gauge with contiguous integer scanline
spans, rather than sparse radial strokes. Dynamic text erase rectangles are
confined to the gauge's hole; Wi-Fi updates stop before the cards. BLE/video
values and free PSRAM use 2x font size. The footer shows the last action and
uptime, without command counts or reset diagnostics. Firmware protocol and BLE
status diagnostics remain unchanged.
