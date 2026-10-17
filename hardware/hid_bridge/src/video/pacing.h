// Classify protocol commands without coupling host tests to Arduino/NimBLE.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// Input is "<request-id> <command> [args]". Routine heartbeats and debug relay
// still get priority when their replies are queued, but must not hold the
// controller's video credit cap on for another second after every message.
static inline bool video_interactive_command(const char *line) {
  const char *p = line;
  while (*p && *p != ' ' && *p != '\t') p++;
  while (*p == ' ' || *p == '\t') p++;
  const char *end = p;
  while (*end && *end != ' ' && *end != '\t' && *end != '\r' && *end != '\n') end++;
  size_t len = (size_t)(end - p);
  if (!len) return false;
  static const char *routine[] = {"ping", "log", "app", "status"};
  for (size_t i = 0; i < sizeof routine / sizeof routine[0]; i++)
    if (strlen(routine[i]) == len && !memcmp(p, routine[i], len)) return false;
  return true;
}
