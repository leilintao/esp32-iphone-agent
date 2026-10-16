# Power-on greeting

Text: 天宝竭诚为您服务

Voice: Microsoft Edge TTS zh-CN-XiaoxiaoNeural (female), rate -6%, pitch +8Hz.
Audio is generated once and embedded in firmware; playback is offline.

Enabled with `hardware/flash.sh --display-es3c28p`. Playback runs once per
firmware boot (including resets), with output enabled no earlier than 5000 ms
of Arduino uptime. It uses a separate FreeRTOS task; there is no five-second
delay in the HID/control loop. After playback the codec is muted, the active-low
amplifier is disabled, I2S/I2C resources are released, and the task exits.

ES3C28P wiring verified against the LCDWIKI schematic:

| Function | GPIO |
| --- | --- |
| ES8311 I2C SDA / SCL | 16 / 15 |
| ES8311 I2C address | 0x18 |
| I2S MCLK / BCLK / LRCLK | 4 / 5 / 7 |
| ESP32 TX -> codec DSDIN | 8 |
| Codec ASDOUT (unused; microphone not recorded) | 6 |
| Amplifier enable | 1, active low |

Note that the board's `I2S_DI` label means codec data input, not ESP32 input.
GPIO8 must be used for playback. It is easy to confuse it with GPIO6.

The audio source is `welcome.mp3`; `welcome.wav` is 16 kHz mono PCM with 0.65
gain and brief fades; `welcome.ulaw` is 40704 bytes of 16 kHz G.711 mu-law.
`hid_bridge/welcome_audio.h` embeds those bytes in Flash. The playback task
decodes short chunks into 16-bit stereo (duplicated mono) without a full RAM
audio buffer. Codec DAC register scale is 90%; the sound is also attenuated in
the source WAV. These are not calibrated sound-pressure levels.

Generation commands (requires network only when generating the source):

```sh
uvx --from edge-tts edge-tts --voice zh-CN-XiaoxiaoNeural --rate=-6% --pitch=+8Hz \
  --text '天宝竭诚为您服务' --write-media hardware/audio/welcome.mp3
ffmpeg -y -i hardware/audio/welcome.mp3 \
  -af 'volume=0.65,afade=t=in:d=0.025,afade=t=out:st=2.35:d=0.15' \
  -ar 16000 -ac 1 -c:a pcm_s16le hardware/audio/welcome.wav
ffmpeg -y -i hardware/audio/welcome.wav -ar 16000 -ac 1 \
  -c:a pcm_mulaw -f mulaw hardware/audio/welcome.ulaw
```

Send an existing `<id> audio` serial/BLE board command to query `pending`,
`waiting`, `playing`, `done` or an initialization/write error. This command
never starts another playback. `<id> audio twice` immediately replays two passes,
or extends a pending/current boot greeting to two passes. It does not change
the once-per-boot default. Requests during final cleanup return busy.
Serial logs include actual playback start, each pass, delivered pass count and
finish uptime. Hearing and voice preference still require a physical speaker
check; `done` verifies data delivery rather than acoustic output.

Register initialization reference:
[Espressif ES8311 driver](https://github.com/espressif/esp-bsp/blob/f259a6abd5808019b1903a422092a4234ca95a51/components/es8311/es8311.c).
Hardware reference:
[LCDWIKI schematic](https://www.lcdwiki.com/res/ES3C28P/2.8inch_ESP32-S3_Display_Schematic.pdf).
