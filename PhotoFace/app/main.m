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
#define kNeedCenter 6   // straight-ahead samples
#define kNeedPer 3      // samples per head direction (8 directions)

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
static UIColor *PFDim(void) { return [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:0.28]; }   // always-visible ring track

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
- (void)cancel;
@end

@implementation PFScan {
    AVCaptureSession *_s; dispatch_queue_t _q, _cfg; NSTimer *_wd;
    NSTimeInterval _startTS, _deadlineTS, _lastFrameTS, _lastProc, _lastGain;
    int _frames, _center, _secCount[8], _retries;
    NSMutableArray *_got; NSMutableArray<NSNumber *> *_bins;
    NSDictionary *_db; void (^_done)(BOOL, NSString *);
    NSString *_interrupt; NSMutableArray *_obs;
    float _biasX, _biasY, _cSumX, _cSumY; int _cN, _lastSec; NSTimeInterval _lastCap; BOOL _lmBroken, _rectErrLogged, _haveRef; float _refX, _refY; int _stableN;
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
    _done = [done copy]; _center = 0; memset(_secCount, 0, sizeof _secCount);
    _got = [NSMutableArray new]; _bins = [NSMutableArray new];
    _frames = 0; _interrupt = nil; _lastProc = 0; _retries = 0;
    _biasX = _biasY = _cSumX = _cSumY = 0; _cN = 0; _lastSec = -1; _lastCap = 0; _lmBroken = NO; _rectErrLogged = NO; _haveRef = NO; _stableN = 0;
    _startTS = CACurrentMediaTime(); _lastFrameTS = _startTS; _lastGain = _startTS;
    _deadlineTS = _startTS + t;
    NSString *err = [self build];
    self.mode = mode;
    if (err) { [self finish:NO info:err]; return; }
    [self launchSession];
    [_wd invalidate];
    _wd = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
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

- (void)report:(NSDictionary *)extra {
    void (^p)(NSDictionary *) = self.progress;
    if (!p) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:extra];
    int secUnits = 0; for (int k = 0; k < 8; k++) secUnits += MIN(_secCount[k], 2);
    d[@"units"] = @(MIN(_center, 4) + MIN(secUnits, 12));
    dispatch_async(dispatch_get_main_queue(), ^{ p(d); });
}

// Square crop around the face (1.3x), cut with plain CoreGraphics: Core Image crashed in this app (OpenGL context creation).
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
    NSString *hint = nil; VNFaceObservation *f = nil;
    if (faces.count == 0) hint = @"Can't see your face.\nLook at the front camera.";
    else if (faces.count > 1) hint = @"Only one face in view, please.";
    else { f = faces[0]; if (f.boundingBox.size.width < 0.3) hint = @"Move a little closer."; }
    if (hint) { [self report:@{@"hint": hint, @"face": @NO}]; return; }

    if (mode == 2) {
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
        BOOL cd = _center >= kNeedCenter;
        float qx = cd ? px - _biasX : px, qy = cd ? py - _biasY : py;
        float tol = havePose ? 0.04f : 0.10f;
        int bin = -2;   // -2 = in between, ignore
        if (!cd) {
            // step 1: no fixed "centre" - whenever the face holds still, that IS straight ahead (offsets differ per face)
            if (!_haveRef || hypotf(px - _refX, py - _refY) > tol) { _refX = px; _refY = py; _haveRef = YES; _stableN = 0; }
            else _stableN++;
            if (_stableN >= 2) bin = -1;
        } else if (hypotf(qx, qy) >= tol) bin = ((int)lroundf(atan2f(qy, qx) / (float)(M_PI / 4)) % 8 + 8) % 8;
        BOOL need = (bin == -1) ? (_center < kNeedCenter) : (bin >= 0 ? _secCount[bin] < kNeedPer : NO);
        if (need && now - _lastCap >= 0.25) {
            VNFeaturePrintObservation *fp = [self printFor:pb face:f.boundingBox];
            if (fp) {
                [_got addObject:fp]; [_bins addObject:@(bin)];
                if (bin == -1) {
                    _center++; _cSumX += px; _cSumY += py; _cN++;
                    if (_center >= kNeedCenter) { _biasX = _cSumX / _cN; _biasY = _cSumY / _cN; PFLog(@"center done, bias %.3f %.3f", _biasX, _biasY); }
                } else { _secCount[bin]++; _lastSec = bin; }
                _lastGain = now; _lastCap = now;
            }
        }
        cd = _center >= kNeedCenter;
        int full = 0, total = MIN(_center, kNeedCenter);
        NSMutableArray *cnt = [NSMutableArray new];
        for (int k = 0; k < 8; k++) { if (_secCount[k] >= kNeedPer) full++; total += MIN(_secCount[k], kNeedPer); [cnt addObject:@(MIN(_secCount[k], kNeedPer))]; }
        int target = -1;
        if (cd) {   // next gap, going clockwise from where we last were
            int start = _lastSec >= 0 ? _lastSec : 2;
            for (int t = 0; t < 8; t++) { int k = ((start - t) % 8 + 8) % 8; if (_secCount[k] < kNeedPer) { target = k; break; } }
        }
        int pct = total * 100 / (kNeedCenter + 8 * kNeedPer);
        NSString *msg, *sub;
        if (!cd) { msg = @"Look straight at the camera\nand hold still"; sub = [NSString stringWithFormat:@"Step 1 of 2  ·  %d%%  ·  hold still", pct]; }
        else if (full < 7) {
            if (bin == target) msg = @"Good, hold it there…";
            else msg = (now - _lastGain > 5) ? @"Tilt a little further toward\nthe bright green part of the ring" : @"Slowly move your head toward\nthe bright green part of the ring";
            sub = [NSString stringWithFormat:@"Step 2 of 2  ·  %d%%  ·  keep your face in the circle", pct];
        } else { msg = @"Almost done…"; sub = @"Finishing up"; }
        [self report:@{@"hint": msg, @"sub": sub, @"face": @YES, @"sectors": cnt, @"target": @(target),
                       @"centerDone": @(cd), @"center": @(MIN(_center, kNeedCenter)), @"dx": @(qx), @"dy": @(qy), @"dbg": [NSString stringWithFormat:@"%@  c%d  s%@  off %.2f,%.2f", havePose ? @"landmarks" : @"fallback", _center, [cnt componentsJoinedByString:@""], qx, qy]}];
        if (cd && (full >= 7 || (now - _startTS > 55 && full >= 5))) [self finalizeEnroll];
        return;
    }

    VNFeaturePrintObservation *fp = [self printFor:pb face:f.boundingBox];
    if (!fp) return;
    float best = FLT_MAX;
    for (VNFeaturePrintObservation *p in _db[@"prints"]) {
        float d; if ([fp computeDistance:&d toFeaturePrintObservation:p error:nil]) best = MIN(best, d);
    }
    [self report:@{@"best": @(best), @"limit": @(PFLimit(_db)), @"face": @YES}];
}

- (void)finalizeEnroll {
    NSInteger n = _got.count; float worst = 0;
    for (NSInteger i = 0; i < n; i++) {
        float mn = FLT_MAX;
        for (NSInteger j = 0; j < n; j++) {
            if ([_bins[i] intValue] == [_bins[j] intValue]) continue;
            float d; if ([_got[i] computeDistance:&d toFeaturePrintObservation:_got[j] error:nil]) mn = MIN(mn, d);
        }
        if (mn < FLT_MAX) worst = MAX(worst, mn);
    }
    float th = worst * 1.25f;
    NSDictionary *db = @{@"prints": [_got copy], @"th": @(th), @"base": @(worst)};
    NSData *dat = [NSKeyedArchiver archivedDataWithRootObject:db requiringSecureCoding:YES error:nil];
    if (!dat || ![dat writeToFile:PFDBPath() atomically:YES]) { [self finish:NO info:@"could not save face data"]; return; }
    chmod(PFDBPath().fileSystemRepresentation, 0600);
    [self finish:YES info:[NSString stringWithFormat:@"%ld samples", (long)n]];
}
@end

#pragma mark - UI

@interface PFVC : UIViewController
- (void)startMode:(int)mode;
- (BOOL)isRunning;
- (void)abortIfRunning;
@end

@implementation PFVC {
    PFScan *_scan; UIView *_circle; AVCaptureVideoPreviewLayer *_pl;
    NSMutableArray<CAShapeLayer *> *_ticks; CAShapeLayer *_dot; int _tickSector[24], _pulseTarget;
    UILabel *_title, *_hint, *_sub, *_ver; UIButton *_btn;
    int _mode; BOOL _running, _finished;
}
- (BOOL)isRunning { return _running && !_finished; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (UILabel *)label:(CGRect)f size:(CGFloat)s weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = [UIFont systemFontOfSize:s weight:w]; l.textColor = c;
    l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0;
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIView *v = self.view;
    v.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1];
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat W = b.size.width, H = b.size.height;

    _title = [self label:CGRectMake(0, H * 0.07, W, 34) size:28 weight:UIFontWeightSemibold color:UIColor.whiteColor];
    _title.text = @"PhotoFace";
    [v addSubview:_title];

    CGFloat d = MIN(W * 0.62, 260), cx = W / 2, cy = H * 0.34;
    _circle = [[UIView alloc] initWithFrame:CGRectMake(cx - d / 2, cy - d / 2, d, d)];
    _circle.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
    _circle.layer.cornerRadius = d / 2; _circle.layer.masksToBounds = YES;
    [v addSubview:_circle];

    _ticks = [NSMutableArray new];
    for (int i = 0; i < 24; i++) {
        CGFloat a = -M_PI_2 + i * 2 * M_PI / 24, r1 = d / 2 + 8, r2 = d / 2 + 26;
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(cx + r1 * cos(a), cy + r1 * sin(a))];
        [p addLineToPoint:CGPointMake(cx + r2 * cos(a), cy + r2 * sin(a))];
        CAShapeLayer *l = [CAShapeLayer layer];
        l.path = p.CGPath; l.lineWidth = 7; l.lineCap = kCALineCapRound;
        l.strokeColor = PFDim().CGColor;
        [v.layer addSublayer:l]; [_ticks addObject:l];
        float th = (90.f - 15.f * i) * (float)M_PI / 180.f;   // screen direction of this tick, counter-clockwise from "right"
        _tickSector[i] = ((int)lroundf(th / (float)(M_PI / 4)) % 8 + 8) % 8;
    }
    _pulseTarget = -2;
    _dot = [CAShapeLayer layer];
    _dot.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-9, -9, 18, 18)].CGPath;
    _dot.fillColor = UIColor.whiteColor.CGColor;
    _dot.shadowColor = UIColor.blackColor.CGColor; _dot.shadowOpacity = 0.6; _dot.shadowRadius = 3; _dot.shadowOffset = CGSizeZero;
    _dot.zPosition = 10; _dot.hidden = YES;
    [_circle.layer addSublayer:_dot];

    CGFloat hy = cy + d / 2 + 48;
    _hint = [self label:CGRectMake(24, hy, W - 48, 64) size:20 weight:UIFontWeightMedium color:UIColor.whiteColor];
    _hint.text = @"Open Settings → PhotoFace\nto set up your face";
    [v addSubview:_hint];
    _sub = [self label:CGRectMake(28, hy + 70, W - 56, 60) size:14 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1]];
    _sub.text = @"";
    [v addSubview:_sub];

    _btn = [UIButton buttonWithType:UIButtonTypeSystem];
    _btn.frame = CGRectMake(W / 2 - 90, H - 80, 180, 46);
    _btn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    [_btn setTitle:@"Close" forState:UIControlStateNormal];
    [_btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [_btn addTarget:self action:@selector(tapMain) forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:_btn];
    _ver = [self label:CGRectMake(0, H - 24, W, 16) size:10 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.4 alpha:1]];
    _ver.text = @"PhotoFace Enroll build 0.4.0";
    [v addSubview:_ver];
}

- (void)lightTicks:(int)n color:(UIColor *)c {
    for (int i = 0; i < (int)_ticks.count; i++)
        _ticks[i].strokeColor = (i < n ? c : PFDim()).CGColor;
}

- (void)attachPreview {
    AVCaptureSession *s = _scan.session;
    if (!s) return;
    if (_pl) { if (_pl.session != s) _pl.session = s; return; }
    _pl = [AVCaptureVideoPreviewLayer layerWithSession:s];
    _pl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _pl.frame = _circle.bounds;
    if (_pl.connection.isVideoOrientationSupported) _pl.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    [_circle.layer addSublayer:_pl];
}

- (void)startMode:(int)mode {
    PFLog(@"startMode %d begin", mode);
    if ([self isRunning]) return;
    _mode = mode; _running = YES; _finished = NO;
    [_pl removeFromSuperlayer]; _pl = nil;
    _hint.textColor = UIColor.whiteColor;
    _title.text = (mode == 2) ? @"Face Setup" : @"Test Recognition";
    _hint.text = (mode == 2) ? @"Position your face in the circle\nand look straight ahead" : @"Look at the camera";
    _sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _sub.textAlignment = NSTextAlignmentCenter;
    _sub.frame = CGRectMake(28, _hint.frame.origin.y + 70, self.view.bounds.size.width - 56, 60);
    _sub.text = (mode == 2) ? @"Use good, even lighting and keep only your face in view. Hold the phone at eye level."
                            : @"Shows how close the live match is to your enrolled face. Lower is closer.";
    [_btn setTitle:@"Cancel" forState:UIControlStateNormal];
    [_btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self lightTicks:0 color:PFGreen()];
    _pulseTarget = -2; _dot.hidden = YES; _circle.layer.borderWidth = 0;

    _scan = [PFScan new];
    __weak PFVC *ws = self;
    _scan.progress = ^(NSDictionary *i) { [ws update:i]; };
    [_scan start:mode timeout:(mode == 2 ? 75 : 90) done:^(BOOL ok, NSString *info) { [ws finished:ok info:info]; }];
    PFLog(@"startMode: scan started, attaching preview");
    [self attachPreview];
    // the session can be rebuilt on a retry; keep the preview attached
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        PFVC *s = ws; if (!s || !s->_running || s->_finished) { [t invalidate]; return; }
        [s attachPreview];
    }];
}

- (void)applyRing:(NSArray *)cnt target:(int)tgt centerDone:(BOOL)cd center:(int)center {
    int per[8] = {0}, idx[24];
    for (int i = 0; i < 24; i++) idx[i] = per[_tickSector[i]]++;
    if (tgt != _pulseTarget) { for (CAShapeLayer *l in _ticks) [l removeAllAnimations]; _pulseTarget = tgt; }
    for (int i = 0; i < 24; i++) {
        CAShapeLayer *l = _ticks[i];
        if (!cd) {
            // step 1: the whole ring fills green, clockwise from the top, while you hold still
            int lit = (int)ceilf(24.f * center / (float)kNeedCenter);
            l.strokeColor = (i < lit ? PFGreen() : PFDim()).CGColor;
            [l removeAnimationForKey:@"pulse"];
            continue;
        }
        int sct = _tickSector[i], c = MIN([cnt[sct] intValue], kNeedPer);
        int filled = (int)ceilf(per[sct] * c / (float)kNeedPer);
        if (idx[i] < filled) { l.strokeColor = PFGreen().CGColor; [l removeAnimationForKey:@"pulse"]; }
        else if (sct == tgt) {
            // the part of the ring to head toward: bright green, pulsing
            l.strokeColor = [UIColor colorWithRed:0.45 green:1 blue:0.6 alpha:1].CGColor;
            if (![l animationForKey:@"pulse"]) {
                CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
                a.fromValue = @1; a.toValue = @0.2; a.duration = 0.5; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
                [l addAnimation:a forKey:@"pulse"];
            }
        } else { l.strokeColor = PFDim().CGColor; [l removeAnimationForKey:@"pulse"]; }
    }
    _circle.layer.borderWidth = 3;
    _circle.layer.borderColor = (cd ? PFGreen() : PFDim()).CGColor;
}

- (void)update:(NSDictionary *)i {
    if (_finished) return;
    [self attachPreview];
    if (_mode == 2) {
        if (i[@"sectors"]) [self applyRing:i[@"sectors"] target:[i[@"target"] intValue] centerDone:[i[@"centerDone"] boolValue] center:[i[@"center"] intValue]];
        if (i[@"hint"]) _hint.text = i[@"hint"];
        if (i[@"sub"]) _sub.text = i[@"sub"];
        if (i[@"dbg"]) _ver.text = [NSString stringWithFormat:@"build 0.4.0  ·  %@", i[@"dbg"]];
        if ([i[@"face"] boolValue] && i[@"dx"]) {   // live "where is my head pointing" dot
            CGFloat R = _circle.bounds.size.width / 2, k = R / 0.22;
            CGFloat x = [i[@"dx"] floatValue] * k, y = -[i[@"dy"] floatValue] * k, m = hypot(x, y), lim = R * 0.82;
            if (m > lim) { x *= lim / m; y *= lim / m; }
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            _dot.position = CGPointMake(R + x, R + y); _dot.hidden = NO;
            [CATransaction commit];
        } else _dot.hidden = YES;
    } else {
        if (i[@"best"]) {
            float best = [i[@"best"] floatValue], lim = [i[@"limit"] floatValue];
            BOOL ok = best < lim;
            [self lightTicks:ok ? 24 : 0 color:PFGreen()];
            _hint.text = [NSString stringWithFormat:@"Match %.2f   (needs below %.2f)\n%@", best, lim, ok ? @"✓ Recognised" : @"✗ Not recognised"];
        } else if (i[@"hint"]) { _hint.text = i[@"hint"]; [self lightTicks:0 color:PFGreen()]; }
    }
}

- (void)finished:(BOOL)ok info:(NSString *)info {
    _finished = YES; _dot.hidden = YES;
    for (CAShapeLayer *l in _ticks) [l removeAllAnimations];
    BOOL cancelled = [info isEqualToString:@"cancelled"];
    if (_mode == 2) {
        if (ok) PFWriteStatus([@"ok: " stringByAppendingString:info]);
        else if (cancelled) PFWriteStatus(@"cancel");
        else PFWriteStatus([@"fail: " stringByAppendingString:info]);
    }
    notify_post("com.photoface.enrolldone");
    if (cancelled) { [self leave]; return; }
    if (ok && _mode == 2) {
        [self lightTicks:24 color:PFGreen()];
        _hint.text = @"Setup complete";
        _hint.textColor = PFGreen();
        _sub.text = @"Lock your phone, then wake it while looking at the screen. After a restart you still enter your passcode once.";
        [_btn setTitle:@"Done" forState:UIControlStateNormal];
        [_btn setTitleColor:PFGreen() forState:UIControlStateNormal];
    } else if (ok) {
        [self leave];
    } else {
        [self lightTicks:0 color:PFGreen()];
        _hint.text = (_mode == 2) ? @"Setup didn't finish" : @"Test couldn't run";
        _hint.textColor = [UIColor colorWithRed:1 green:0.35 blue:0.3 alpha:1];
        _sub.text = [NSString stringWithFormat:@"Reason: %@", info];
        [_btn setTitle:@"Close" forState:UIControlStateNormal];
    }
}

- (void)abortIfRunning { if ([self isRunning]) [_scan cancel]; }
- (void)tapMain { if ([self isRunning]) [_scan cancel]; else [self leave]; }

// go back to the Home Screen and drop the process so the camera is released
- (void)leave {
    PFLog(@"leave: going home and exiting");
    _running = NO;
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
