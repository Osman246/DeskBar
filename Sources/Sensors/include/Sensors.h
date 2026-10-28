#pragma once

/// Hottest CPU die sensor in °C, or a negative number if none could be read.
double sensors_cpu_temperature(void);

/// Fills `rpm` with the current speed of up to `max` fans; returns how many fans there are.
int sensors_fan_speeds(double *rpm, int max);

/// Number of external displays that accept DDC commands (brightness over the cable).
int ddc_display_count(void);
/// Reads DDC brightness (0–100) of external display `index`; returns -1 if it doesn't answer.
int ddc_get_brightness(int index);
/// Sets DDC brightness (0–100) of external display `index`; returns 0 on success.
int ddc_set_brightness(int index, int value);
