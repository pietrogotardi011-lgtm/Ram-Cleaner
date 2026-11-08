// PhotoFace - on-device 2D face unlock for SpringBoard (iOS 15, rootful)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <Security/Security.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <float.h>
#import <math.h>
#import <sys/stat.h>

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUIUnlocked;
- (void)_attemptUnlockWithPasscode:(NSString *)p mesa:(BOOL)m finishUIUnlock:(BOOL)f completion:(id)c;
- (void)attemptUnlockWithPasscode:(NSString *)p finishUIUnlock:(BOOL)f completion:(id)c;
- (BOOL)attemptUnlockWithPasscode:(NSString *)p;
@end
@interface SBBacklightController : NSObject
- (void)turnOnScreenFullyWithBacklightSource:(long long)source;
@end
@interface SpringBoard : UIApplication
- (void)_simulateHomeButtonPress;
@end

static NSString *const kDir = @"/var/mobile/Library/PhotoFace";
static NSString *const kService = @"com.photoface.passcode";
static CFStringRef const kPrefDom = CFSTR("com.photoface.tweak");
static int gFails = 0;
static NSString *gPendingPW = nil;

#pragma mark - helpers

static id PFPrefGet(NSString *k) {
    CFPreferencesAppSynchronize(kPrefDom);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k, kPrefDom));
}
static void PFPrefSet(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, kPrefDom);
    CFPreferencesAppSynchronize(kPrefDom);
}
static NSString *PFDBPath(void) { return [kDir stringByAppendingPathComponent:@"db.bin"]; }
static void PFRefreshStatus(void) {
    PFPrefSet(@"status", [[NSFileManager defaultManager] fileExistsAtPath:PFDBPath()] ? @"Enrolled" : @"Not enrolled");
}
static void PFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PFLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *p = [kDir stringByAppendingPathComponent:@"log.txt"];
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if ([at fileSize] > 200000) [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}
static NSDictionary *PFQ(void) {
    return @{(id)kSecClass: (id)kSecClassGenericPassword,
             (id)kSecAttrService: kService, (id)kSecAttrAccount: @"pw"};
}
static void PFSavePW(NSString *pw) {
    SecItemDelete((__bridge CFDictionaryRef)PFQ());
    NSMutableDictionary *d = [PFQ() mutableCopy];
    d[(id)kSecValueData] = [pw dataUsingEncoding:NSUTF8StringEncoding];
    d[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)d, NULL);
}
static NSString *PFLoadPW(void) {
    NSMutableDictionary *q = [PFQ() mutableCopy];
    q[(id)kSecReturnData] = @YES;
    CFTypeRef r = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &r) != errSecSuccess) return nil;
    NSData *d = (__bridge_transfer NSData *)r;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}
static void PFStatus(NSString *s) {   // status file for the pfenroll CLI
    NSString *p = [kDir stringByAppendingPathComponent:@"status.txt"];
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(p.fileSystemRepresentation, 0644);
}
static NSDictionary *PFLoadDB(void) {
    NSData *d = [NSData dataWithContentsOfFile:PFDBPath()];
    if (!d) return nil;
    NSSet *cls = [NSSet setWithObjects:NSDictionary.class, NSArray.class, NSNumber.class,
                  VNFeaturePrintObservation.class, nil];
    return [NSKeyedUnarchiver unarchivedObjectOfClasses:cls fromData:d error:nil];
}
static float PFLimit(NSDictionary *db) {
    float base = db[@"base"] ? [db[@"base"] floatValue] : [db[@"th"] floatValue] / 1.25f;
    id tv = PFPrefGet(@"tolerance");
    float tol = tv ? [tv floatValue] : 1.25f;
    if (tol < 1.0f || tol > 2.0f) tol = 1.25f;
    return base * tol;
}

#pragma mark - scanner

@interface PFScanner : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (atomic) int mode; // 0 idle, 1 verify, 2 enroll, 3 test
@property (nonatomic, readonly) AVCaptureSession *session;
@property (nonatomic, copy) void (^progress)(NSDictionary *info);
+ (instancetype)shared;
- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done;
- (void)cancel;
@end

@implementation PFScanner {
    AVCaptureSession *_s; dispatch_queue_t _q; CIContext *_ci; NSTimer *_wd;
    NSTimeInterval _startTS, _deadlineTS, _lastFrameTS, _lastProc, _lastGain;
    int _frames, _hits, _center, _secCount[8];
    NSMutableArray *_got; NSMutableArray<NSNumber *> *_bins;
    NSDictionary *_db; void (^_done)(BOOL, NSString *);
    NSString *_interrupt; BOOL _observing;
}
@synthesize session = _s;

+ (instancetype)shared {
    static PFScanner *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [PFScanner new];
        i->_q = dispatch_queue_create("photoface.cam", DISPATCH_QUEUE_SERIAL);
        i->_ci = [CIContext contextWithOptions:nil]; });
    return i;
}

- (NSString *)build {
    if (_s) return nil;
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                            mediaType:AVMediaTypeVideo
                                                             position:AVCaptureDevicePositionFront];
    if (!d) return @"no front camera found";
    NSError *e = nil;
    AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:d error:&e];
    if (!in) return [NSString stringWithFormat:@"can't open the camera (%@)", e.localizedDescription ?: @"unknown"];
    AVCaptureSession *s = [AVCaptureSession new];
    if ([s canSetSessionPreset:AVCaptureSessionPreset640x480]) s.sessionPreset = AVCaptureSessionPreset640x480;
    if (![s canAddInput:in]) return @"can't add camera input";
    [s addInput:in];
    AVCaptureVideoDataOutput *o = [AVCaptureVideoDataOutput new];
    o.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    o.alwaysDiscardsLateVideoFrames = YES;
    [o setSampleBufferDelegate:self queue:_q];
    if (![s canAddOutput:o]) return @"can't add camera output";
    [s addOutput:o];
    AVCaptureConnection *c = [o connectionWithMediaType:AVMediaTypeVideo];
    if (c.isVideoOrientationSupported) c.videoOrientation = AVCaptureVideoOrientationPortrait;
    _s = s;
    __weak PFScanner *ws = self;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:AVCaptureSessionRuntimeErrorNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        NSError *er = n.userInfo[AVCaptureSessionErrorKey];
        ws->_interrupt = er.localizedDescription ?: @"camera runtime error";
        PFLog(@"runtime error: %@", er);
    }];
    [nc addObserverForName:AVCaptureSessionWasInterruptedNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        long r = [n.userInfo[AVCaptureSessionInterruptionReasonKey] longValue];
        ws->_interrupt = [NSString stringWithFormat:@"camera interrupted (reason %ld)", r];
        PFLog(@"interrupted reason=%ld", r);
    }];
    [nc addObserverForName:AVCaptureSessionInterruptionEndedNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        ws->_interrupt = nil;
    }];
    return nil;
}

- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done {
    if (self.mode) { done(NO, @"busy"); return; }
    if (mode == 1 || mode == 3) {
        _db = PFLoadDB();
        if (!_db) { done(NO, @"no face enrolled yet"); return; }
    }
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    PFLog(@"start mode=%d camera-auth=%ld", mode, (long)st);
    if (st == AVAuthorizationStatusDenied || st == AVAuthorizationStatusRestricted) {
        done(NO, @"camera access is denied for SpringBoard"); return;
    }
    if (st == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL g) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g) [self start:mode timeout:t done:done]; else done(NO, @"camera permission was not granted");
            });
        }];
        return;
    }
    _done = [done copy]; _hits = 0; _center = 0; memset(_secCount, 0, sizeof _secCount);
    _got = [NSMutableArray new]; _bins = [NSMutableArray new];
    _frames = 0; _interrupt = nil; _lastProc = 0;
    _startTS = CACurrentMediaTime(); _lastFrameTS = _startTS; _lastGain = _startTS;
    _deadlineTS = _startTS + t;
    NSString *err = [self build];
    self.mode = mode;
    if (err) { [self finish:NO info:err]; return; }
    dispatch_async(_q, ^{ [self->_s startRunning]; });
    [_wd invalidate];
    _wd = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)tick {
    if (!self.mode) return;
    NSTimeInterval n = CACurrentMediaTime();
    if (_frames == 0 && n - _startTS > 5) {
        [self finish:NO info:[NSString stringWithFormat:@"the camera isn't delivering frames%@",
                              _interrupt ? [NSString stringWithFormat:@" (%@)", _interrupt] : @""]];
        return;
    }
    if (_frames > 0 && n - _lastFrameTS > 3) {
        [self finish:NO info:[NSString stringWithFormat:@"the camera stopped%@",
                              _interrupt ? [NSString stringWithFormat:@" (%@)", _interrupt] : @""]];
        return;
    }
    if (n > _deadlineTS) {
        if (self.mode == 3) [self finish:YES info:@"test ended"];
        else [self finish:NO info:self.mode == 2 ? @"setup timed out before enough face angles were captured" : @"timeout"];
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [s stopRunning]; });
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

- (VNFeaturePrintObservation *)printFor:(CIImage *)img face:(CGRect)box {
    CGRect r = VNImageRectForNormalizedRect(box, img.extent.size.width, img.extent.size.height);
    CGFloat side = MAX(r.size.width, r.size.height) * 1.3;
    CGRect sq = CGRectMake(CGRectGetMidX(r) - side / 2, CGRectGetMidY(r) - side / 2, side, side);
    sq = CGRectIntersection(sq, img.extent);
    CGImageRef cg = [_ci createCGImage:img fromRect:sq];
    if (!cg) return nil;
    VNGenerateImageFeaturePrintRequest *pr = [VNGenerateImageFeaturePrintRequest new];
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    BOOL ok = [h performRequests:@[pr] error:nil];
    CGImageRelease(cg);
    return ok ? (VNFeaturePrintObservation *)pr.results.firstObject : nil;
}

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)c {
    NSTimeInterval now = CACurrentMediaTime();
    _frames++; _lastFrameTS = now;
    int mode = self.mode;
    if (!mode) return;
    if (now - _lastProc < (mode == 1 ? 0.2 : 0.15)) return;
    _lastProc = now;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;

    VNDetectFaceRectanglesRequest *fr = [VNDetectFaceRectanglesRequest new];
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
    if (![h performRequests:@[fr] error:nil]) return;
    NSArray *faces = fr.results;
    NSString *hint = nil; VNFaceObservation *f = nil;
    if (faces.count == 0) hint = @"Can't see your face.\nLook at the front camera.";
    else if (faces.count > 1) hint = @"Only one face in view, please.";
    else { f = faces[0]; if (f.boundingBox.size.width < 0.3) hint = @"Move a little closer."; }
    if (hint) { _hits = 0; [self report:@{@"hint": hint, @"face": @NO}]; return; }

    CIImage *img = [CIImage imageWithCVPixelBuffer:pb];

    if (mode == 2) {
        float yaw = NAN, pitch = NAN;
        if (f.yaw) yaw = f.yaw.floatValue;
        if (@available(iOS 15.0, *)) { if (f.pitch) pitch = f.pitch.floatValue; }
        int bin;
        if (isnan(yaw) || isnan(pitch)) bin = (_center < 4) ? -1 : (int)(_got.count % 8);
        else {
            float mag = hypotf(yaw, pitch);
            if (mag < 0.15f) bin = -1;
            else bin = ((int)lroundf(atan2f(pitch, yaw) / (float)(M_PI / 4)) + 8) % 8;
        }
        BOOL need = (bin == -1) ? (_center < 4) : (_secCount[bin] < 2);
        if (need) {
            VNFeaturePrintObservation *fp = [self printFor:img face:f.boundingBox];
            if (fp) {
                [_got addObject:fp]; [_bins addObject:@(bin)];
                if (bin == -1) _center++; else _secCount[bin]++;
                _lastGain = now;
            }
        }
        int secUnits = 0; for (int k = 0; k < 8; k++) secUnits += MIN(_secCount[k], 2);
        NSString *msg;
        if (_center < 4) msg = @"Position your face in the circle\nand look straight ahead";
        else if (secUnits < 12) msg = (now - _lastGain > 6) ? @"Keep going: tilt your head further\nup, down, left and right"
                                                           : @"Now slowly move your head\nin a circle";
        else msg = @"Almost done…";
        [self report:@{@"hint": msg, @"face": @YES}];
        if (_center >= 4 && secUnits >= 12) [self finalizeEnroll];
        return;
    }

    VNFeaturePrintObservation *fp = [self printFor:img face:f.boundingBox];
    if (!fp) return;
    float best = FLT_MAX;
    for (VNFeaturePrintObservation *p in _db[@"prints"]) {
        float d; if ([fp computeDistance:&d toFeaturePrintObservation:p error:nil]) best = MIN(best, d);
    }
    float limit = PFLimit(_db);
    if (mode == 3) { [self report:@{@"best": @(best), @"limit": @(limit), @"face": @YES}]; return; }
    _hits = (best < limit) ? _hits + 1 : 0;
    if (_hits >= 3) [self finish:YES info:[NSString stringWithFormat:@"match %.2f", best]];
}

- (void)finalizeEnroll {
    NSInteger n = _got.count; float worst = 0;
    for (NSInteger i = 0; i < n; i++) {
        float mn = FLT_MAX;
        for (NSInteger j = 0; j < n; j++) {
            if ([_bins[i] intValue] == [_bins[j] intValue]) continue; // compare against other poses
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

#pragma mark - setup UI (shown in SpringBoard, like Face ID setup)

@interface PFSetup : NSObject
+ (instancetype)shared;
+ (void)begin:(int)mode;
@end

@implementation PFSetup {
    UIWindow *_w; UIView *_circle; AVCaptureVideoPreviewLayer *_pl;
    NSMutableArray<CAShapeLayer *> *_ticks;
    UILabel *_hint, *_sub; UIButton *_btn, *_retry;
    int _mode; BOOL _finished;
}
+ (instancetype)shared { static PFSetup *i; static dispatch_once_t o; dispatch_once(&o, ^{ i = [PFSetup new]; }); return i; }

+ (void)begin:(int)mode {
    id app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(_simulateHomeButtonPress)]) [(SpringBoard *)app _simulateHomeButtonPress];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [[PFSetup shared] present:mode];
    });
}

static UIColor *PFGreen(void) { return [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1]; }

- (UILabel *)label:(CGRect)f size:(CGFloat)s weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = [UIFont systemFontOfSize:s weight:w]; l.textColor = c;
    l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0;
    return l;
}

- (void)present:(int)mode {
    if (_w) return;
    _mode = mode; _finished = NO;
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat W = b.size.width, H = b.size.height;
    _w = [[UIWindow alloc] initWithFrame:b];
    _w.windowLevel = 10000;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1];
    _w.rootViewController = vc;
    UIView *v = vc.view;

    UILabel *title = [self label:CGRectMake(0, H * 0.07, W, 34) size:28 weight:UIFontWeightSemibold color:UIColor.whiteColor];
    title.text = (mode == 2) ? @"Face Setup" : @"Test Recognition";
    [v addSubview:title];

    CGFloat d = MIN(W * 0.62, 260), cx = W / 2, cy = H * 0.34;
    _circle = [[UIView alloc] initWithFrame:CGRectMake(cx - d / 2, cy - d / 2, d, d)];
    _circle.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1];
    _circle.layer.cornerRadius = d / 2; _circle.layer.masksToBounds = YES;
    [v addSubview:_circle];

    _ticks = [NSMutableArray new];
    for (int i = 0; i < 24; i++) {
        CGFloat a = -M_PI_2 + i * 2 * M_PI / 24, r1 = d / 2 + 10, r2 = d / 2 + 22;
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(cx + r1 * cos(a), cy + r1 * sin(a))];
        [p addLineToPoint:CGPointMake(cx + r2 * cos(a), cy + r2 * sin(a))];
        CAShapeLayer *l = [CAShapeLayer layer];
        l.path = p.CGPath; l.lineWidth = 4; l.lineCap = kCALineCapRound;
        l.strokeColor = [UIColor colorWithWhite:0.25 alpha:1].CGColor;
        [v.layer addSublayer:l]; [_ticks addObject:l];
    }

    CGFloat hy = cy + d / 2 + 48;
    _hint = [self label:CGRectMake(24, hy, W - 48, 64) size:20 weight:UIFontWeightMedium color:UIColor.whiteColor];
    _hint.text = (mode == 2) ? @"Position your face in the circle\nand look straight ahead" : @"Look at the camera";
    [v addSubview:_hint];
    _sub = [self label:CGRectMake(28, hy + 70, W - 56, 60) size:14 weight:UIFontWeightRegular color:[UIColor colorWithWhite:0.6 alpha:1]];
    _sub.text = (mode == 2) ? @"Use good, even lighting and keep only your face in view. Hold the phone at eye level."
                            : @"Shows how close the live match is to your enrolled face. Lower is closer.";
    [v addSubview:_sub];

    _btn = [UIButton buttonWithType:UIButtonTypeSystem];
    _btn.frame = CGRectMake(W / 2 - 90, H - 80, 180, 46);
    _btn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    [_btn setTitle:@"Cancel" forState:UIControlStateNormal];
    [_btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [_btn addTarget:self action:@selector(tapMain) forControlEvents:UIControlEventTouchUpInside];
    [v addSubview:_btn];
    _retry = [UIButton buttonWithType:UIButtonTypeSystem];
    _retry.frame = CGRectMake(W / 2 - 90, H - 130, 180, 46);
    _retry.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [_retry setTitle:@"Try Again" forState:UIControlStateNormal];
    [_retry setTitleColor:PFGreen() forState:UIControlStateNormal];
    [_retry addTarget:self action:@selector(tapRetry) forControlEvents:UIControlEventTouchUpInside];
    _retry.hidden = YES;
    [v addSubview:_retry];

    _w.hidden = NO;

    PFScanner *sc = [PFScanner shared];
    __weak PFSetup *ws = self;
    sc.progress = ^(NSDictionary *i) { [ws update:i]; };
    [sc start:mode timeout:(mode == 2 ? 75 : 90) done:^(BOOL ok, NSString *info) { [ws finished:ok info:info]; }];
    [self addPreviewIfNeeded];
}

- (void)addPreviewIfNeeded {
    AVCaptureSession *s = [PFScanner shared].session;
    if (_pl || !s || !_circle) return;
    _pl = [AVCaptureVideoPreviewLayer layerWithSession:s];
    _pl.videoGravity = AVLayerVideoGravityResizeAspectFill;
    _pl.frame = _circle.bounds;
    if (_pl.connection.isVideoOrientationSupported) _pl.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    [_circle.layer addSublayer:_pl];
}

- (void)lightTicks:(int)n color:(UIColor *)c {
    for (int i = 0; i < (int)_ticks.count; i++)
        _ticks[i].strokeColor = (i < n ? c : [UIColor colorWithWhite:0.25 alpha:1]).CGColor;
}

- (void)update:(NSDictionary *)i {
    [self addPreviewIfNeeded];
    if (_finished || !_w) return;
    if (_mode == 2) {
        float u = [i[@"units"] floatValue];
        [self lightTicks:(int)floorf(24.f * u / 16.f) color:PFGreen()];
        if (i[@"hint"]) _hint.text = i[@"hint"];
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
    _finished = YES;
    BOOL cancelled = [info isEqualToString:@"cancelled"];
    if (_mode == 2) {
        if (ok) {
            if (gPendingPW) PFSavePW(gPendingPW);
            gPendingPW = nil; gFails = 0;
            PFStatus([@"ok: " stringByAppendingString:info]);
            PFPrefSet(@"status", [NSString stringWithFormat:@"Enrolled (%@)", info]);
        } else if (cancelled) {
            PFRefreshStatus();
        } else {
            PFStatus([@"fail: " stringByAppendingString:info]);
            PFPrefSet(@"status", [@"Failed: " stringByAppendingString:info]);
        }
    }
    if (cancelled || (_mode == 3 && ok)) { [self close]; return; }
    if (ok) {
        [self lightTicks:24 color:PFGreen()];
        _hint.text = @"Setup complete";
        _hint.textColor = PFGreen();
        _sub.text = @"Lock your phone, then wake it while looking at the screen. After a restart you still enter your passcode once.";
        [_btn setTitle:@"Done" forState:UIControlStateNormal];
        [_btn setTitleColor:PFGreen() forState:UIControlStateNormal];
    } else {
        [self lightTicks:0 color:PFGreen()];
        _hint.text = (_mode == 2) ? @"Setup didn't finish" : @"Test couldn't run";
        _hint.textColor = [UIColor colorWithRed:1 green:0.35 blue:0.3 alpha:1];
        _sub.text = [NSString stringWithFormat:@"Reason: %@", info];
        [_btn setTitle:@"Close" forState:UIControlStateNormal];
        _retry.hidden = (_mode != 2) || !gPendingPW;
    }
}

- (void)tapMain {
    if (!_finished) [[PFScanner shared] cancel]; else [self close];
}
- (void)tapRetry {
    int m = _mode;
    [self teardown];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self present:m]; });
}
- (void)teardown {
    [PFScanner shared].progress = nil;
    [_pl removeFromSuperlayer]; _pl = nil;
    _w.hidden = YES; _w = nil; _ticks = nil; _circle = nil;
}
- (void)close {
    [self teardown];
    gPendingPW = nil;
}
@end

#pragma mark - unlock logic

static void PFUnlock(NSString *pw) {
    SBLockScreenManager *m = [%c(SBLockScreenManager) sharedInstance];
    if ([m respondsToSelector:@selector(_attemptUnlockWithPasscode:mesa:finishUIUnlock:completion:)])
        [m _attemptUnlockWithPasscode:pw mesa:NO finishUIUnlock:YES completion:nil];
    else if ([m respondsToSelector:@selector(attemptUnlockWithPasscode:finishUIUnlock:completion:)])
        [m attemptUnlockWithPasscode:pw finishUIUnlock:YES completion:nil];
    else if ([m respondsToSelector:@selector(attemptUnlockWithPasscode:)])
        [m attemptUnlockWithPasscode:pw];
}

static void PFWake(void) {
    SBLockScreenManager *m = [%c(SBLockScreenManager) sharedInstance];
    if ([m isUIUnlocked]) { gFails = 0; return; }
    id en = PFPrefGet(@"enabled");
    if (en && ![en boolValue]) return;      // master switch
    if (gFails >= 3) return;
    NSString *pw = PFLoadPW(); // nil before first unlock after boot -> passcode required, like Touch ID
    if (!pw || ![[NSFileManager defaultManager] fileExistsAtPath:PFDBPath()]) return;
    [[PFScanner shared] start:1 timeout:6 done:^(BOOL ok, NSString *i) {
        if (!ok || [m isUIUnlocked]) return;
        PFUnlock(pw);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (![m isUIUnlocked]) gFails++;
        });
    }];
}

%hook SBBacklightController
- (void)turnOnScreenFullyWithBacklightSource:(long long)source {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ PFWake(); });
}
%end

%ctor {
    @autoreleasepool {
        static int t1, t2, t3;
        notify_register_dispatch("com.photoface.enroll", &t1, dispatch_get_main_queue(), ^(int t) {
            NSString *p = [kDir stringByAppendingPathComponent:@"passcode.tmp"];
            NSString *pw = PFPrefGet(@"pendingPasscode");
            PFPrefSet(@"pendingPasscode", nil);
            if (!pw.length) pw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
            if (!pw.length) {
                PFStatus(@"fail: no passcode received");
                PFPrefSet(@"status", @"Failed: no passcode received");
                return;
            }
            PFLog(@"enroll requested");
            gPendingPW = pw;
            PFPrefSet(@"status", @"Setup in progress");
            [PFSetup begin:2];
        });
        notify_register_dispatch("com.photoface.test", &t2, dispatch_get_main_queue(), ^(int t) {
            PFLog(@"test requested");
            [PFSetup begin:3];
        });
        notify_register_dispatch("com.photoface.clear", &t3, dispatch_get_main_queue(), ^(int t) {
            [[NSFileManager defaultManager] removeItemAtPath:PFDBPath() error:nil];
            SecItemDelete((__bridge CFDictionaryRef)PFQ());
            PFPrefSet(@"status", @"Not enrolled");
        });
        PFPrefSet(@"pendingPasscode", nil);
        PFRefreshStatus();
        PFLog(@"PhotoFace loaded in SpringBoard");
    }
}
