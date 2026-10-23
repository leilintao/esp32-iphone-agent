// Host unit tests for the board's pure-C parts: bplist codec and the GOP buffer / video chunker.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../hid_bridge/src/bplist/bplist.h"
#include "../hid_bridge/src/video/gop.h"
#include "../hid_bridge/src/video/pacing.h"
#include "../hid_bridge/src/hid/motion.h"

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); } } while (0)

static void check_motion(int32_t dx, int32_t dy) {
  hid_motion plan = hid_motion_begin(dx, dy);
  int sx, sy;
  int64_t x = 0, y = 0;
  unsigned n = 0;
  bool seen_y = false;
  while (hid_motion_next(&plan, &sx, &sy)) {
    CHECK(abs(sx) <= HID_MOTION_STEP && abs(sy) <= HID_MOTION_STEP);
    CHECK(sx || sy);
    CHECK(!(sx && sy));  // strictly orthogonal: never mix X and Y in one HID report
    if (sx != 0) {
      CHECK(!seen_y);
      CHECK(dx >= 0 ? sx > 0 : sx < 0);
      if (x + sx != dx) CHECK(abs(sx) == HID_MOTION_STEP);
    } else {
      seen_y = true;
      CHECK(dy >= 0 ? sy > 0 : sy < 0);
      if (y + sy != dy) CHECK(abs(sy) == HID_MOTION_STEP);
    }
    x += sx; y += sy; n++;
  }
  CHECK(x == dx && y == dy && n == plan.count);
  CHECK(!hid_motion_next(&plan, &sx, &sy));
}

static void check_axis_invariance(int32_t dx1, int32_t dx2, int32_t dy) {
  hid_motion p1 = hid_motion_begin(dx1, dy);
  hid_motion p2 = hid_motion_begin(dx2, dy);
  int sx, sy;
  int y_steps1[512], y_steps2[512];
  unsigned n1 = 0, n2 = 0;
  while (hid_motion_next(&p1, &sx, &sy)) if (sy != 0 && n1 < 512) y_steps1[n1++] = sy;
  while (hid_motion_next(&p2, &sx, &sy)) if (sy != 0 && n2 < 512) y_steps2[n2++] = sy;
  CHECK(n1 == n2);
  for (unsigned i = 0; i < n1; i++) CHECK(y_steps1[i] == y_steps2[i]);
}

static void test_motion(void) {
  const int32_t moves[][2] = {{0, 0}, {1, 0}, {0, -1}, {150, 150}, {350, 350},
    {106, 254}, {358, 254}, {106, 803}, {358, 803}, {50, 999},
    {-50, 999}, {50, -999}, {-50, -999}, {1200, 0}, {0, 1200},
    {82, 1257}, {158, 1202}, {542, 1202}};
  for (unsigned i = 0; i < sizeof(moves) / sizeof(moves[0]); i++) check_motion(moves[i][0], moves[i][1]);
  for (int x = -70; x <= 70; x += 7)
    for (int y = -100; y <= 100; y += 10) check_motion(x, y);
  check_axis_invariance(106, 358, 254);
  check_axis_invariance(106, 358, 803);
  check_axis_invariance(158, 542, 1202);
  check_axis_invariance(82, 542, 1257);
  // Input limits: check first steps without iterating hundreds of millions of reports.
  hid_motion large = hid_motion_begin(INT32_MIN, INT32_MAX);
  int sx, sy;
  CHECK(hid_motion_next(&large, &sx, &sy) && sx == -HID_MOTION_STEP && sy == 0);
}

static void test_bplist_roundtrip(void) {
  bp_writer w;
  bp_writer_init(&w);
  int root = bp_w_dict(&w);
  bp_w_set(&w, root, "features", bp_w_uint(&w, 0x5A7FFEE6ull));
  bp_w_set(&w, root, "big", bp_w_uint(&w, 0x123456789ull));
  bp_w_set(&w, root, "name", bp_w_string(&w, "ESP32 Agent with a long name"));
  bp_w_set(&w, root, "ok", bp_w_bool(&w, true));
  bp_w_set(&w, root, "rate", bp_w_real(&w, 1.0 / 60));
  uint8_t pk[32];
  for (int i = 0; i < 32; i++) pk[i] = (uint8_t)i;
  bp_w_set(&w, root, "pk", bp_w_data(&w, pk, 32));
  int arr = bp_w_array(&w);
  bp_w_set(&w, root, "displays", arr);
  int d0 = bp_w_dict(&w);
  bp_w_append(&w, arr, d0);
  bp_w_set(&w, d0, "width", bp_w_uint(&w, 480));
  size_t len = 0;
  uint8_t *buf = bp_w_finish(&w, &len);
  bp_writer_free(&w);
  CHECK(buf != NULL);

  bp_reader r;
  int top = bp_open(&r, buf, len);
  CHECK(top >= 0 && bp_type(&r, top) == BP_DICT && bp_count(&r, top) == 7);
  uint64_t u = 0;
  CHECK(bp_get_uint(&r, bp_dict_get(&r, top, "features"), &u) && u == 0x5A7FFEE6ull);
  CHECK(bp_get_uint(&r, bp_dict_get(&r, top, "big"), &u) && u == 0x123456789ull);
  char s[64];
  CHECK(bp_get_string(&r, bp_dict_get(&r, top, "name"), s, sizeof s) && !strcmp(s, "ESP32 Agent with a long name"));
  bool b = false;
  CHECK(bp_get_bool(&r, bp_dict_get(&r, top, "ok"), &b) && b);
  double d = 0;
  CHECK(bp_get_real(&r, bp_dict_get(&r, top, "rate"), &d) && d == 1.0 / 60);
  const uint8_t *p;
  size_t n;
  CHECK(bp_get_data(&r, bp_dict_get(&r, top, "pk"), &p, &n) && n == 32 && !memcmp(p, pk, 32));
  int a = bp_dict_get(&r, top, "displays");
  CHECK(bp_type(&r, a) == BP_ARRAY && bp_count(&r, a) == 1);
  CHECK(bp_get_uint(&r, bp_dict_get(&r, bp_array_get(&r, a, 0), "width"), &u) && u == 480);
  CHECK(bp_dict_get(&r, top, "missing") < 0);
  CHECK(bp_array_get(&r, a, 5) < 0);

  // truncation and garbage never crash
  for (size_t cut = 0; cut < len; cut++) {
    bp_reader t;
    int tt = bp_open(&t, buf, cut);
    if (tt >= 0) bp_dict_get(&t, tt, "pk");
  }
  uint8_t junk[200];
  memcpy(junk, buf, len < 200 ? len : 200);
  for (int i = 8; i < 200 && (size_t)i < len - 32; i += 3) junk[i] ^= 0xA5;
  bp_reader t;
  int tt = bp_open(&t, junk, len < 200 ? len : 200);
  if (tt >= 0) { bp_dict_get(&t, tt, "pk"); bp_count(&t, tt); }
  free(buf);
}

// Hand-made plist as Apple writes it: UTF-16 string value and 1-byte refs.
static void test_bplist_utf16(void) {
  static const uint8_t pl[] = {
    'b','p','l','i','s','t','0','0',
    0xD1, 0x01, 0x02,                // dict {1: 2}         @8
    0x54, 'n','a','m','e',           // "name"              @11
    0x63, 0x00,'H', 0x20,0x19, 0x00,'s',  // u"H’s"        @16
    8, 11, 16,                       // offsets            @23
    0,0,0,0,0,0, 1, 1,
    0,0,0,0,0,0,0,3, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,23};
  bp_reader r;
  int top = bp_open(&r, pl, sizeof pl);
  char s[32];
  CHECK(top == 0);
  CHECK(bp_get_string(&r, bp_dict_get(&r, top, "name"), s, sizeof s) && !strcmp(s, "H\xE2\x80\x99s"));
}

static void test_gop(void) {
  static uint8_t arena[100];
  static gop_au aus[4];
  gop_buf g;
  gop_init(&g, arena, sizeof arena, aus, 4);
  uint8_t au[40] = {0, 0, 0, 1, 0x41};
  CHECK(gop_push(&g, au, 10, false, 1, false) == -1);  // waits for the first IDR
  CHECK(gop_push(&g, au, 30, true, 2, false) == 0);
  CHECK(gop_push(&g, au, 30, false, 3, false) == 1);
  CHECK(gop_push(&g, au, 30, false, 4, true) == 2 && g.used == 90);
  // Not every buffered AU reached the decoder: drop the GOP and wait for an IDR.
  CHECK(gop_push(&g, au, 30, false, 5, false) == -1 && g.n == 0 && g.wait_idr && !g.live_continue);
  CHECK(g.overflows == 1);
  CHECK(gop_push(&g, au, 10, false, 6, true) == -1);  // no anchor, no live chain
  CHECK(gop_push(&g, au, 30, true, 7, false) == 0 && !g.wait_idr && !g.live_continue);

  // Everything was delivered: an overflow may restart at this AU and keep the live
  // decoder going even though the cache has no IDR.
  gop_init(&g, arena, sizeof arena, aus, 4);
  CHECK(gop_push(&g, au, 30, true, 10, false) == 0);
  CHECK(gop_push(&g, au, 30, false, 11, true) == 1);
  CHECK(gop_push(&g, au, 30, false, 12, true) == 2 && g.used == 90);
  CHECK(gop_push(&g, au, 30, false, 13, true) == 0 && g.n == 1 && g.used == 30);
  CHECK(g.wait_idr && g.live_continue && g.overflows == 1);
  CHECK(gop_push(&g, au, 30, false, 14, false) == 1 && g.n == 2 && g.live_continue);
  CHECK(gop_push(&g, au, 30, false, 15, false) == 2 && g.n == 3);
  // The decoder lagged: this restart cannot be continued, so stop until a real IDR.
  CHECK(gop_push(&g, au, 30, false, 16, false) == -1 && g.n == 0 && g.wait_idr && !g.live_continue);
  CHECK(g.overflows == 2);
  CHECK(gop_push(&g, au, 30, false, 17, true) == -1);
  CHECK(gop_push(&g, au, 30, true, 18, false) == 0 && !g.wait_idr);
  // An AU larger than the whole cache is unusable even with a live decoder.
  CHECK(gop_push(&g, au, 120, false, 19, true) == -1 && g.n == 0 && g.wait_idr && !g.live_continue);
  CHECK(g.overflows == 3);

  uint8_t idr[] = {0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x65, 9};
  CHECK(annexb_has_idr(idr, sizeof idr));
  CHECK(!annexb_has_idr(idr, 6));

  uint8_t avcc[] = {0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41};
  uint8_t want[] = {0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41};
  CHECK(avcc_to_annexb(avcc, sizeof avcc) && !memcmp(avcc, want, sizeof want));
  uint8_t bad[] = {0, 0, 0, 9, 0x65};
  CHECK(!avcc_to_annexb(bad, sizeof bad));
}

static void test_chunker(void) {
  uint8_t data[100], out[64], got[100];
  for (int i = 0; i < 100; i++) data[i] = (uint8_t)i;
  vchunk c;
  vchunk_begin(&c, data, sizeof data, VF_IDR | VF_SNAP, 0xAABBCCDD);
  size_t n, got_len = 0;
  int chunks = 0;
  uint16_t seq = 65534;
  while ((n = vchunk_next(&c, out, 20, seq)) > 0) {
    CHECK(n <= VCHUNK_HDR + 20);
    CHECK(out[0] == (uint8_t)seq && out[1] == (uint8_t)(seq >> 8));
    CHECK(out[2] & VF_IDR && out[2] & VF_SNAP);
    size_t off = VCHUNK_HDR;
    if (chunks == 0) {
      CHECK(out[2] & VF_START);
      CHECK(out[3] == 0xDD && out[6] == 0xAA);
      off += 4;
    } else {
      CHECK(!(out[2] & VF_START));
    }
    memcpy(got + got_len, out + off, n - off);
    got_len += n - off;
    chunks++;
    seq++;
    if (got_len < 100) CHECK(!(out[2] & VF_END));
  }
  CHECK(out[2] & VF_END);
  CHECK(got_len == 100 && !memcmp(got, data, 100));
  CHECK(chunks == 6);  // 16 + 5 * 20 >= 100
  CHECK(seq == 4);     // wrapped

  vchunk_begin(&c, data, 3, VF_CONFIG, 1);  // tiny AU: one chunk is START and END
  n = vchunk_next(&c, out, 20, 0);
  CHECK(n == VCHUNK_HDR + 4 + 3 && (out[2] & (VF_START | VF_END | VF_CONFIG)) == (VF_START | VF_END | VF_CONFIG));
  CHECK(vchunk_next(&c, out, 20, 1) == 0);

  // Live delivery pauses after four chunks so a queued snapshot can run. Resuming the
  // persistent cursor must not repeat START or lose payload bytes across task iterations.
  vchunk_begin(&c, data, sizeof data, VF_IDR, 99);
  got_len = 0;
  seq = 100;
  int turns = 0;
  while (got_len < sizeof data) {
    turns++;
    for (int i = 0; i < 4 && (n = vchunk_next(&c, out, 10, seq)) > 0; i++, seq++) {
      bool first = (out[2] & VF_START) != 0;
      CHECK(first == (got_len == 0));
      size_t off = VCHUNK_HDR + (first ? 4 : 0);
      memcpy(got + got_len, out + off, n - off);
      got_len += n - off;
    }
  }
  CHECK(turns == 3);
  CHECK(got_len == sizeof data && !memcmp(got, data, sizeof data));
}

struct retry_test { unsigned attempts, sent; uint8_t expected[128]; size_t len; bool retrying; };
static bool retry_sender(void *ctx, const uint8_t *packet, size_t len) {
  struct retry_test *t = ctx;
  t->attempts++;
  if (!t->retrying && (packet[0] == 254 || packet[0] == 0 || (packet[2] & VF_END))) {
    memcpy(t->expected, packet, len); t->len = len; t->retrying = true;
    return false; // first, middle, and final chunk each stall once
  }
  if (t->retrying) {
    CHECK(t->len == len && !memcmp(t->expected, packet, len));
    t->retrying = false;
  }
  t->sent++;
  return true;
}

static void test_chunk_retry(void) {
  uint8_t data[100] = {0}, packet[128];
  vchunk c;
  vchunk_begin(&c, data, sizeof data, VF_IDR, 1234);
  uint16_t seq = 65534;
  struct retry_test t = {0};
  for (int result; (result = vchunk_send(&c, packet, 20, &seq, retry_sender, &t)) != 0;) {
    CHECK(t.attempts <= 12);
    if (t.attempts > 12) break;
    if (result < 0) CHECK(seq == (uint16_t)(65534 + t.sent));
  }
  CHECK(t.sent == 6 && t.attempts == 9);
  CHECK(seq == 4 && c.pos == sizeof data);
}

int main(void) {
  test_motion();
  test_chunk_retry();
  CHECK(!video_interactive_command("123 ping"));
  CHECK(!video_interactive_command("123 log start: waiting for video"));
  CHECK(!video_interactive_command("123 app status"));
  CHECK(!video_interactive_command("123 status"));
  CHECK(!video_interactive_command("123\t ping\r\n"));
  CHECK(!video_interactive_command("123"));
  CHECK(video_interactive_command("123 move 1 0"));
  CHECK(video_interactive_command("123 click"));
  CHECK(video_interactive_command("123 key cmd+h"));
  CHECK(video_interactive_command("123 release"));
  CHECK(video_interactive_command("123 pingextra"));
  test_bplist_roundtrip();
  test_bplist_utf16();
  test_gop();
  test_chunker();
  printf(fails ? "%d FAILED\n" : "all tests passed\n", fails);
  return fails != 0;
}
