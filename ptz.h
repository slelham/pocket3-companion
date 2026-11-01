#ifndef PTZ_H
#define PTZ_H

// UVC pan/tilt/zoom on a DJI Osmo Pocket 3 in webcam mode.
// Pan and tilt are degrees. UVC reports them in arcseconds.
// Zoom is the camera's absolute zoom control (100 = wide, 400 = full on this body).
// Every function returns 0 on success.

typedef struct {
  double panMin, panMax, tiltMin, tiltMax;
} ptz_range_t;

int ptz_get(double *pan, double *tilt);
int ptz_set(double pan, double tilt);
int ptz_range(ptz_range_t *out);

int ptz_zoom_get(int *zoom);
int ptz_zoom_set(int zoom);
int ptz_zoom_range(int *min, int *max);

// One USB open for the live position. Any pointer may be NULL.
int ptz_read(double *pan, double *tilt, int *zoom);

// One open held across a burst of reads and writes. The gimbal often
// stops short of a single absolute target, so callers repeat the target
// until the readback arrives.
int ptz_link_open(void **out);
void ptz_link_close(void *link);
int ptz_link_read(void *link, double *pan, double *tilt, int *zoom);
int ptz_link_aim(void *link, double pan, double tilt);
int ptz_link_zoom(void *link, int zoom);

// Repeat the target until the camera is within about 1° and 3 zoom units,
// until it stops moving, or until seconds elapse. A NULL pan skips aim.
// A NULL zoom skips zoom. Returns 0 if the camera got there.
int ptz_settle(const double *pan, const double *tilt, const int *zoom, double seconds);

#endif
