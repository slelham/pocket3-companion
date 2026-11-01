#ifndef PTZ_H
#define PTZ_H

// UVC controls on a DJI Osmo Pocket 3 in webcam mode.
// Pan and tilt are degrees. UVC reports them in arcseconds.
// Roll is degrees on this body (about −30 to +30), not arcseconds.
// Zoom is the absolute zoom control (100 = wide, 400 = full on this body).
// Focus is 0 through 4095. Focus auto is 0 or 1.
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

int ptz_roll_get(double *roll);
int ptz_roll_set(double roll);
int ptz_roll_range(double *min, double *max);

int ptz_focus_get(int *focus);
int ptz_focus_set(int focus);
int ptz_focus_range(int *min, int *max);
int ptz_focus_auto_get(int *on);
int ptz_focus_auto_set(int on);

typedef struct {
  double pan, tilt, roll;
  int zoom, focus, focusAuto;
} ptz_sense_t;

// One USB open for the live position. Any pointer may be NULL.
int ptz_read(double *pan, double *tilt, int *zoom);
int ptz_sense(ptz_sense_t *out);

// One open held across a burst of reads and writes. The gimbal often
// stops short of a single absolute target, so callers repeat the target
// until the readback arrives.
int ptz_link_open(void **out);
void ptz_link_close(void *link);
int ptz_link_read(void *link, double *pan, double *tilt, int *zoom);
int ptz_link_sense(void *link, ptz_sense_t *out);
int ptz_link_aim(void *link, double pan, double tilt);
int ptz_link_zoom(void *link, int zoom);
int ptz_link_roll(void *link, double roll);
int ptz_link_focus(void *link, int focus);
int ptz_link_focus_auto(void *link, int on);

// Repeat the target until the camera is within half a degree and a couple of
// zoom units, until it stops moving, or until seconds elapse. A NULL pan
// skips aim. A NULL zoom skips zoom. Returns 0 if the camera got there.
int ptz_settle(const double *pan, const double *tilt, const int *zoom, double seconds);

#endif
