// PhotoFace Enroll - a tiny real app so the camera daemon sees a genuine foreground client.
// SpringBoard launches it (see Tweak.x, PFSetup begin:), it captures the face, writes db.bin and
// status.txt into /var/mobile/Library/PhotoFace and posts com.photoface.enrolldone.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
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
    AVCaptureSession *_s; dispatch_queue_t _q, _cfg; CIContext *_ci; NSTimer *_wd;
    NSTimeInterval _startTS, _deadlineTS, _lastFrameTS, _lastProc, _lastGain;
    int _frames, _center, _secCount[8], _retries;
    NSMutableArray *_got; NSMutableArray<NSNumber *> *_bins;
    NSDictionary *_db; void (^_done)(BOOL, NSString *);
    NSString *_interrupt; NSMutableArray *_obs;
}
@synthesize session = _s;

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _q = dispatch_queue_create("photoface.app.cam", DISPATCH_QUEUE_SERIAL);
    _cfg = dispatch_queue_create("photoface.app.cfg", DISPATCH_QUEUE_SERIAL);
    _ci = [CIContext contextWithOptions:nil];
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

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    NSTimeInterval now = CACurrentMediaTime();
    _frames++; _lastFrameTS = now;
    int mode = self.mode;
    if (!mode) return;
    if (now - _lastProc < 0.15) return;
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
    if (hint) { [self report:@{@"hint": hint, @"face": @NO}]; return; }

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
    NSMutableArray<CAShapeLayer *> *_ticks;
    UILabel *_title, *_hint, *_sub; UIButton *_btn;
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
}

- (void)lightTicks:(int)n color:(UIColor *)c {
    for (int i = 0; i < (int)_ticks.count; i++)
        _ticks[i].strokeColor = (i < n ? c : [UIColor colorWithWhite:0.25 alpha:1]).CGColor;
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

- (void)update:(NSDictionary *)i {
    if (_finished) return;
    [self attachPreview];
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
