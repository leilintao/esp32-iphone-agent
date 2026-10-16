#pragma once
#include <Arduino.h>

// Optional ES3C28P/ES3N28P local diagnostics. Call only from the Arduino loop task.
void display_begin();
void display_poll(const char *usb, const char *reset);
void display_command(const String &verb);
