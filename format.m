#import <AVFoundation/AVFoundation.h>
#import "ptz.h"

// Swift cannot catch the exception this camera raises while the frame
// duration is changed. That abort closed the whole menu-bar app.
// The caller must not wrap this in a session configuration batch.
// commitConfiguration puts the Pocket 3 back on portrait 1080.
int p3_apply_format(void *devicePtr, void *formatPtr, int fps) {
    if (devicePtr == NULL || formatPtr == NULL) return 1;
    AVCaptureDevice *device = (__bridge AVCaptureDevice *)devicePtr;
    AVCaptureDeviceFormat *format = (__bridge AVCaptureDeviceFormat *)formatPtr;
    BOOL locked = NO;
    @try {
        NSError *error = nil;
        if (![device lockForConfiguration:&error]) return 1;
        locked = YES;
        device.activeFormat = format;
        // Frame duration is not available on this Mac. Setting it aborts.
        (void)fps;
        [device unlockForConfiguration];
        locked = NO;
        return 0;
    } @catch (NSException *ignored) {
        if (locked) {
            @try {
                [device unlockForConfiguration];
            } @catch (NSException *alsoIgnored) {
            }
        }
        return 2;
    }
}

// Reading the duration does not raise. Setting it does, and aborts a Swift caller.
double p3_active_fps(void *devicePtr) {
    if (devicePtr == NULL) return 0;
    @try {
        AVCaptureDevice *device = (__bridge AVCaptureDevice *)devicePtr;
        CMTime dur = device.activeVideoMinFrameDuration;
        if (CMTIME_IS_INVALID(dur) || dur.value == 0) return 0;
        return (double)dur.timescale / (double)dur.value;
    } @catch (NSException *ignored) {
        return 0;
    }
}

int p3_session_start(void *sessionPtr) {
    if (sessionPtr == NULL) return 1;
    AVCaptureSession *session = (__bridge AVCaptureSession *)sessionPtr;
    @try {
        if (!session.isRunning) [session startRunning];
        return session.isRunning ? 0 : 1;
    } @catch (NSException *ignored) {
        return 2;
    }
}

int p3_session_stop(void *sessionPtr) {
    if (sessionPtr == NULL) return 1;
    AVCaptureSession *session = (__bridge AVCaptureSession *)sessionPtr;
    @try {
        if (session.isRunning) [session stopRunning];
        return 0;
    } @catch (NSException *ignored) {
        return 2;
    }
}
