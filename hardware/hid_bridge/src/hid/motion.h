#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

// Orthogonal, constant-pace HID pointer motion.
// Moving X and Y in the same HID report couples the two axes through iOS AssistiveTouch's
// 2D pointer-acceleration curve and integer step quantization (causing the same vertical
// move to land ~3-5% higher or lower depending on horizontal travel). Stepping X first at
// a fixed per-report delta and then Y at the same fixed per-report delta makes each axis's
// report sequence invariant to the other axis and strictly prefix-consistent.
#define HID_MOTION_STEP 8

typedef struct {
  int32_t dx, dy, x, y;
  uint32_t count, index;
} hid_motion;

static inline uint32_t hid_axis_steps(int32_t d) {
  uint32_t u = d < 0 ? (uint32_t)(-(int64_t)d) : (uint32_t)d;
  return (u + HID_MOTION_STEP - 1u) / HID_MOTION_STEP;
}

static inline int hid_step_clamp(int64_t rem) {
  if (rem > HID_MOTION_STEP) return HID_MOTION_STEP;
  if (rem < -HID_MOTION_STEP) return -HID_MOTION_STEP;
  return (int)rem;
}

static inline hid_motion hid_motion_begin(int32_t dx, int32_t dy) {
  hid_motion p = {dx, dy, 0, 0, 0, 0};
  p.count = hid_axis_steps(dx) + hid_axis_steps(dy);
  return p;
}

static inline bool hid_motion_next(hid_motion *p, int *sx, int *sy) {
  if (p->index >= p->count) return false;
  p->index++;
  if (p->x != p->dx) {
    int step = hid_step_clamp((int64_t)p->dx - (int64_t)p->x);
    *sx = step;
    *sy = 0;
    p->x += step;
    return true;
  }
  int step = hid_step_clamp((int64_t)p->dy - (int64_t)p->y);
  *sx = 0;
  *sy = step;
  p->y += step;
  return true;
}
