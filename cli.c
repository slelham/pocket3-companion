#include "ptz.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int usage(void) {
  fprintf(stderr,
          "usage:\n"
          "  pocket3-ptz                 print pan, tilt, and zoom\n"
          "  pocket3-ptz set PAN TILT    aim, degrees\n"
          "  pocket3-ptz nudge DPAN DTILT\n"
          "  pocket3-ptz zoom N          absolute zoom (100 wide … 400 full)\n"
          "  pocket3-ptz zoom in|out     step by 25\n");
  return 2;
}

static int print_status(void) {
  double pan = 0, tilt = 0;
  int zoom = 0;
  ptz_range_t range = {0};
  int zmin = 0, zmax = 0;
  if (ptz_read(&pan, &tilt, &zoom)) {
    fprintf(stderr, "Pocket 3 not available. Plug it in and choose Webcam on the camera.\n");
    return 1;
  }
  printf("pan %.1f\ntilt %.1f\nzoom %d\n", pan, tilt, zoom);
  if (!ptz_range(&range))
    printf("pan_range %.0f %.0f\ntilt_range %.0f %.0f\n", range.panMin, range.panMax, range.tiltMin, range.tiltMax);
  if (!ptz_zoom_range(&zmin, &zmax)) printf("zoom_range %d %d\n", zmin, zmax);
  return 0;
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
  return usage();
}
