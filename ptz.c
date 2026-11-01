#include "ptz.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VID 0x2ca3
#define PID 0x0023
#define CT_FOCUS_ABS 0x06
#define CT_FOCUS_AUTO 0x08
#define CT_ZOOM_ABS 0x0B
#define CT_PANTILT_ABS 0x0D
#define CT_ROLL_ABS 0x0F
#define WINDEX ((1 << 8) | 0) // camera terminal 1, VideoControl interface 0

#define GET_CUR 0x81
#define GET_MIN 0x82
#define GET_MAX 0x83
#define SET_CUR 0x01

static IOUSBDeviceInterface **open_device(void) {
  CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
  if (!match) return NULL;
  int vid = VID, pid = PID;
  CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
  CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
  CFDictionarySetValue(match, CFSTR("idVendor"), v);
  CFDictionarySetValue(match, CFSTR("idProduct"), p);
  CFRelease(v);
  CFRelease(p);

  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
  if (!svc) return NULL;

  IOCFPlugInInterface **plug = NULL;
  SInt32 score = 0;
  kern_return_t kr = IOCreatePlugInInterfaceForService(
      svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
  IOObjectRelease(svc);
  if (kr || !plug) return NULL;

  IOUSBDeviceInterface **dev = NULL;
  HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
  IODestroyPlugInInterface(plug);
  if (hr || !dev) return NULL;

  // The system UVC driver owns the interfaces. A device-level control
  // transfer still reaches the camera terminal, which is how pan/tilt/zoom
  // move while webcam mode stays up.
  if ((*dev)->USBDeviceOpen(dev) != kIOReturnSuccess) {
    (*dev)->Release(dev);
    return NULL;
  }
  return dev;
}

static void close_device(IOUSBDeviceInterface **dev) {
  (*dev)->USBDeviceClose(dev);
  (*dev)->Release(dev);
}

static int control(IOUSBDeviceInterface **dev, UInt8 type, UInt8 req, UInt16 sel, void *data, UInt16 len) {
  IOUSBDevRequest r = {
      .bmRequestType = type,
      .bRequest = req,
      .wValue = (UInt16)(sel << 8),
      .wIndex = WINDEX,
      .wLength = len,
      .pData = data,
  };
  IOReturn kr = (*dev)->DeviceRequest(dev, &r);
  if (kr || r.wLenDone < len) return -1;
  return 0;
}

static int with_device(int (*body)(IOUSBDeviceInterface **, void *), void *ctx) {
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  int rc = body(dev, ctx);
  close_device(dev);
  return rc;
}

static int get_pair_body(IOUSBDeviceInterface **dev, void *ctx) {
  UInt8 req = ((UInt8 *)ctx)[0];
  int32_t *v = (int32_t *)((UInt8 *)ctx + 8);
  return control(dev, 0xA1, req, CT_PANTILT_ABS, v, 8);
}

static int get_pair(UInt8 req, double *pan, double *tilt) {
  struct {
    UInt8 req;
    UInt8 pad[7];
    int32_t v[2];
  } ctx = {.req = req};
  int rc = with_device(get_pair_body, &ctx);
  if (rc) return rc;
  *pan = ctx.v[0] / 3600.0;
  *tilt = ctx.v[1] / 3600.0;
  return 0;
}

int ptz_get(double *pan, double *tilt) { return get_pair(GET_CUR, pan, tilt); }

int ptz_set(double pan, double tilt) {
  int32_t v[2] = {(int32_t)(pan * 3600.0), (int32_t)(tilt * 3600.0)};
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  int rc = control(dev, 0x21, SET_CUR, CT_PANTILT_ABS, v, 8);
  close_device(dev);
  return rc;
}

int ptz_range(ptz_range_t *out) {
  int rc = get_pair(GET_MIN, &out->panMin, &out->tiltMin);
  return rc ? rc : get_pair(GET_MAX, &out->panMax, &out->tiltMax);
}

static int zoom_req(UInt8 type, UInt8 req, uint16_t *zoom) {
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  int rc = control(dev, type, req, CT_ZOOM_ABS, zoom, 2);
  close_device(dev);
  return rc;
}

int ptz_zoom_get(int *zoom) {
  uint16_t z = 0;
  int rc = zoom_req(0xA1, GET_CUR, &z);
  if (!rc) *zoom = z;
  return rc;
}

int ptz_zoom_set(int zoom) {
  if (zoom < 0) zoom = 0;
  if (zoom > 65535) zoom = 65535;
  uint16_t z = (uint16_t)zoom;
  return zoom_req(0x21, SET_CUR, &z);
}

int ptz_zoom_range(int *min, int *max) {
  uint16_t lo = 0, hi = 0;
  if (zoom_req(0xA1, GET_MIN, &lo)) return -1;
  if (zoom_req(0xA1, GET_MAX, &hi)) return -1;
  *min = lo;
  *max = hi;
  return 0;
}

static int16_t deg_i16(double v) {
  if (v >= 0) v += 0.5;
  else v -= 0.5;
  if (v > 32767) v = 32767;
  if (v < -32768) v = -32768;
  return (int16_t)v;
}

static int fill_sense(IOUSBDeviceInterface **dev, ptz_sense_t *out) {
  int32_t v[2] = {0};
  uint16_t z = 0, focus = 0;
  int16_t roll = 0;
  uint8_t af = 0;
  if (control(dev, 0xA1, GET_CUR, CT_PANTILT_ABS, v, 8)) return -1;
  if (control(dev, 0xA1, GET_CUR, CT_ZOOM_ABS, &z, 2)) return -1;
  if (control(dev, 0xA1, GET_CUR, CT_ROLL_ABS, &roll, 2)) return -1;
  if (control(dev, 0xA1, GET_CUR, CT_FOCUS_ABS, &focus, 2)) return -1;
  if (control(dev, 0xA1, GET_CUR, CT_FOCUS_AUTO, &af, 1)) return -1;
  out->pan = v[0] / 3600.0;
  out->tilt = v[1] / 3600.0;
  out->roll = roll;
  out->zoom = z;
  out->focus = focus;
  out->focusAuto = af ? 1 : 0;
  return 0;
}

int ptz_read(double *pan, double *tilt, int *zoom) {
  ptz_sense_t s;
  if (ptz_sense(&s)) return -1;
  if (pan) *pan = s.pan;
  if (tilt) *tilt = s.tilt;
  if (zoom) *zoom = s.zoom;
  return 0;
}

int ptz_sense(ptz_sense_t *out) {
  if (!out) return -1;
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  int rc = fill_sense(dev, out);
  close_device(dev);
  return rc;
}

static int scalar_req(UInt8 type, UInt8 req, UInt8 sel, void *data, UInt16 len) {
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  int rc = control(dev, type, req, sel, data, len);
  close_device(dev);
  return rc;
}

int ptz_roll_get(double *roll) {
  int16_t v = 0;
  if (scalar_req(0xA1, GET_CUR, CT_ROLL_ABS, &v, 2)) return -1;
  if (roll) *roll = v;
  return 0;
}

int ptz_roll_set(double roll) {
  int16_t v = deg_i16(roll);
  return scalar_req(0x21, SET_CUR, CT_ROLL_ABS, &v, 2);
}

int ptz_roll_range(double *min, double *max) {
  int16_t lo = 0, hi = 0;
  if (scalar_req(0xA1, GET_MIN, CT_ROLL_ABS, &lo, 2)) return -1;
  if (scalar_req(0xA1, GET_MAX, CT_ROLL_ABS, &hi, 2)) return -1;
  if (min) *min = lo;
  if (max) *max = hi;
  return 0;
}

int ptz_focus_get(int *focus) {
  uint16_t v = 0;
  if (scalar_req(0xA1, GET_CUR, CT_FOCUS_ABS, &v, 2)) return -1;
  if (focus) *focus = v;
  return 0;
}

int ptz_focus_set(int focus) {
  if (focus < 0) focus = 0;
  if (focus > 65535) focus = 65535;
  uint16_t v = (uint16_t)focus;
  return scalar_req(0x21, SET_CUR, CT_FOCUS_ABS, &v, 2);
}

int ptz_focus_range(int *min, int *max) {
  uint16_t lo = 0, hi = 0;
  if (scalar_req(0xA1, GET_MIN, CT_FOCUS_ABS, &lo, 2)) return -1;
  if (scalar_req(0xA1, GET_MAX, CT_FOCUS_ABS, &hi, 2)) return -1;
  if (min) *min = lo;
  if (max) *max = hi;
  return 0;
}

int ptz_focus_auto_get(int *on) {
  uint8_t v = 0;
  if (scalar_req(0xA1, GET_CUR, CT_FOCUS_AUTO, &v, 1)) return -1;
  if (on) *on = v ? 1 : 0;
  return 0;
}

int ptz_focus_auto_set(int on) {
  uint8_t v = on ? 1 : 0;
  return scalar_req(0x21, SET_CUR, CT_FOCUS_AUTO, &v, 1);
}

struct ptz_link {
  IOUSBDeviceInterface **dev;
};

int ptz_link_open(void **out) {
  if (!out) return -1;
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  struct ptz_link *link = calloc(1, sizeof *link);
  if (!link) {
    close_device(dev);
    return -1;
  }
  link->dev = dev;
  *out = link;
  return 0;
}

void ptz_link_close(void *handle) {
  struct ptz_link *link = handle;
  if (!link) return;
  close_device(link->dev);
  free(link);
}

int ptz_link_sense(void *handle, ptz_sense_t *out) {
  struct ptz_link *link = handle;
  if (!link || !out) return -1;
  return fill_sense(link->dev, out);
}

int ptz_link_read(void *handle, double *pan, double *tilt, int *zoom) {
  ptz_sense_t s;
  if (ptz_link_sense(handle, &s)) return -1;
  if (pan) *pan = s.pan;
  if (tilt) *tilt = s.tilt;
  if (zoom) *zoom = s.zoom;
  return 0;
}

int ptz_link_aim(void *handle, double pan, double tilt) {
  struct ptz_link *link = handle;
  if (!link) return -1;
  int32_t v[2] = {(int32_t)(pan * 3600.0), (int32_t)(tilt * 3600.0)};
  return control(link->dev, 0x21, SET_CUR, CT_PANTILT_ABS, v, 8);
}

int ptz_link_zoom(void *handle, int zoom) {
  struct ptz_link *link = handle;
  if (!link) return -1;
  if (zoom < 0) zoom = 0;
  if (zoom > 65535) zoom = 65535;
  uint16_t z = (uint16_t)zoom;
  return control(link->dev, 0x21, SET_CUR, CT_ZOOM_ABS, &z, 2);
}

int ptz_link_roll(void *handle, double roll) {
  struct ptz_link *link = handle;
  if (!link) return -1;
  int16_t v = deg_i16(roll);
  return control(link->dev, 0x21, SET_CUR, CT_ROLL_ABS, &v, 2);
}

int ptz_link_focus(void *handle, int focus) {
  struct ptz_link *link = handle;
  if (!link) return -1;
  if (focus < 0) focus = 0;
  if (focus > 65535) focus = 65535;
  uint16_t v = (uint16_t)focus;
  return control(link->dev, 0x21, SET_CUR, CT_FOCUS_ABS, &v, 2);
}

int ptz_link_focus_auto(void *handle, int on) {
  struct ptz_link *link = handle;
  if (!link) return -1;
  uint8_t v = on ? 1 : 0;
  return control(link->dev, 0x21, SET_CUR, CT_FOCUS_AUTO, &v, 1);
}

static int close_enough(double pan, double tilt, int zoom, const double *wantPan, const double *wantTilt, const int *wantZoom) {
  if (wantPan && wantTilt) {
    double dp = pan - *wantPan;
    double dt = tilt - *wantTilt;
    if (dp < 0) dp = -dp;
    if (dt < 0) dt = -dt;
    if (dp >= 0.5 || dt >= 0.5) return 0;
  }
  if (wantZoom) {
    int dz = zoom - *wantZoom;
    if (dz < 0) dz = -dz;
    if (dz > 2) return 0;
  }
  return 1;
}

int ptz_settle(const double *pan, const double *tilt, const int *zoom, double seconds) {
  void *link = NULL;
  if (ptz_link_open(&link)) return -1;
  if (seconds < 0.2) seconds = 0.2;
  if (seconds > 6) seconds = 6;
  int ticks = (int)(seconds / 0.05);
  if (ticks < 4) ticks = 4;
  int aimStill = 0, zoomStill = 0, lastZoomSend = -100, zoomSent = 0, primed = 0, arrived = 0;
  double prevPan = 0, prevTilt = 0;
  int prevZoom = 0;
  for (int i = 0; i < ticks; i++) {
    double p = 0, t = 0;
    int z = 0;
    if (ptz_link_read(link, &p, &t, &z)) {
      ptz_link_close(link);
      return -1;
    }
    int aimPending = 0, zoomPending = 0;
    if (pan && tilt) {
      double dp = p - *pan, dt = t - *tilt;
      if (dp < 0) dp = -dp;
      if (dt < 0) dt = -dt;
      if (dp >= 0.5 || dt >= 0.5) {
        aimPending = 1;
        if (ptz_link_aim(link, *pan, *tilt)) {
          ptz_link_close(link);
          return -1;
        }
      }
    }
    if (zoom && z != *zoom) {
      zoomPending = 1;
      // Send once, then leave the lens alone through its ~400ms update.
      // A retry sooner than that holds zoom-out on the current stop.
      int far = z > *zoom + 2 || z < *zoom - 2;
      if (!zoomSent || (far && i - lastZoomSend >= 10)) {
        if (ptz_link_zoom(link, *zoom)) {
          ptz_link_close(link);
          return -1;
        }
        lastZoomSend = i;
        zoomSent = 1;
        zoomStill = 0;
      } else if (i - lastZoomSend >= 8 && !far) {
        zoomPending = 0;
      } else if (i - lastZoomSend >= 8) {
        int dz = z - prevZoom;
        if (dz < 0) dz = -dz;
        if (dz <= 1) zoomStill++;
        else zoomStill = 0;
        if (zoomStill >= 20) zoomPending = 0;
      }
    }
    if (!aimPending && !zoomPending) {
      arrived = 1;
      break;
    }
    if (aimPending && primed) {
      double dp = p - prevPan, dt = t - prevTilt;
      if (dp < 0) dp = -dp;
      if (dt < 0) dt = -dt;
      if (dp < 0.2 && dt < 0.2) aimStill++;
      else aimStill = 0;
      if (aimStill >= 16) aimPending = 0;
    }
    if (!aimPending && !zoomPending) {
      arrived = close_enough(p, t, z, pan, tilt, zoom);
      break;
    }
    prevPan = p;
    prevTilt = t;
    prevZoom = z;
    primed = 1;
    usleep(50000);
  }
  ptz_link_close(link);
  return arrived ? 0 : -1;
}
