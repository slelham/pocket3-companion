#include "ptz.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int usage(void) {
  fprintf(stderr,
          "usage:\n"
          "  pocket3-companion                 print pan, tilt, roll, zoom, and focus\n"
          "  pocket3-companion set PAN TILT    aim, degrees\n"
          "  pocket3-companion nudge DPAN DTILT\n"
          "  pocket3-companion zoom N          absolute zoom (100 wide … 400 full)\n"
          "  pocket3-companion zoom in|out     step by 25\n"
          "  pocket3-companion roll DEGREES    horizon, about -30 … 30\n"
          "  pocket3-companion focus N         manual focus, 0 … 4095\n"
          "  pocket3-companion focus auto|manual\n");
  return 2;
}

static int print_status(void) {
  ptz_sense_t s = {0};
  ptz_range_t range = {0};
  int zmin = 0, zmax = 0;
  double rmin = 0, rmax = 0;
  int fmin = 0, fmax = 0;
  if (ptz_sense(&s)) {
    fprintf(stderr, "Pocket 3 not available. Plug it in and choose Webcam on the camera.\n");
    return 1;
  }
  printf("pan %.1f\ntilt %.1f\nroll %.0f\nzoom %d\nfocus %d\nfocus_auto %d\n",
         s.pan, s.tilt, s.roll, s.zoom, s.focus, s.focusAuto);
  if (!ptz_range(&range))
    printf("pan_range %.0f %.0f\ntilt_range %.0f %.0f\n", range.panMin, range.panMax, range.tiltMin, range.tiltMax);
  if (!ptz_roll_range(&rmin, &rmax)) printf("roll_range %.0f %.0f\n", rmin, rmax);
  if (!ptz_zoom_range(&zmin, &zmax)) printf("zoom_range %d %d\n", zmin, zmax);
  if (!ptz_focus_range(&fmin, &fmax)) printf("focus_range %d %d\n", fmin, fmax);
  return 0;
}

// Roll and focus settle on their own clocks. One focus command is enough;
// repeating it can hold the lens the way a repeated zoom command does.
static int settle_roll(double roll) {
  if (ptz_roll_set(roll)) return -1;
  for (int i = 0; i < 30; i++) {
    usleep(50000);
    double now = 0;
    if (ptz_roll_get(&now)) return -1;
    double d = now - roll;
    if (d < 0) d = -d;
    if (d < 0.5) return 0;
  }
  return -1;
}

static int settle_focus(int focus) {
  if (ptz_focus_auto_set(0)) return -1;
  if (ptz_focus_set(focus)) return -1;
  usleep(400000);
  int now = 0;
  if (ptz_focus_get(&now)) return -1;
  int d = now - focus;
  if (d < 0) d = -d;
  if (d <= 8) return 0;
  if (ptz_focus_set(focus)) return -1;
  usleep(400000);
  if (ptz_focus_get(&now)) return -1;
  d = now - focus;
  if (d < 0) d = -d;
  return d <= 8 ? 0 : -1;
}

int main(int argc, char **argv) {
  if (argc == 1) return print_status();
  if (!strcmp(argv[1], "set") && argc == 4) {
    double pan = strtod(argv[2], NULL), tilt = strtod(argv[3], NULL);
    if (ptz_settle(&pan, &tilt, NULL, 4)) {
      fprintf(stderr, "gimbal did not reach the aim\n");
      print_status();
      return 1;
    }
    return print_status();
  }
  if (!strcmp(argv[1], "nudge") && argc == 4) {
    double pan = 0, tilt = 0;
    if (ptz_get(&pan, &tilt)) return 1;
    pan += strtod(argv[2], NULL);
    tilt += strtod(argv[3], NULL);
    if (ptz_settle(&pan, &tilt, NULL, 4)) {
      fprintf(stderr, "gimbal did not reach the aim\n");
      print_status();
      return 1;
    }
    return print_status();
  }
  if (!strcmp(argv[1], "zoom") && argc == 3) {
    int zoom = 0;
    if (!strcmp(argv[2], "in") || !strcmp(argv[2], "out")) {
      if (ptz_zoom_get(&zoom)) return 1;
      zoom += !strcmp(argv[2], "in") ? 25 : -25;
    } else {
      zoom = (int)strtol(argv[2], NULL, 10);
    }
    int zmin = 100, zmax = 400;
    ptz_zoom_range(&zmin, &zmax);
    if (zoom < zmin) zoom = zmin;
    if (zoom > zmax) zoom = zmax;
    if (ptz_settle(NULL, NULL, &zoom, 4)) {
      fprintf(stderr, "zoom did not arrive\n");
      print_status();
      return 1;
    }
    return print_status();
  }
  if (!strcmp(argv[1], "roll") && argc == 3) {
    if (settle_roll(strtod(argv[2], NULL))) {
      fprintf(stderr, "roll did not arrive\n");
      print_status();
      return 1;
    }
    return print_status();
  }
  if (!strcmp(argv[1], "focus") && argc == 3) {
    if (!strcmp(argv[2], "auto")) {
      if (ptz_focus_auto_set(1)) return 1;
      return print_status();
    }
    if (!strcmp(argv[2], "manual")) {
      if (ptz_focus_auto_set(0)) return 1;
      return print_status();
    }
    if (settle_focus((int)strtol(argv[2], NULL, 10))) {
      fprintf(stderr, "focus did not arrive\n");
      print_status();
      return 1;
    }
    return print_status();
  }
  return usage();
}
