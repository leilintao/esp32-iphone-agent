// Mirrored H.264 from AirPlay to BLE, see video_link.h.
#include "video_link.h"
#include <esp_heap_caps.h>
#include <atomic>
#include "ble_link.h"
#include "src/video/gop.h"

// GOP since the latest IDR; overflow drops it until the next IDR. A still screen gets an IDR only every
// few minutes, so room for ~27 min of AUs at 5 fps (P-frames of a still screen are tiny).
const size_t GOP_CAP = 4 * 1024 * 1024;
const int MAX_AUS = 8192;
const size_t SCRATCH_CAP = 512 * 1024;   // largest access unit we forward
const size_t MAX_CHUNK = 512;

struct Req {
  char id[16];
  uint32_t kb;
  bool bench;
};

static gop_buf gop;
static SemaphoreHandle_t lock;
static uint8_t *scratch;
static QueueHandle_t reqs;
static TaskHandle_t task;
static volatile bool streaming;
static uint16_t seq;
static uint8_t chunk[VCHUNK_HDR + MAX_CHUNK];
static uint32_t winStart, winBytes, winFrames, lastIdr;
static volatile uint32_t statKbps, statIdrMs, statAt;
static volatile float statFps;
static uint32_t lastAccepted, oversized;
static uint32_t txGen = UINT32_MAX;
static int nextAu;
static vchunk pending;
static bool pendingAu;
// Which live AU the decoder has completely received. Guarded by `lock`: the mirror task
// compares it with the cache before restarting an overflowing GOP.
static bool hasSent;
static uint32_t sentGen = UINT32_MAX;
static int sentN = -1;
static int pendingIdx = -1;   // index of the AU being chunked (not config)
static uint32_t pendingGen;
static std::atomic<uint32_t> lastTxMs, txLeft;
static const uint32_t SNAP_BUDGET_MS = 20000;

static bool queueChunk(void *, const uint8_t *p, size_t n) { return ble_video_send(p, n); }

// One access unit as notifies. A failed queue attempt must not create a wire-level
// sequence hole: retry it within the snapshot's deadline instead of replaying the GOP.
static bool sendAu(const uint8_t *p, size_t n, uint8_t flags, uint32_t ts, uint32_t started) {
  size_t room = min(ble_video_room(), MAX_CHUNK);
  if (room < 5) return false;
  vchunk c;
  vchunk_begin(&c, p, n, flags, ts);
  const uint32_t epoch = ble_video_epoch();
  for (;;) {
    if (millis() - started >= SNAP_BUDGET_MS) return false;
    if (ble_video_epoch() != epoch || !ble_video_room()) return false;
    int result = vchunk_send(&c, chunk, min(ble_video_room(), MAX_CHUNK), &seq, queueChunk, nullptr);
    if (!result) return true;
    if (result < 0) vTaskDelay(1);
  }
}

// Copies AU i of generation gen into scratch; false if the GOP moved on.
static bool copyAu(uint32_t gen, int i, gop_au *au) {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = gop.gen == gen && i < gop.n && gop.aus[i].len <= SCRATCH_CAP;
  if (ok) {
    *au = gop.aus[i];
    memcpy(scratch, gop.arena + au->off, au->len);
  }
  xSemaphoreGive(lock);
  return ok;
}

// Snapshot of the GOP state: generation, AU count, SPS/PPS.
static bool snapshot(uint32_t *gen, int *n, uint8_t *cfg, size_t *cfg_len, uint32_t *cfg_ts) {
  xSemaphoreTake(lock, portMAX_DELAY);
  *gen = gop.gen;
  *n = gop.wait_idr ? 0 : gop.n;
  *cfg_len = gop.cfg_len;
  *cfg_ts = gop.cfg_ts;
  memcpy(cfg, gop.cfg, gop.cfg_len);
  xSemaphoreGive(lock);
  return *n > 0 && *cfg_len > 0;
}

struct StreamView {
  uint32_t gen, cfg_ts;
  size_t cfg_len;
  int n;
  bool wait_idr, live_continue;
};

// Unlike a snapshot, a live decoder may keep consuming a cache that lost its IDR,
// because gop_push only allows that when its reference chain stayed intact.
static bool streamView(StreamView *v, uint8_t *cfg) {
  xSemaphoreTake(lock, portMAX_DELAY);
  v->gen = gop.gen;
  v->n = gop.n;
  v->cfg_len = gop.cfg_len;
  v->cfg_ts = gop.cfg_ts;
  v->wait_idr = gop.wait_idr;
  v->live_continue = gop.live_continue;
  memcpy(cfg, gop.cfg, gop.cfg_len);
  xSemaphoreGive(lock);
  return v->n > 0 && v->cfg_len > 0 && (!v->wait_idr || v->live_continue);
}

static String doSnap() {
  static uint8_t cfg[GOP_CFG_MAX];
  if (!ble_video_room()) return "err video not subscribed";
  const uint32_t started = millis();
  for (int attempt = 0; attempt < 3; attempt++) {
    uint32_t gen, cfg_ts;
    size_t cfg_len;
    int n;
    if (!snapshot(&gen, &n, cfg, &cfg_len, &cfg_ts)) {
      VideoStats s = video_stats();
      return s.overflows && s.wait_idr
        ? "err video cache overflow; waiting keyframe (restart screen mirroring)"
        : "err no decodable video; waiting keyframe (start screen mirroring)";
    }
    if (!sendAu(cfg, cfg_len, VF_CONFIG | VF_SNAP, cfg_ts, started))
      return "err video transfer stalled or exceeded 20s (restart screen mirroring)";
    bool complete = true;
    uint32_t finalTs = 0;
    for (int i = 0; i < n && complete; i++) {
      gop_au au;
      complete = copyAu(gen, i, &au);
      if (complete && !sendAu(scratch, au.len, VF_SNAP | (au.idr ? VF_IDR : 0), au.ts, started))
        return "err video transfer stalled or exceeded 20s (restart screen mirroring)";
      if (complete) finalTs = au.ts;
    }
    if (complete) {
      // The snapshot just sent the decoder this generation through n: do not replay the same
      // entire GOP again when continuous delivery resumes.
      txGen = gen;
      nextAu = n;
      lastTxMs = finalTs;
      xSemaphoreTake(lock, portMAX_DELAY);
      hasSent = true;
      sentGen = gen;
      sentN = n - 1;
      xSemaphoreGive(lock);
      return "ok";
    }  // else a new IDR replaced the GOP mid-send: start over with it
    if (millis() - started >= SNAP_BUDGET_MS) return "err video transfer exceeded 20s";
  }
  return "err video changing too fast";
}

static String doBench(uint32_t kb) {
  size_t room = min(ble_video_room(), MAX_CHUNK);
  if (!room) return "err video not subscribed";
  uint32_t start = millis();
  memset(chunk + VCHUNK_HDR, 0xA5, room);
  for (size_t left = kb * 1024; left;) {
    size_t n = min(left, room);
    chunk[0] = (uint8_t)seq;
    chunk[1] = (uint8_t)(seq >> 8);
    chunk[2] = VF_BENCH;
    bool ok = ble_video_send(chunk, VCHUNK_HDR + n);
    seq++;
    if (!ok) return "err ble send failed";
    left -= n;
  }
  return "ok " + String(millis() - start);
}

// Continuous mode: send every AU once, catching up from the GOP's IDR when streaming starts (P-frames
// can't be skipped: each needs the one before, and the next IDR may be minutes away). Queue pressure
// retries the same chunk. Pausing doesn't invalidate a decoder that is still subscribed.
static void streamStep() {
  static uint8_t cfg[GOP_CFG_MAX];
  static uint32_t epoch = UINT32_MAX;
  if (epoch != ble_video_epoch()) {
    epoch = ble_video_epoch();
    txGen = UINT32_MAX;
    pendingAu = false;
    txLeft = 0;
    // A (re)subscribed decoder starts empty, so it can only begin at an IDR.
    xSemaphoreTake(lock, portMAX_DELAY);
    hasSent = false;
    sentGen = UINT32_MAX;
    sentN = -1;
    gop.live_continue = false;  // an unanchored tail can only serve the decoder that was already warm
    xSemaphoreGive(lock);
  }
  if (!ble_video_room()) {
    txGen = UINT32_MAX;  // resend config + whole GOP when streaming resumes
    pendingAu = false;
    txLeft = 0;
    return;
  }
  if (!streaming) return;  // resume at the same AU; a real reconnect changes the epoch above
  StreamView v;
  if (!streamView(&v, cfg)) {
    txGen = UINT32_MAX;
    pendingAu = false;
    txLeft = 0;
    return;
  }
  const uint32_t gen = v.gen;
  const int n = v.n;
  if (gen != txGen) {
    txGen = gen;
    nextAu = 0;
    pendingIdx = -1;
    if (v.wait_idr) {
      // The cache lost its IDR. Only a decoder that had consumed everything before the
      // restart may continue; a new or lagging one must wait for the next IDR.
      if (!v.live_continue || !hasSent) {
        pendingAu = false;
        txLeft = 0;
        return;
      }
      pendingAu = false;  // continue straight with AU 0, without repeating SPS/PPS
    } else {
      // scratch also holds config: unlike a loop-local cfg it survives across task iterations.
      memcpy(scratch, cfg, v.cfg_len);
      vchunk_begin(&pending, scratch, v.cfg_len, VF_CONFIG, v.cfg_ts);
      pendingAu = true;
    }
  }
  if (!pendingAu) {
    if (nextAu >= n) return;
    gop_au au;
    if (!copyAu(gen, nextAu, &au)) { txGen = UINT32_MAX; return; }
    pendingIdx = nextAu;
    pendingGen = gen;
    nextAu++;
    vchunk_begin(&pending, scratch, au.len, au.idr ? VF_IDR : 0, au.ts);
    pendingAu = true;
  }
  // Yield after four chunks, even mid-AU. Snapshot/control requests no longer wait for an
  // entire historical GOP (previously ~90s). Never interleave two AUs on the BLE channel.
  const size_t room = min(ble_video_room(), MAX_CHUNK);
  if (room < 5) return;
  for (int i = 0; i < 4; i++) {
    int result = vchunk_send(&pending, chunk, room, &seq, queueChunk, nullptr);
    if (!result) { pendingAu = false; break; }
    if (result < 0) break;  // keep this exact AU/chunk; don't replay minutes of history
    if (chunk[2] & VF_END) {
      if (!(pending.flags & VF_CONFIG)) {
        lastTxMs = pending.ts;
        // Only a completely delivered AU advances the decoder's reference point.
        xSemaphoreTake(lock, portMAX_DELAY);
        hasSent = true;
        sentGen = pendingGen;
        sentN = pendingIdx;
        xSemaphoreGive(lock);
      }
      pendingAu = false;
      break;
    }
  }
  txLeft = (uint32_t)max(0, n - nextAu) + (pendingAu && !(pending.flags & VF_CONFIG) ? 1 : 0);
}

static void videoTask(void *) {
  for (;;) {
    Req r;
    if (xQueueReceive(reqs, &r, 0) == pdTRUE) {
      // A snapshot starts with CONFIG/START and deliberately replaces an unfinished live AU.
      pendingAu = false;
      txLeft = 0;
      txGen = UINT32_MAX;
      if (!r.bench) {
        // A snapshot replaces live delivery; until it completes we cannot promise the
        // decoder a continuity for an unanchored GOP.
        xSemaphoreTake(lock, portMAX_DELAY);
        hasSent = false;
        sentGen = UINT32_MAX;
        sentN = -1;
        xSemaphoreGive(lock);
      }
      String reply = String(r.id) + " " + (r.bench ? doBench(r.kb) : doSnap());
#if AGENT_DEBUG_SERIAL
      Serial.println("video: " + reply);  // the reply only goes over BLE; mirror it for serial-driven tests
#endif
      ble_reply(reply);
    }
    streamStep();
    // Do not throttle backlog to four packets / 20ms; keep yielding to the scheduler.
    if (pendingAu || txLeft.load()) vTaskDelay(1);
    else ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));
  }
}

bool video_begin() {
  uint8_t *arena = (uint8_t *)heap_caps_malloc(GOP_CAP, MALLOC_CAP_SPIRAM);
  gop_au *aus = (gop_au *)heap_caps_malloc(MAX_AUS * sizeof(gop_au), MALLOC_CAP_SPIRAM);
  scratch = (uint8_t *)heap_caps_malloc(SCRATCH_CAP, MALLOC_CAP_SPIRAM);
  if (!arena || !aus || !scratch) return false;
  gop_init(&gop, arena, GOP_CAP, aus, MAX_AUS);
  lock = xSemaphoreCreateMutex();
  reqs = xQueueCreate(4, sizeof(Req));
  return xTaskCreatePinnedToCore(videoTask, "video", 6 * 1024, NULL, 2, &task, 1) == pdPASS;
}

void video_on_config(const uint8_t *sps_pps, size_t len) {
  xSemaphoreTake(lock, portMAX_DELAY);
  gop_set_config(&gop, sps_pps, len, millis());
  xSemaphoreGive(lock);
}

void video_on_au(const uint8_t *au, size_t len, bool idr) {
  uint32_t now = millis();
  winBytes += len;
  winFrames++;
  if (idr) {
    if (lastIdr) statIdrMs = now - lastIdr;
    lastIdr = now;
  }
  if (now - winStart >= 1000) {
    statKbps = winBytes * 8 / (now - winStart);
    statFps = winFrames * 1000.0f / (now - winStart);
    statAt = now;
    winBytes = winFrames = 0;
    winStart = now;
  }
  xSemaphoreTake(lock, portMAX_DELAY);
  // An AU larger than the transmitter scratch must not wedge delivery at this index forever.
  if (len > SCRATCH_CAP) {
    oversized++;
    gop.used = 0;
    gop.n = 0;
    gop.gen++;
    gop.wait_idr = true;
    gop.live_continue = false;
  } else {
    // Every buffered AU was already delivered: a restart at this AU keeps the decoder's
    // reference chain intact even though the cache loses its IDR anchor.
    bool live_synced = hasSent && sentGen == gop.gen && gop.n > 0 && sentN == gop.n - 1;
    if (gop_push(&gop, au, len, idr, now, live_synced) >= 0) lastAccepted = now;
  }
  xSemaphoreGive(lock);
  xTaskNotifyGive(task);
}

void video_stream(bool on) { streaming = on; }

static void request(const String &id, bool bench, uint32_t kb) {
  Req r = {{0}, kb, bench};
  strncpy(r.id, id.c_str(), sizeof r.id - 1);
  if (xQueueSend(reqs, &r, 0) != pdTRUE) ble_reply(id + " err busy");
}

void video_snap(const String &id) { request(id, false, 0); }
void video_bench(const String &id, uint32_t kb) { request(id, true, kb); }

VideoStats video_stats() {
  bool fresh = millis() - statAt < 3000;  // mirroring stopped: report zeros, not stale numbers
  xSemaphoreTake(lock, portMAX_DELAY);
  uint32_t gopBytes = gop.used;
  uint32_t overflow = gop.overflows, large = oversized;
  bool waiting = gop.wait_idr, live = gop.live_continue;
  uint32_t age = lastAccepted ? millis() - lastAccepted : UINT32_MAX;
  xSemaphoreGive(lock);
  const uint32_t sentAt = lastTxMs.load();
  return {fresh ? statKbps : 0, statIdrMs, gopBytes, (uint32_t)GOP_CAP,
          fresh && (!waiting || live) ? statFps : 0,
          overflow, age, large, waiting, live,
          sentAt ? millis() - sentAt : UINT32_MAX, txLeft.load()};
}
