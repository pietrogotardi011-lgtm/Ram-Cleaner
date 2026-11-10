// PhotoFace Enroll - a tiny real app so the camera daemon sees a genuine foreground client.
// SpringBoard launches it (see Tweak.x, PFSetup begin:), it captures the face, writes db.bin and
// status.txt into /var/mobile/Library/PhotoFace and posts com.photoface.enrolldone.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <float.h>
#import <math.h>
#import <sys/stat.h>
#import <objc/message.h>
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *const kDir = @"/var/mobile/Library/PhotoFace";
static CFStringRef const kPrefDom = CFSTR("com.photoface.tweak");
#define kNeedCenter 6   // straight-ahead samples per scan
#define kNeedPer 2      // samples per head direction (8 directions) per scan
#define kScans 2        // Face ID style: two passes around the circle
#define kScanSeconds 55 // time limit for one pass (the whole flow must stay under the tweak's 200 s watchdog)
#define kShowLivePreview 1   // 1 = live camera view inside the circle (like Face ID, nothing is ever saved as an image); 0 = dark circle + ring only
#define kTicks 72

#pragma mark - helpers

static NSString *PFDBPath(void) { return [kDir stringByAppendingPathComponent:@"db.bin"]; }
static NSString *PFModePath(void) { return [kDir stringByAppendingPathComponent:@"mode.txt"]; }

static void PFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PFLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *p = [kDir stringByAppendingPathComponent:@"log.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ [app] %@\n", [NSDate date], s];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(p.fileSystemRepresentation, 0600); return; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}
static id PFPrefGet(NSString *k) {
    CFPreferencesAppSynchronize(kPrefDom);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k, kPrefDom));
}
static void PFWriteStatus(NSString *s) {
    NSString *p = [kDir stringByAppendingPathComponent:@"status.txt"];
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(p.fileSystemRepresentation, 0644);
}
static UIColor *PFGreen(void) { return [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1]; }
static UIColor *PFTrack(void) { return [UIColor colorWithWhite:1 alpha:0.22]; }   // ring track
static UIColor *PFBlue(void) { return [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1]; }

static NSDictionary *PFLoadDB(void) {
    NSData *d = [NSData dataWithContentsOfFile:PFDBPath()];
    if (!d) return nil;
    NSSet *cls = [NSSet setWithObjects:NSDictionary.class, NSArray.class, NSNumber.class, NSString.class,
                  NSData.class, NSNull.class, VNFeaturePrintObservation.class, nil];
    NSError *err = nil;
    NSDictionary *r = [NSKeyedUnarchiver unarchivedObjectOfClasses:cls fromData:d error:&err];
    if (!r) {
        PFLog(@"PFLoadDB secure unarchive failed: %@ - trying non-secure fallback", err);
        @try {
            NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:d error:nil];
            u.requiresSecureCoding = NO;
            r = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
            [u finishDecoding];
        } @catch (NSException *e) { r = nil; }
    }
    if (![r isKindOfClass:NSDictionary.class] || ![r[@"prints"] count]) return nil;
    return r;
}
static float PFLimit(NSDictionary *db) {
    float base = db[@"base"] ? [db[@"base"] floatValue] : [db[@"th"] floatValue] / 1.25f;
    id tv = PFPrefGet(@"tolerance");
    float tol = tv ? [tv floatValue] : 1.25f;
    if (tol < 0.5f || tol > 2.0f) tol = 1.25f;
    return base * tol;
}


#pragma mark - crash recorder (writes into log.txt so the next run can show what killed the app)

static void PFCrashSignal(int sig) {
    int fd = open("/var/mobile/Library/PhotoFace/log.txt", O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd >= 0) {
        char head[64]; int n = snprintf(head, sizeof head, "[app] CRASH signal %d\n", sig);
        write(fd, head, n);
        void *bt[24]; int c = backtrace(bt, 24);
        backtrace_symbols_fd(bt, c, fd);
        close(fd);
    }
    signal(sig, SIG_DFL); raise(sig);
}
static void PFCrashException(NSException *e) {
    PFLog(@"CRASH exception %@: %@\n%@", e.name, e.reason, [[e callStackSymbols] componentsJoinedByString:@"\n"]);
}
static void PFInstallCrashRecorder(void) {
    NSSetUncaughtExceptionHandler(&PFCrashException);
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++) signal(sigs[i], PFCrashSignal);
}

#pragma mark - scanner (enroll = 2, test = 3)

@interface PFScan : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (atomic) int mode;
@property (nonatomic, readonly) AVCaptureSession *session;
@property (nonatomic, copy) void (^progress)(NSDictionary *info);
- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done;
- (void)nextScan;   // enroll: begin the second pass
- (void)cancel;
@end

@implementation PFScan {
    AVCaptureSession *_s; dispatch_queue_t _q, _cfg; NSTimer *_wd;
    NSTimeInterval _startTS, _deadlineTS, _lastFrameTS, _lastProc, _lastGain, _scanStart, _lastCap, _lastDbg;
    int _frames, _retries;
    NSMutableArray *_got; NSMutableArray<NSNumber *> *_bins, *_scanOf;
    NSDictionary *_db; void (^_done)(BOOL, NSString *);
    NSString *_interrupt; NSMutableArray *_obs;
    // enroll engine (touched only on _q)
    int _scanIdx, _phase, _center, _secCount[8], _lastSec, _cN;   // _phase: 0 find face, 1 circle, 2 paused between passes, 3 finishing
    float _biasX, _biasY, _cSumX, _cSumY; BOOL _lmBroken, _rectErrLogged;
}
@synthesize session = _s;

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q = dispatch_queue_create("photoface.app.cam", DISPATCH_QUEUE_SERIAL);
    _cfg = dispatch_queue_create("photoface.app.cfg", DISPATCH_QUEUE_SERIAL);
    _obs = [NSMutableArray new];
    return self;
}

- (void)teardown {
    for (id t in _obs) [[NSNotificationCenter defaultCenter] removeObserver:t];
    [_obs removeAllObjects];
    AVCaptureSession *old = _s; _s = nil;
    if (old) dispatch_async(_cfg, ^{
        for (AVCaptureOutput *o in old.outputs) { if ([o isKindOfClass:[AVCaptureVideoDataOutput class]]) [(AVCaptureVideoDataOutput *)o setSampleBufferDelegate:nil queue:nil]; }
        [old stopRunning];
    });
}

- (NSString *)build {
    [self teardown];
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                            mediaType:AVMediaTypeVideo
                                                             position:AVCaptureDevicePositionFront];
    if (!d) return @"no front camera found";
    NSError *e = nil;
    AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:d error:&e];
    if (!in) return [NSString stringWithFormat:@"can't open the camera (%@)", e.localizedDescription ?: @"unknown"];
    AVCaptureSession *s = [AVCaptureSession new];
    if (@available(iOS 10.0, *)) s.automaticallyConfiguresCaptureDeviceForWideColor = NO;
    [s beginConfiguration];
    if ([s canSetSessionPreset:AVCaptureSessionPreset640x480]) s.sessionPreset = AVCaptureSessionPreset640x480;
    if (![s canAddInput:in]) { [s commitConfiguration]; return @"can't add camera input"; }
    [s addInput:in];
    AVCaptureVideoDataOutput *o = [AVCaptureVideoDataOutput new];
    o.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    o.alwaysDiscardsLateVideoFrames = YES;
    [o setSampleBufferDelegate:self queue:_q];
    if (![s canAddOutput:o]) { [s commitConfiguration]; return @"can't add camera output"; }
    [s addOutput:o];
    AVCaptureConnection *c = [o connectionWithMediaType:AVMediaTypeVideo];
    if (c.isVideoOrientationSupported) c.videoOrientation = AVCaptureVideoOrientationPortrait;
    [s commitConfiguration];
    _s = s;
    __weak PFScan *ws = self;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionRuntimeErrorNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        NSError *er = n.userInfo[AVCaptureSessionErrorKey];
        PFScan *st = ws; if (!st) return;
        st->_interrupt = er.localizedDescription ?: @"camera runtime error";
        PFLog(@"runtime error: %@", er);
    }]];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionWasInterruptedNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        long r = [n.userInfo[AVCaptureSessionInterruptionReasonKey] longValue];
        PFScan *st = ws; if (!st) return;
        st->_interrupt = [NSString stringWithFormat:@"camera interrupted (reason %ld)", r];
        PFLog(@"interrupted reason=%ld appState=%ld", r, (long)[UIApplication sharedApplication].applicationState);
    }]];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionInterruptionEndedNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        PFScan *st = ws; if (st) st->_interrupt = nil;
        PFLog(@"interruption ended");
    }]];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionDidStartRunningNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        PFLog(@"session did start running");
    }]];
    return nil;
}

- (void)resetScanState {   // per-pass counters (the collected prints are kept)
    _center = 0; memset(_secCount, 0, sizeof _secCount);
    _biasX = _biasY = _cSumX = _cSumY = 0; _cN = 0; _lastSec = -1; _lastCap = 0;
    _phase = 0; _scanStart = CACurrentMediaTime(); _lastGain = _scanStart;
}

- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done {
    if (self.mode) { done(NO, @"busy"); return; }
    if (mode == 3) {
        _db = PFLoadDB();
        if (!_db) { done(NO, @"no face enrolled yet"); return; }
    }
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    PFLog(@"start mode=%d camera-auth=%ld appState=%ld", mode, (long)st, (long)[UIApplication sharedApplication].applicationState);
    if (st == AVAuthorizationStatusDenied || st == AVAuthorizationStatusRestricted) {
        done(NO, @"camera access is denied for PhotoFace Enroll (Settings > Privacy > Camera)"); return;
    }
    if (st == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL g) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g) [self start:mode timeout:t done:done]; else done(NO, @"camera permission was not granted");
            });
        }];
        return;
    }
    _done = [done copy];
    _got = [NSMutableArray new]; _bins = [NSMutableArray new]; _scanOf = [NSMutableArray new];
    _frames = 0; _interrupt = nil; _lastProc = 0; _retries = 0; _lastDbg = 0; _scanIdx = 0;
    _lmBroken = NO; _rectErrLogged = NO;
    [self resetScanState];
    _startTS = CACurrentMediaTime(); _lastFrameTS = _startTS;
    _deadlineTS = _startTS + t;
    NSString *err = [self build];
    self.mode = mode;
    if (err) { [self finish:NO info:err]; return; }
    [self launchSession];
    [_wd invalidate];
    _wd = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

// Second pass around the circle (enroll only). Runs on the camera queue so it never races with a frame.
- (void)nextScan {
    dispatch_async(_q, ^{
        if (self.mode != 2) return;
        self->_scanIdx = 1;
        [self resetScanState];
        self->_deadlineTS = CACurrentMediaTime() + kScanSeconds;
        PFLog(@"second scan started");
    });
}

- (void)launchSession {
    AVCaptureSession *s = _s;
    if (!s) return;
    dispatch_async(_cfg, ^{
        if (!self.mode || s != self->_s) return;
        [s startRunning];
        PFLog(@"startRunning returned, running=%d interrupted=%d (try %d)", s.isRunning, s.isInterrupted, self->_retries);
    });
}

- (void)tick {
    if (!self.mode) return;
    NSTimeInterval n = CACurrentMediaTime();
    BOOL held = _s.isInterrupted;
    if (_frames == 0 && _retries < 4 && n - _startTS > 3.0 * (_retries + 1)) {
        _retries++;
        PFLog(@"no frames after %.1fs (running=%d interrupted=%d) - rebuilding session (retry %d)", n - _startTS, _s.isRunning, held, _retries);
        NSString *err = [self build];
        if (err) { [self finish:NO info:err]; return; }
        [self launchSession];
        return;
    }
    if (_frames == 0 && n - _startTS > 20.0) {
        [self finish:NO info:[NSString stringWithFormat:@"the camera isn't delivering frames (running: %@, interrupted: %@%@)",
                              _s.isRunning ? @"yes" : @"no", held ? @"yes" : @"no",
                              _interrupt ? [NSString stringWithFormat:@", %@", _interrupt] : @""]];
        return;
    }
    if (_frames > 0 && n - _lastFrameTS > 3) { [self finish:NO info:@"the camera stopped"]; return; }
    if (n > _deadlineTS) {
        if (self.mode == 3) [self finish:YES info:@"test ended"];
        else if (_phase == 2) [self finish:NO info:@"cancelled"];   // walked away between the two scans
        else [self finish:NO info:@"setup timed out before enough face angles were captured"];
    }
}

- (void)cancel { [self finish:NO info:@"cancelled"]; }

- (void)finish:(BOOL)ok info:(NSString *)info {
    if (!self.mode) return;
    self.mode = 0;
    NSTimer *w = _wd; _wd = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [w invalidate]; });
    PFLog(@"finish ok=%d info=%@ frames=%d", ok, info, _frames);
    AVCaptureSession *s = _s;
    dispatch_async(_cfg, ^{ [s stopRunning]; });
    void (^d)(BOOL, NSString *) = _done; _done = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (d) d(ok, info); });
}

- (void)report:(NSDictionary *)d {
    void (^p)(NSDictionary *) = self.progress;
    if (!p) return;
    dispatch_async(dispatch_get_main_queue(), ^{ p(d); });
}

// Square crop around the face (1.3x), cut with plain CoreGraphics: Core Image crashed in this app (OpenGL context creation).
// The geometry must stay identical to PFScanner printFor: in Tweak.x, so enrolled and live prints are comparable.
- (VNFeaturePrintObservation *)printFor:(CVPixelBufferRef)pb face:(CGRect)box {
    size_t W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb);
    CGRect r = VNImageRectForNormalizedRect(box, W, H);   // origin bottom-left, same as a CG bitmap context
    CGFloat side = MAX(r.size.width, r.size.height) * 1.3;
    CGRect sq = CGRectMake(CGRectGetMidX(r) - side / 2, CGRectGetMidY(r) - side / 2, side, side);
    sq = CGRectIntegral(CGRectIntersection(sq, CGRectMake(0, 0, W, H)));
    if (sq.size.width < 8 || sq.size.height < 8) return nil;

    CGImageRef cg = NULL;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bi = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;   // BGRA
    CGContextRef src = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), W, H, 8, CVPixelBufferGetBytesPerRow(pb), cs, bi);
    CGContextRef dst = CGBitmapContextCreate(NULL, (size_t)sq.size.width, (size_t)sq.size.height, 8, 0, cs, bi);
    if (src && dst) {
        CGImageRef full = CGBitmapContextCreateImage(src);
        if (full) {
            CGContextDrawImage(dst, CGRectMake(-sq.origin.x, -sq.origin.y, W, H), full);
            CGImageRelease(full);
            cg = CGBitmapContextCreateImage(dst);   // owns its own pixels, safe after the buffer is unlocked
        }
    }
    if (src) CGContextRelease(src);
    if (dst) CGContextRelease(dst);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!cg) return nil;

    // The crop only lives in memory for this request. No image is ever written anywhere; only the feature print is kept.
    VNGenerateImageFeaturePrintRequest *pr = [VNGenerateImageFeaturePrintRequest new];
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    BOOL ok = [h performRequests:@[pr] error:nil];
    CGImageRelease(cg);
    return ok ? (VNFeaturePrintObservation *)pr.results.firstObject : nil;
}

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    NSTimeInterval now = CACurrentMediaTime();
    _frames++; _lastFrameTS = now;
    int mode = self.mode;
    if (!mode) return;
    if (mode == 2 && _phase >= 2) return;   // paused between passes, or finishing
    if (now - _lastProc < 0.15) return;
    _lastProc = now;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;

    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
    VNRequest *fr = nil; NSError *verr = nil;
    if (mode == 2 && !_lmBroken) {
        VNDetectFaceLandmarksRequest *lr = [VNDetectFaceLandmarksRequest new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        lr.usesCPUOnly = YES;   // GPU/ANE paths are not available to this unsandboxed app (same cause as the Core Image crash)
#pragma clang diagnostic pop
        if ([h performRequests:@[lr] error:&verr]) { fr = lr; }
        else { _lmBroken = YES; PFLog(@"landmarks request failed (%@) - falling back to plain face detection", verr); }
    }
    if (!fr) {
        VNDetectFaceRectanglesRequest *rr = [VNDetectFaceRectanglesRequest new];
        if (![h performRequests:@[rr] error:&verr]) {
            if (!_rectErrLogged) { _rectErrLogged = YES; PFLog(@"face detection failed: %@", verr); }
            return;
        }
        fr = rr;
    }
    NSArray *faces = fr.results;

    if (mode == 2) { [self enrollFrame:pb faces:faces conn:c now:now]; return; }

    // ---- test mode: live match score against the enrolled face ----
    NSString *hint = nil; VNFaceObservation *f = nil;
    if (faces.count == 0) hint = @"Can't see your face.\nLook at the front camera.";
    else if (faces.count > 1) hint = @"Only one face in view, please.";
    else { f = faces[0]; if (f.boundingBox.size.width < 0.3) hint = @"Move a little closer."; }
    if (hint) { [self report:@{@"hint": hint, @"face": @NO}]; return; }
    VNFeaturePrintObservation *fp = [self printFor:pb face:f.boundingBox];
    if (!fp) return;
    float best = FLT_MAX;
    for (VNFeaturePrintObservation *p in _db[@"prints"]) {
        float d; if ([fp computeDistance:&d toFeaturePrintObservation:p error:nil]) best = MIN(best, d);
    }
    [self report:@{@"best": @(best), @"limit": @(PFLimit(_db)), @"face": @YES}];
}

#pragma mark enroll engine

- (NSArray *)sectorCounts { NSMutableArray *a = [NSMutableArray new]; for (int k = 0; k < 8; k++) [a addObject:@(MIN(_secCount[k], kNeedPer))]; return a; }

- (void)addSample:(VNFeaturePrintObservation *)fp bin:(int)bin now:(NSTimeInterval)now {
    [_got addObject:fp]; [_bins addObject:@(bin)]; [_scanOf addObject:@(_scanIdx)];
    _lastCap = now; _lastGain = now;
}

- (void)enrollFrame:(CVPixelBufferRef)pb faces:(NSArray *)faces conn:(AVCaptureConnection *)c now:(NSTimeInterval)now {
    NSDictionary *base = @{@"phase": @(_phase), @"scan": @(_scanIdx), @"sectors": [self sectorCounts],
                           @"center": @(MIN(_center, kNeedCenter)), @"target": @(-1)};
    NSString *code = nil; VNFaceObservation *f = nil;
    if (faces.count == 0) code = @"nface";
    else if (faces.count > 1) code = @"multi";
    else {
        f = faces[0];
        CGRect b = f.boundingBox; float mx = CGRectGetMidX(b), my = CGRectGetMidY(b);
        if (b.size.width < 0.3) code = @"close";
        else if (b.size.width > 0.85) code = @"far";
        else if (mx < 0.22 || mx > 0.78 || my < 0.18 || my > 0.82) code = @"center";
    }
    if (code) {
        NSMutableDictionary *d = [base mutableCopy]; d[@"code"] = code; d[@"face"] = @NO;
        [self report:d]; return;
    }

    // Head direction from where the nose sits inside the face (screen space: x right, y up). Works whatever
    // the signs of Vision's yaw/pitch are, and matches what the user sees in the mirrored preview.
    float px = 0, py = 0; BOOL havePose = NO;
    VNFaceLandmarks2D *lm = f.landmarks;
    if (lm && lm.nose && lm.allPoints && lm.nose.pointCount > 0 && lm.allPoints.pointCount > 0) {
        const CGPoint *np = lm.nose.normalizedPoints, *ap = lm.allPoints.normalizedPoints;
        size_t nc = lm.nose.pointCount, ac = lm.allPoints.pointCount;
        float nx = 0, ny = 0, ax = 0, ay = 0;
        for (size_t i = 0; i < nc; i++) { nx += np[i].x; ny += np[i].y; }
        for (size_t i = 0; i < ac; i++) { ax += ap[i].x; ay += ap[i].y; }
        nx /= nc; ny /= nc; ax /= ac; ay /= ac;
        float ox = nx - ax, oy = ny - ay;
        px = c.isVideoMirrored ? ox : -ox; py = oy; havePose = YES;
    } else {
        float yaw = f.yaw ? f.yaw.floatValue : 0, pitch = 0;
        if (@available(iOS 15.0, *)) { if (f.pitch) pitch = f.pitch.floatValue; }
        px = yaw; py = pitch;
    }

    if (_phase == 0) {
        // Step 1: face found and centred. Whenever the face is roughly where the earlier straight-ahead frames were, it counts.
        BOOL near = (_cN == 0 || hypotf(px - _cSumX / _cN, py - _cSumY / _cN) < 0.12f);
        if (near && _center < kNeedCenter && now - _lastCap >= 0.25) {
            VNFeaturePrintObservation *fp = [self printFor:pb face:f.boundingBox];
            if (fp) { [self addSample:fp bin:-1 now:now]; _center++; _cSumX += px; _cSumY += py; _cN++; }
        }
        if (_center >= kNeedCenter) {
            _biasX = _cSumX / _cN; _biasY = _cSumY / _cN;
            _phase = 1; _scanStart = now; _lastGain = now;
            PFLog(@"scan %d: straight-ahead done, bias %.3f %.3f", _scanIdx + 1, _biasX, _biasY);
        }
        NSMutableDictionary *d = [base mutableCopy];
        d[@"phase"] = @(_phase); d[@"center"] = @(MIN(_center, kNeedCenter)); d[@"sectors"] = [self sectorCounts];
        d[@"code"] = (_phase == 1) ? @"circle" : @"hold"; d[@"face"] = @YES;
        [self report:d];
        return;
    }

    // Step 2: head directions relative to the straight-ahead position.
    float qx = px - _biasX, qy = py - _biasY, tol = havePose ? 0.04f : 0.10f;
    int bin = -2;   // -2 = near centre / in between, ignore
    if (hypotf(qx, qy) >= tol) bin = ((int)lroundf(atan2f(qy, qx) / (float)(M_PI / 4)) % 8 + 8) % 8;
    if (bin >= 0 && _secCount[bin] < kNeedPer && now - _lastCap >= 0.25) {
        VNFeaturePrintObservation *fp = [self printFor:pb face:f.boundingBox];
        if (fp) { [self addSample:fp bin:bin now:now]; _secCount[bin]++; _lastSec = bin; }
    }
    int full = 0;
    for (int k = 0; k < 8; k++) if (_secCount[k] >= kNeedPer) full++;
    int target = -1;   // next gap, going clockwise from where we last were
    int start = _lastSec >= 0 ? _lastSec : 2;
    for (int t = 0; t < 8; t++) { int k = ((start - t) % 8 + 8) % 8; if (_secCount[k] < kNeedPer) { target = k; break; } }
    NSString *msg = (bin >= 0 && bin == target) ? @"good" : (now - _lastGain > 5 ? @"further" : @"circle");
    NSMutableDictionary *d = [base mutableCopy];
    d[@"phase"] = @1; d[@"sectors"] = [self sectorCounts]; d[@"target"] = @(target); d[@"code"] = msg; d[@"face"] = @YES;
    [self report:d];
    if (now - _lastDbg > 1.0) {
        _lastDbg = now;
        PFLog(@"scan %d: %@ full=%d target=%d off %.2f,%.2f samples=%lu", _scanIdx + 1, havePose ? @"landmarks" : @"fallback", full, target, qx, qy, (unsigned long)_got.count);
    }
    if (full >= 6 || (now - _scanStart > 40 && full >= 4)) [self scanComplete:now];
}

- (void)scanComplete:(NSTimeInterval)now {
    PFLog(@"scan %d complete (%lu samples so far)", _scanIdx + 1, (unsigned long)_got.count);
    if (_scanIdx + 1 >= kScans) { _phase = 3; [self finalizeEnroll]; return; }
    _phase = 2;
    _deadlineTS = now + 30;   // time to tap Continue
    [self report:@{@"event": @"scanDone", @"scan": @(_scanIdx)}];
}

// Tolerance base: how far a sample is from its nearest sample of the OTHER pass (an independent capture of the same
// poses), 95th percentile. A live face later is exactly such an independent capture.
- (void)finalizeEnroll {
    NSInteger n = _got.count;
    if (n < 10) { [self finish:NO info:@"not enough face samples were captured"]; return; }
    NSMutableArray<NSNumber *> *ds = [NSMutableArray new];
    for (NSInteger i = 0; i < n; i++) {
        float mn = FLT_MAX;
        for (NSInteger j = 0; j < n; j++) {
            if ([_scanOf[i] intValue] == [_scanOf[j] intValue]) continue;
            float d; if ([_got[i] computeDistance:&d toFeaturePrintObservation:_got[j] error:nil]) mn = MIN(mn, d);
        }
        if (mn < FLT_MAX) [ds addObject:@(mn)];
    }
    float base = 0;
    if (ds.count) {
        [ds sortUsingSelector:@selector(compare:)];
        base = [ds[(NSUInteger)floor((ds.count - 1) * 0.95)] floatValue];
    }
    if (base <= 0) {   // fallback: nearest sample of a different head direction
        for (NSInteger i = 0; i < n; i++) {
            float mn = FLT_MAX;
            for (NSInteger j = 0; j < n; j++) {
                if ([_bins[i] intValue] == [_bins[j] intValue]) continue;
                float d; if ([_got[i] computeDistance:&d toFeaturePrintObservation:_got[j] error:nil]) mn = MIN(mn, d);
            }
            if (mn < FLT_MAX) base = MAX(base, mn);
        }
    }
    if (base <= 0) { [self finish:NO info:@"couldn't measure the face data"]; return; }
    NSDictionary *db = @{@"prints": [_got copy], @"th": @(base * 1.25f), @"base": @(base),
                         @"bins": [_bins copy], @"scans": [_scanOf copy], @"version": @2,
                         @"created": @((long long)[[NSDate date] timeIntervalSince1970])};
    NSError *err = nil;
    NSData *dat = [NSKeyedArchiver archivedDataWithRootObject:db requiringSecureCoding:YES error:&err];
    if (!dat || ![dat writeToFile:PFDBPath() atomically:YES]) { PFLog(@"save failed: %@", err); [self finish:NO info:@"could not save face data"]; return; }
    chmod(PFDBPath().fileSystemRepresentation, 0600);
    NSDictionary *back = PFLoadDB();   // prove the tweak will be able to read it
    if ((NSInteger)[back[@"prints"] count] != n) {
        PFLog(@"read-back mismatch: wrote %ld, read %lu", (long)n, (unsigned long)[back[@"prints"] count]);
        [[NSFileManager defaultManager] removeItemAtPath:PFDBPath() error:nil];
        [self finish:NO info:@"face data could not be read back after saving"]; return;
    }
    PFLog(@"saved %ld samples, base %.3f, %lu bytes", (long)n, base, (unsigned long)dat.length);
    [self finish:YES info:[NSString stringWithFormat:@"%ld samples", (long)n]];
}
@end

#pragma mark - UI (Face ID style setup)

typedef NS_ENUM(int, PFStage) { PFStageIntro, PFStageScan, PFStageBetween, PFStageDone, PFStageFail };

@interface PFVC : UIViewController
- (void)startMode:(int)mode;
- (BOOL)isRunning;
- (void)abortIfRunning;
@end

@implementation PFVC {
    PFScan *_scan; UIView *_circle; AVCaptureVideoPreviewLayer *_pl;
    NSMutableArray<CAShapeLayer *> *_ticks; int _tickSector[kTicks], _pulseTarget;
    CAShapeLayer *_glyph, *_disc, *_check;
    UILabel *_title, *_sub, *_ver; UIButton *_primary, *_secondary, *_cancel;
    int _mode, _scanNo; PFStage _stage; BOOL _flow; NSTimer *_idle, *_attach;
}
- (BOOL)isRunning { return _flow; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (UILabel *)label:(CGRect)f size:(CGFloat)s weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = [UIFont systemFontOfSize:s weight:w]; l.textColor = c;
    l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0;
    return l;
}
- (UIButton *)button:(CGRect)f title:(NSString *)t filled:(BOOL)filled action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.titleLabel.font = [UIFont systemFontOfSize:19 weight:filled ? UIFontWeightSemibold : UIFontWeightRegular];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:filled ? UIColor.whiteColor : PFBlue() forState:UIControlStateNormal];
    if (filled) { b.backgroundColor = PFBlue(); b.layer.cornerRadius = 14; }
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// The Face ID style face glyph: four corner brackets, two eyes, a nose and a smile.
- (UIBezierPath *)glyphPath:(CGPoint)c size:(CGFloat)g {
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat s = g / 2, a = g * 0.28;
    for (int sx = -1; sx <= 1; sx += 2) for (int sy = -1; sy <= 1; sy += 2) {
        [p moveToPoint:CGPointMake(c.x + sx * s, c.y + sy * (s - a))];
        [p addLineToPoint:CGPointMake(c.x + sx * s, c.y + sy * s)];
        [p addLineToPoint:CGPointMake(c.x + sx * (s - a), c.y + sy * s)];
    }
    for (int e = -1; e <= 1; e += 2) {
        [p moveToPoint:CGPointMake(c.x + e * g * 0.2, c.y - g * 0.17)];
        [p addLineToPoint:CGPointMake(c.x + e * g * 0.2, c.y - g * 0.05)];
    }
    [p moveToPoint:CGPointMake(c.x, c.y - g * 0.12)];
    [p addLineToPoint:CGPointMake(c.x, c.y + g * 0.07)];
    [p addLineToPoint:CGPointMake(c.x - g * 0.06, c.y + g * 0.07)];
    [p moveToPoint:CGPointMake(c.x - g * 0.2, c.y + g * 0.2)];
    [p addQuadCurveToPoint:CGPointMake(c.x + g * 0.2, c.y + g * 0.2) controlPoint:CGPointMake(c.x, c.y + g * 0.34)];
    return p;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *v = self.view;
    v.backgroundColor = UIColor.blackColor;
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat d = MIN(W * 0.66, 270), cx = W / 2, cy = H * 0.37;

    _circle = [[UIView alloc] initWithFrame:CGRectMake(cx - d / 2, cy - d / 2, d, d)];
    _circle.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
    _circle.layer.cornerRadius = d / 2; _circle.layer.masksToBounds = YES;
    _circle.hidden = YES;
    [v addSubview:_circle];

    _ticks = [NSMutableArray new];
    for (int i = 0; i < kTicks; i++) {
        CGFloat a = -M_PI_2 + i * 2 * M_PI / kTicks, r1 = d / 2 + 11, r2 = d / 2 + 25;
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(cx + r1 * cos(a), cy + r1 * sin(a))];
        [p addLineToPoint:CGPointMake(cx + r2 * cos(a), cy + r2 * sin(a))];
        CAShapeLayer *l = [CAShapeLayer layer];
        l.path = p.CGPath; l.lineWidth = 3.5; l.lineCap = kCALineCapRound;
        l.strokeColor = PFTrack().CGColor; l.opacity = 0;
        [v.layer addSublayer:l]; [_ticks addObject:l];
        float th = (90.f - (360.f / kTicks) * i) * (float)M_PI / 180.f;   // screen direction of this tick, counter-clockwise from "right"
        _tickSector[i] = ((int)lroundf(th / (float)(M_PI / 4)) % 8 + 8) % 8;
    }
    _pulseTarget = -2;

    _glyph = [CAShapeLayer layer];
    _glyph.path = [self glyphPath:CGPointMake(cx, cy) size:d * 0.62].CGPath;
    _glyph.fillColor = nil; _glyph.strokeColor = PFBlue().CGColor;
    _glyph.lineWidth = 6; _glyph.lineCap = kCALineCapRound; _glyph.lineJoin = kCALineJoinRound;
    [v.layer addSublayer:_glyph];

    CGFloat R = d * 0.42;   // the green check shown when setup is complete
    _disc = [CAShapeLayer layer];
    _disc.frame = CGRectMake(cx - R, cy - R, 2 * R, 2 * R);
    _disc.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 2 * R, 2 * R)].CGPath;
    _disc.fillColor = PFGreen().CGColor; _disc.hidden = YES;
    [v.layer addSublayer:_disc];
    _check = [CAShapeLayer layer];
    _check.frame = _disc.frame;
    UIBezierPath *cp = [UIBezierPath bezierPath];
    [cp moveToPoint:CGPointMake(R * 0.55, R * 1.04)];
    [cp addLineToPoint:CGPointMake(R * 0.88, R * 1.36)];
    [cp addLineToPoint:CGPointMake(R * 1.46, R * 0.68)];
    _check.path = cp.CGPath; _check.fillColor = nil; _check.strokeColor = UIColor.whiteColor.CGColor;
    _check.lineWidth = 11; _check.lineCap = kCALineCapRound; _check.lineJoin = kCALineJoinRound; _check.hidden = YES;
    [v.layer addSublayer:_check];

    _title = [self label:CGRectMake(24, H * 0.62, W - 48, 70) size:27 weight:UIFontWeightBold color:UIColor.whiteColor];
    [v addSubview:_title];
    _sub = [self label:CGRectMake(32, H * 0.62 + 76, W - 64, 90) size:16 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.62 alpha:1]];
    [v addSubview:_sub];

    _primary = [self button:CGRectMake(W / 2 - 125, H - 108, 250, 52) title:@"Get Started" filled:YES action:@selector(tapPrimary)];
    [v addSubview:_primary];
    _secondary = [self button:CGRectMake(W / 2 - 125, H - 52, 250, 40) title:@"Close" filled:NO action:@selector(tapSecondary)];
    _secondary.hidden = YES;
    [v addSubview:_secondary];
    _cancel = [self button:CGRectMake(14, 22, 90, 36) title:@"Cancel" filled:NO action:@selector(tapCancel)];
    _cancel.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    _cancel.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [v addSubview:_cancel];
    _ver = [self label:CGRectMake(0, H - 16, W, 12) size:9 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.3 alpha:1]];
    _ver.text = @"PhotoFace Enroll build 0.5.0";
    [v addSubview:_ver];
    _primary.hidden = YES; _cancel.hidden = YES;
}

#pragma mark ring

- (void)setTickColor:(UIColor *)c all:(BOOL)all { for (CAShapeLayer *l in _ticks) { l.strokeColor = c.CGColor; if (all) l.opacity = 1; } }
- (void)showRing:(BOOL)on {
    for (CAShapeLayer *l in _ticks) { l.opacity = on ? 1 : 0; [l removeAnimationForKey:@"pulse"]; l.strokeColor = PFTrack().CGColor; }
    _pulseTarget = -2;
}
- (void)applyRing:(NSArray *)cnt target:(int)tgt phase:(int)ph {
    int per[8] = {0}, idx[kTicks];
    for (int i = 0; i < kTicks; i++) idx[i] = per[_tickSector[i]]++;
    if (tgt != _pulseTarget) { for (CAShapeLayer *l in _ticks) [l removeAnimationForKey:@"pulse"]; _pulseTarget = tgt; }
    for (int i = 0; i < kTicks; i++) {
        CAShapeLayer *l = _ticks[i];
        if (ph == 0) { l.strokeColor = PFTrack().CGColor; [l removeAnimationForKey:@"pulse"]; continue; }
        int sct = _tickSector[i], c = MIN([cnt[sct] intValue], kNeedPer);
        int filled = (int)ceilf(per[sct] * c / (float)kNeedPer);
        if (idx[i] < filled) { l.strokeColor = PFGreen().CGColor; [l removeAnimationForKey:@"pulse"]; }
        else if (sct == tgt) {
            l.strokeColor = [UIColor colorWithRed:0.55 green:1 blue:0.68 alpha:1].CGColor;   // the part of the ring to head toward, pulsing
            if (![l animationForKey:@"pulse"]) {
                CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
                a.fromValue = @1; a.toValue = @0.25; a.duration = 0.55; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
                [l addAnimation:a forKey:@"pulse"];
            }
        } else { l.strokeColor = PFTrack().CGColor; [l removeAnimationForKey:@"pulse"]; }
    }
    _circle.layer.borderWidth = 3;
    _circle.layer.borderColor = (ph == 0 ? PFTrack() : PFGreen()).CGColor;
}
- (void)fillRingSweep {   // the circle completes itself clockwise
    for (CAShapeLayer *l in _ticks) [l removeAnimationForKey:@"pulse"];
    for (int i = 0; i < kTicks; i++) {
        CAShapeLayer *l = _ticks[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 9 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ l.opacity = 1; l.strokeColor = PFGreen().CGColor; });
    }
}
- (void)haptic { [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess]; }

#pragma mark preview

- (void)attachPreview {
    if (!kShowLivePreview) return;
    AVCaptureSession *s = _scan.session;
    if (!s) return;
    if (_pl) { if (_pl.session != s) _pl.session = s; return; }
    _pl = [AVCaptureVideoPreviewLayer layerWithSession:s];
    _pl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _pl.frame = _circle.bounds;
    if (_pl.connection.isVideoOrientationSupported) _pl.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    [_circle.layer addSublayer:_pl];
}
- (void)detachPreview { [_attach invalidate]; _attach = nil; [_pl removeFromSuperlayer]; _pl = nil; }

#pragma mark screens

- (void)setTitle_:(NSString *)t sub:(NSString *)s { if (![_title.text isEqualToString:t]) _title.text = t; if (![_sub.text isEqualToString:s]) _sub.text = s; }
- (void)idleStart {
    [_idle invalidate];
    __weak PFVC *ws = self;
    _idle = [NSTimer scheduledTimerWithTimeInterval:40 repeats:NO block:^(NSTimer *t) { PFVC *s = ws; if (s && s->_stage == PFStageIntro) { PFLog(@"intro idle, cancelling"); [s finished:NO info:@"cancelled"]; } }];
}

- (void)startMode:(int)mode {
    PFLog(@"startMode %d begin", mode);
    if ([self isRunning]) return;
    _mode = mode; _flow = YES; _scanNo = 0;
    _title.textColor = UIColor.whiteColor;
    if (mode == 2) [self showIntro]; else [self beginTest];
}

- (void)showIntro {
    _stage = PFStageIntro;
    [self detachPreview];
    _circle.hidden = YES; [self showRing:NO];
    _disc.hidden = YES; _check.hidden = YES; _glyph.hidden = NO; _glyph.strokeColor = PFBlue().CGColor;
    [self setTitle_:@"PhotoFace" sub:@"PhotoFace uses the front camera to recognise your face and unlock your iPhone.\n\nHold your iPhone upright, at arm's length, in good light."];
    [_primary setTitle:@"Get Started" forState:UIControlStateNormal]; _primary.hidden = NO;
    _secondary.hidden = YES; _cancel.hidden = NO;
    [self idleStart];
}

- (void)beginScan:(int)idx {
    [_idle invalidate]; _idle = nil;
    _scanNo = idx; _stage = PFStageScan;
    _glyph.hidden = (BOOL)kShowLivePreview; _glyph.strokeColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    _disc.hidden = YES; _check.hidden = YES;
    _circle.hidden = NO; _circle.layer.borderWidth = 3; _circle.layer.borderColor = PFTrack().CGColor;
    [self showRing:YES];
    _primary.hidden = YES; _secondary.hidden = YES; _cancel.hidden = NO;
    [self setTitle_:@"Position your face in the frame" sub:@"Look straight at the camera."];
    if (idx == 0) {
        _scan = [PFScan new];
        __weak PFVC *ws = self;
        _scan.progress = ^(NSDictionary *i) { [ws update:i]; };
        [_scan start:2 timeout:kScanSeconds done:^(BOOL ok, NSString *info) { [ws finished:ok info:info]; }];
        PFLog(@"scan 1 started, attaching preview");
        [self attachPreview];
        // the session can be rebuilt on a retry; keep the preview attached
        [_attach invalidate];
        _attach = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            PFVC *s = ws; if (!s || !s->_flow) { [t invalidate]; return; }
            [s attachPreview];
        }];
    } else {
        [_scan nextScan];
    }
}

- (void)beginTest {
    _stage = PFStageScan;
    _glyph.hidden = YES; _disc.hidden = YES; _check.hidden = YES;
    _circle.hidden = NO; [self showRing:YES];
    _primary.hidden = YES; _secondary.hidden = YES; _cancel.hidden = NO;
    [self setTitle_:@"Test Recognition" sub:@"Look at the camera. Shows how close the live match is to your enrolled face. Lower is closer."];
    _scan = [PFScan new];
    __weak PFVC *ws = self;
    _scan.progress = ^(NSDictionary *i) { [ws update:i]; };
    [_scan start:3 timeout:90 done:^(BOOL ok, NSString *info) { [ws finished:ok info:info]; }];
    [self attachPreview];
    [_attach invalidate];
    _attach = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        PFVC *s = ws; if (!s || !s->_flow) { [t invalidate]; return; }
        [s attachPreview];
    }];
}

- (void)showBetween {
    _stage = PFStageBetween;
    [self fillRingSweep]; [self haptic];
    _circle.layer.borderColor = PFGreen().CGColor;
    [self setTitle_:@"First scan complete" sub:@"Now move your head slowly to complete the circle a second time."];
    [_primary setTitle:@"Continue" forState:UIControlStateNormal]; _primary.hidden = NO;
}

- (void)showDone:(NSString *)info {
    _stage = PFStageDone; [self detachPreview];
    [self haptic];
    _circle.hidden = YES; [self showRing:NO]; _glyph.hidden = YES;
    _disc.hidden = NO; _check.hidden = NO;
    CABasicAnimation *pop = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pop.fromValue = @0.4; pop.toValue = @1; pop.duration = 0.35; pop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [_disc addAnimation:pop forKey:@"pop"]; [_check addAnimation:pop forKey:@"pop"];
    [self setTitle_:@"PhotoFace is now set up" sub:@"You can unlock your iPhone by looking at it. After a restart you still enter your passcode once."];
    [_primary setTitle:@"Done" forState:UIControlStateNormal]; _primary.hidden = NO;
    _secondary.hidden = YES; _cancel.hidden = YES;
}

- (void)showFail:(NSString *)info {
    _stage = PFStageFail; [self detachPreview];
    _circle.hidden = YES; [self showRing:NO]; _disc.hidden = YES; _check.hidden = YES;
    _glyph.hidden = NO; _glyph.strokeColor = [UIColor colorWithRed:1 green:0.35 blue:0.3 alpha:1].CGColor;
    [self setTitle_:(_mode == 3 ? @"Test couldn't run" : @"Setup didn't finish") sub:[NSString stringWithFormat:@"%@", info]];
    [_primary setTitle:@"Try Again" forState:UIControlStateNormal]; _primary.hidden = NO;
    [_secondary setTitle:@"Close" forState:UIControlStateNormal]; _secondary.hidden = NO; _cancel.hidden = YES;
}

#pragma mark actions

- (void)tapPrimary {
    switch (_stage) {
        case PFStageIntro:   [self beginScan:0]; break;
        case PFStageBetween: [self beginScan:1]; break;
        case PFStageDone:    [self leave]; break;
        case PFStageFail:    _flow = YES; if (_mode == 3) [self beginTest]; else [self beginScan:0]; break;
        default: break;
    }
}
- (void)tapSecondary { [self leave]; }
- (void)tapCancel { [self abortIfRunning]; }
- (void)abortIfRunning {
    if (!_flow) return;
    if (_scan.mode) [_scan cancel]; else [self finished:NO info:@"cancelled"];
}

#pragma mark progress

- (void)update:(NSDictionary *)i {
    if (!_flow) return;
    [self attachPreview];
    if (_mode == 3) {
        if (i[@"best"]) {
            float best = [i[@"best"] floatValue], lim = [i[@"limit"] floatValue];
            BOOL ok = best < lim;
            [self setTickColor:ok ? PFGreen() : PFTrack() all:YES];
            [self setTitle_:[NSString stringWithFormat:@"Match %.2f  (needs below %.2f)", best, lim] sub:ok ? @"✓ Recognised" : @"✗ Not recognised"];
        } else if (i[@"hint"]) { [self setTickColor:PFTrack() all:YES]; [self setTitle_:i[@"hint"] sub:@""]; }
        return;
    }
    if ([i[@"event"] isEqual:@"scanDone"]) { if (_stage == PFStageScan) [self showBetween]; return; }
    if (_stage != PFStageScan) return;
    int ph = [i[@"phase"] intValue];
    if (i[@"sectors"]) [self applyRing:i[@"sectors"] target:[i[@"target"] intValue] phase:ph];
    NSString *code = i[@"code"] ?: @"";
    NSString *t = @"Position your face in the frame", *s = @"Look straight at the camera.";
    if ([code isEqual:@"nface"]) { s = @"Can't see your face. Look at the front camera."; }
    else if ([code isEqual:@"multi"]) { t = @"Only one face, please"; s = @"Make sure nobody else is in view."; }
    else if ([code isEqual:@"close"]) { t = @"Move a little closer"; s = @"Bring your face closer to the camera."; }
    else if ([code isEqual:@"far"]) { t = @"Move back a little"; s = @"Your face is too close to the camera."; }
    else if ([code isEqual:@"center"]) { t = @"Center your face in the frame"; s = @"Keep your whole face inside the circle."; }
    else if ([code isEqual:@"hold"]) { s = @"Hold still…"; }
    else if ([code isEqual:@"circle"]) { t = @"Move your head slowly to complete the circle"; s = _scanNo == 0 ? @"" : @"Second scan"; }
    else if ([code isEqual:@"good"]) { t = @"Move your head slowly to complete the circle"; s = @"Good, keep going."; }
    else if ([code isEqual:@"further"]) { t = @"Move your head slowly to complete the circle"; s = @"Tilt a little further toward the bright part of the ring."; }
    else if (!code.length && ph == 1) { t = @"Move your head slowly to complete the circle"; s = @""; }
    [self setTitle_:t sub:s];
}

- (void)finished:(BOOL)ok info:(NSString *)info {
    if (!_flow) return;
    _flow = NO; [_idle invalidate]; _idle = nil; [_attach invalidate]; _attach = nil;
    BOOL cancelled = [info isEqualToString:@"cancelled"];
    if (_mode == 2) {
        if (ok) PFWriteStatus([@"ok: " stringByAppendingString:info]);
        else if (cancelled) PFWriteStatus(@"cancel");
        else PFWriteStatus([@"fail: " stringByAppendingString:info]);
    }
    notify_post("com.photoface.enrolldone");
    if (cancelled) { [self leave]; return; }
    if (ok && _mode == 2) [self showDone:info];
    else if (ok) [self leave];
    else [self showFail:info];
}

// go back to the Home Screen and drop the process so the camera is released
- (void)leave {
    PFLog(@"leave: going home and exiting");
    _flow = NO;
    UIApplication *app = [UIApplication sharedApplication];
    SEL sus = NSSelectorFromString(@"suspend");
    if ([app respondsToSelector:sus]) ((void (*)(id, SEL))objc_msgSend)(app, sus);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ exit(0); });
}
@end

#pragma mark - app

@interface PFAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation PFAppDelegate {
    PFVC *_vc;
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)o {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _vc = [PFVC new];
    self.window.rootViewController = _vc;
    [self.window makeKeyAndVisible];
    PFInstallCrashRecorder();
    PFLog(@"app launched appState=%ld pid=%d", (long)app.applicationState, getpid());
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)app {
    NSString *m = [NSString stringWithContentsOfFile:PFModePath() encoding:NSUTF8StringEncoding error:nil];
    if (!m.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:PFModePath() error:nil];
    int mode = m.intValue;
    if (mode != 2 && mode != 3) return;
    PFLog(@"app active, starting mode %d", mode);
    // small pause so the app is fully frontmost before the camera starts
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self->_vc startMode:mode]; });
}
- (void)applicationWillResignActive:(UIApplication *)app { PFLog(@"app will resign active"); }
- (void)applicationWillTerminate:(UIApplication *)app { PFLog(@"app will terminate"); }
- (void)applicationDidEnterBackground:(UIApplication *)app {
    PFLog(@"app entered background (scan running: %d)", [_vc isRunning]);
    if ([_vc isRunning]) { PFLog(@"app went to background mid-scan, cancelling"); [_vc abortIfRunning]; }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([PFAppDelegate class])); }
}
