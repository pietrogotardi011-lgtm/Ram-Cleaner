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
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <dlfcn.h>

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUIUnlocked;
- (BOOL)isUILocked;
- (BOOL)isLockScreenVisible;
- (void)_attemptUnlockWithPasscode:(NSString *)p mesa:(BOOL)m finishUIUnlock:(BOOL)f completion:(id)c;
- (void)attemptUnlockWithPasscode:(NSString *)p finishUIUnlock:(BOOL)f completion:(id)c;
- (BOOL)attemptUnlockWithPasscode:(NSString *)p;
@end
@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)screenIsOn;
- (BOOL)screenIsDim;
- (void)turnOnScreenFullyWithBacklightSource:(long long)source;
@end
@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (void)clickedMenuButton;
@end
@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)terminateApplication:(NSString *)bundleID forReason:(long long)reason andReport:(BOOL)report withDescription:(NSString *)desc;
@end
@interface SpringBoard : UIApplication
- (void)_simulateHomeButtonPress;
@end

static NSString *const kDir = @"/var/mobile/Library/PhotoFace";
static NSString *const kService = @"com.photoface.passcode";
static CFStringRef const kPrefDom = CFSTR("com.photoface.tweak");
static int gFails = 0;
static BOOL PFScreenActive(void);
static BOOL gForceScan = NO;
static NSString *gPendingPW = nil;
static int gEnrollMode = 0, gEnrollGen = 0;   // which scan the Enroll app is running (2 setup / 3 test)
static BOOL gEnrolling = NO;   // setup/test UI is up or being brought up: lock-screen verify must stay out of the way

#pragma mark - helpers

static id PFPrefGet(NSString *k) {
    CFPreferencesAppSynchronize(kPrefDom);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k, kPrefDom));
}
static void PFPrefSet(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, kPrefDom);
    CFPreferencesAppSynchronize(kPrefDom);
}
static CGFloat gIconYPct = 19, gIconXPct = 0;   // icon centre: % of screen height above the bottom, and -100..100 left/right
static BOOL gHideOnPasscode = YES, gEarlyTrigger = YES, gAODSafe = YES;
static int gStartDelayMs = 80, gConfirmFrames = 2;
static void PFLoadIconPos(void) {
    id y = PFPrefGet(@"iconYPct"), x = PFPrefGet(@"iconX"), h = PFPrefGet(@"hideOnPasscode");
    id sd = PFPrefGet(@"startDelay"), cf = PFPrefGet(@"confirmFrames"), et = PFPrefGet(@"earlyTrigger");
    gStartDelayMs = sd ? MAX(0, MIN(600, (int)lroundf([sd floatValue]))) : 80;
    gConfirmFrames = cf ? MAX(1, MIN(4, (int)lroundf([cf floatValue]))) : 2;
    gEarlyTrigger = et ? [et boolValue] : YES;
    id ao = PFPrefGet(@"aodSafe"); gAODSafe = ao ? [ao boolValue] : YES;
    gIconYPct = y ? MAX(0, MIN(100, [y floatValue])) : 19;
    gIconXPct = x ? MAX(-100, MIN(100, [x floatValue])) : 0;
    gHideOnPasscode = h ? [h boolValue] : YES;
}
static CGPoint PFIconCenter(CGSize sz) {
    CGFloat v = gIconXPct; if (fabs(v) < 6) v = 0;               // snap to the middle
    CGFloat cx = sz.width / 2 + v / 100.0 * (sz.width / 2 - 24);
    CGFloat cy = sz.height * (1 - gIconYPct / 100.0);
    cy = MAX(32, MIN(sz.height - 32, cy));                         // always fully on screen
    return CGPointMake(cx, cy);
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
    if (!h) { [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; chmod(p.fileSystemRepresentation, 0600); return; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
    chmod(p.fileSystemRepresentation, 0600);
}

// ---- diagnostics: who is in front, and what camera "background" switches exist ----
static id PFFrontAppObj(void) {
    @try {
        id app = [UIApplication sharedApplication];
        SEL sel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
        if (![app respondsToSelector:sel]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(app, sel);
    } @catch (NSException *e) { return nil; }
}
static NSString *PFFrontAppID(void) {   // nil = nothing in front (home screen / lock screen)
    id fa = PFFrontAppObj();
    if (!fa) return nil;
    id bid = nil;
    @try { bid = [fa valueForKey:@"bundleIdentifier"]; } @catch (...) {}
    if (!bid) { @try { bid = [fa valueForKey:@"displayIdentifier"]; } @catch (...) {} }
    return [bid isKindOfClass:NSString.class] ? bid : @"(unknown app)";
}
static NSString *PFFrontApp(void) {
    id app = [UIApplication sharedApplication];
    if (![app respondsToSelector:NSSelectorFromString(@"_accessibilityFrontMostApplication")]) return @"(selector missing)";
    NSString *b = PFFrontAppID();
    return b ?: @"(none: SpringBoard/home or lock screen)";
}
static void PFLogEnv(const char *tag) {
    UIApplication *app = [UIApplication sharedApplication];
    SBLockScreenManager *lm = [%c(SBLockScreenManager) sharedInstance];
    int locked = -1;
    if ([lm respondsToSelector:@selector(isUILocked)]) locked = [lm isUILocked] ? 1 : 0;
    PFLog(@"env[%s] appState=%ld frontApp=%@ homePressSel=%d locked=%d", tag, (long)app.applicationState, PFFrontApp(),
          (int)[app respondsToSelector:@selector(_simulateHomeButtonPress)], locked);
}
static void PFDumpCameraSwitches(void) {
    const char *names[] = { "AVCaptureSession", "AVCaptureDevice", "AVCaptureDeviceInput", "AVCaptureVideoDataOutput" };
    for (int i = 0; i < 4; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) continue;
        NSMutableArray *hits = [NSMutableArray new];
        for (int meta = 0; meta < 2; meta++) {
            unsigned n = 0;
            Method *ms = class_copyMethodList(meta ? object_getClass(c) : c, &n);
            for (unsigned k = 0; k < n; k++) {
                NSString *nm = NSStringFromSelector(method_getName(ms[k]));
                NSString *l = nm.lowercaseString;
                if ([l containsString:@"background"] || [l containsString:@"foreground"] || [l containsString:@"inuseby"] ||
                    [l containsString:@"suspend"] || [l containsString:@"interrupt"] || [l containsString:@"multitask"])
                    [hits addObject:[NSString stringWithFormat:@"%@%@", meta ? @"+" : @"-", nm]];
            }
            free(ms);
        }
        PFLog(@"camera-api %s: %@", names[i], [hits componentsJoinedByString:@" "]);
    }
}
static NSString *PFGuardPath(void) { return [kDir stringByAppendingPathComponent:@"guard"]; }
static void PFGuardBegin(void) { [@"1" writeToFile:PFGuardPath() atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
static void PFGuardEnd(void) { [[NSFileManager defaultManager] removeItemAtPath:PFGuardPath() error:nil]; }

// _simulateHomeButtonPress does not exist on iOS 15 (log showed homePressSel=0), so Settings never left the front.
static BOOL PFGoHome(void) {
    UIApplication *app = [UIApplication sharedApplication];
    SEL a = NSSelectorFromString(@"_simulateHomeButtonPress");
    if ([app respondsToSelector:a]) { ((void (*)(id, SEL))objc_msgSend)(app, a); PFLog(@"home via _simulateHomeButtonPress"); return YES; }
    id ui = [%c(SBUIController) sharedInstance];
    SEL b = NSSelectorFromString(@"clickedMenuButton");
    if (ui && [ui respondsToSelector:b]) { ((void (*)(id, SEL))objc_msgSend)(ui, b); PFLog(@"home via SBUIController clickedMenuButton"); return YES; }
    PFLog(@"home: no usable home-button selector found");
    return NO;
}
static void PFDumpHomeSelectors(void) {
    const char *names[] = { "SpringBoard", "SBUIController", "SBHomeHardwareButtonActions", "SBMainSwitcherViewController" };
    for (int i = 0; i < 4; i++) {
        Class c = objc_getClass(names[i]); if (!c) { PFLog(@"home-api %s: (class missing)", names[i]); continue; }
        NSMutableArray *hits = [NSMutableArray new]; unsigned n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned k = 0; k < n; k++) {
            NSString *nm = NSStringFromSelector(method_getName(ms[k])), *l = nm.lowercaseString;
            if ([l containsString:@"menubutton"] || [l containsString:@"homebutton"] || [l containsString:@"dismissswitcher"] || [l containsString:@"gohome"]) [hits addObject:nm];
        }
        free(ms);
        PFLog(@"home-api %s: %@", names[i], [hits componentsJoinedByString:@" "]);
    }
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
static void PFEnrollAbort(NSString *why) {
    gEnrolling = NO;
    PFLog(@"enroll aborted: %@", why);
    PFStatus([@"fail: " stringByAppendingString:why]);
    PFPrefSet(@"status", [@"Failed: " stringByAppendingString:why]);
}

// Force the foreground app (Settings) away. Kills it through FrontBoard, which drops back to the home screen.
static BOOL PFCloseFrontApp(NSString *bid) {
    if (!bid.length || [bid isEqualToString:@"com.apple.springboard"]) return NO;
    id svc = [%c(FBSSystemService) sharedService];
    SEL t = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if (svc && [svc respondsToSelector:t]) {
        ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(svc, t, bid, 1, NO, @"PhotoFace setup");
        PFLog(@"close: FBSSystemService terminated %@", bid);
        return YES;
    }
    @try {   // fallback: kill the process directly
        id fa = PFFrontAppObj();
        int pid = [[fa valueForKey:@"pid"] intValue];
        if (pid > 1) { kill(pid, SIGKILL); PFLog(@"close: kill(%d) for %@", pid, bid); return YES; }
    } @catch (NSException *e) {}
    PFLog(@"close: no way to terminate %@", bid);
    return NO;
}

// Launch the bundled PhotoFace Enroll app. A real foreground app is the one thing the camera daemon always lets use the camera.
static NSString *const kEnrollApp = @"com.photoface.enroll";
static BOOL PFLaunchEnrollApp(void) {
    id app = [UIApplication sharedApplication];
    SEL a = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([app respondsToSelector:a]) {
        BOOL r = ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(app, a, kEnrollApp, NO);
        PFLog(@"launch: launchApplicationWithIdentifier -> %d", r);
        if (r) return YES;
    }
    void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    typedef int (*LaunchFn)(CFStringRef, Boolean);
    LaunchFn f = h ? (LaunchFn)dlsym(h, "SBSLaunchApplicationWithIdentifier") : NULL;
    if (f) {
        int r = f((__bridge CFStringRef)kEnrollApp, false);
        PFLog(@"launch: SBSLaunchApplicationWithIdentifier -> %d", r);
        return r == 0;
    }
    PFLog(@"launch: no launch API available");
    return NO;
}

static NSDictionary *PFLoadDB(void) {
    NSData *d = [NSData dataWithContentsOfFile:PFDBPath()];
    if (!d) return nil;
    // NSString/NSData/NSNull must be allowed too: dictionary keys are NSStrings, and a secure
    // unarchive that doesn't list them fails, which made verify + test think nothing was enrolled.
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
        } @catch (NSException *e) { PFLog(@"PFLoadDB fallback exception: %@", e); r = nil; }
    }
    if (![r isKindOfClass:NSDictionary.class] || ![r[@"prints"] count]) { PFLog(@"PFLoadDB: face data unreadable"); return nil; }
    return r;
}
static float PFLimit(NSDictionary *db) {
    float base = db[@"base"] ? [db[@"base"] floatValue] : [db[@"th"] floatValue] / 1.25f;
    id tv = PFPrefGet(@"tolerance");
    float tol = tv ? [tv floatValue] : 1.25f;
    if (tol < 0.5f || tol > 2.0f) tol = 1.25f;
    return base * tol;
}

#pragma mark - scanner

@interface PFScanner : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (atomic) int mode; // 0 idle, 1 verify, 2 enroll, 3 test
@property (atomic) BOOL sawMismatch; // verify saw a face repeatedly that did not match
@property (nonatomic, readonly) AVCaptureSession *session;
@property (nonatomic, copy) void (^progress)(NSDictionary *info);
+ (instancetype)shared;
- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done;
- (void)cancel;
@end

@implementation PFScanner {
    AVCaptureSession *_s; dispatch_queue_t _q; CIContext *_ci; NSTimer *_wd;
    NSTimeInterval _startTS, _deadlineTS, _lastFrameTS, _lastProc, _lastGain;
    int _frames, _hits, _miss, _center, _secCount[8];
    NSMutableArray *_got; NSMutableArray<NSNumber *> *_bins;
    NSDictionary *_db; void (^_done)(BOOL, NSString *);
    NSString *_interrupt; long _intReason; NSTimeInterval _lastRebuild; BOOL _observing; int _retries; dispatch_queue_t _cfg; NSMutableArray *_obs;
}
@synthesize session = _s;

+ (instancetype)shared {
    static PFScanner *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [PFScanner new];
        i->_q = dispatch_queue_create("photoface.cam", DISPATCH_QUEUE_SERIAL);
        i->_cfg = dispatch_queue_create("photoface.cfg", DISPATCH_QUEUE_SERIAL);
        i->_ci = [CIContext contextWithOptions:nil]; });
    return i;
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
    [self teardown];   // never reuse a session that may be wedged
    if (!_obs) _obs = [NSMutableArray new];
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
    @try {
        SEL sup = NSSelectorFromString(@"isMultitaskingCameraAccessSupported"), en = NSSelectorFromString(@"setMultitaskingCameraAccessEnabled:");
        if ([s respondsToSelector:sup] && [s respondsToSelector:en]) {
            BOOL supported = ((BOOL (*)(id, SEL))objc_msgSend)(s, sup);
            PFLog(@"multitasking camera access supported=%d", supported);
            if (supported) ((void (*)(id, SEL, BOOL))objc_msgSend)(s, en, YES);
        } else PFLog(@"multitasking camera access API not present on this iOS");
    } @catch (NSException *ex) { PFLog(@"multitasking camera access exception: %@", ex); }
    _s = s;
    __weak PFScanner *ws = self;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionRuntimeErrorNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        NSError *er = n.userInfo[AVCaptureSessionErrorKey];
        PFScanner *st = ws; if (!st) return;
        st->_interrupt = er.localizedDescription ?: @"camera runtime error";
        PFLog(@"runtime error: %@", er);
    }]];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionWasInterruptedNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        long r = [n.userInfo[AVCaptureSessionInterruptionReasonKey] longValue];
        PFScanner *st = ws; if (!st) return;
        const char *rn = r == 1 ? "not foreground" : r == 2 ? "audio in use" : r == 3 ? "camera in use by another app" : r == 4 ? "multiple foreground apps" : r == 5 ? "system pressure" : "unknown";
        st->_interrupt = [NSString stringWithFormat:@"camera interrupted (reason %ld: %s)", r, rn]; st->_intReason = r;
        PFLog(@"interrupted reason=%ld (%s) appState=%ld frontApp=%@", r, rn, (long)[UIApplication sharedApplication].applicationState, PFFrontApp());
        if (r == 1) dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication *a = [UIApplication sharedApplication];
            if (a.applicationState == UIApplicationStateBackground) {
                PFLog(@"nudge: SpringBoard reports Background, posting WillEnterForeground/DidBecomeActive");
                [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationWillEnterForegroundNotification object:a];
                [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidBecomeActiveNotification object:a];
            }
        });
    }]];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionInterruptionEndedNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        PFScanner *st = ws; if (st) { st->_interrupt = nil; st->_intReason = 0; }
        PFLog(@"interruption ended");
    }]];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionDidStartRunningNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        PFLog(@"session did start running");
    }]];
    [_obs addObject:[nc addObserverForName:AVCaptureSessionDidStopRunningNotification object:s queue:nil usingBlock:^(NSNotification *n) {
        PFLog(@"session did stop running");
    }]];
    return nil;
}

- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done {
    if (self.mode) {
        if (mode == 1) { done(NO, @"busy"); return; }
        // setup/test were requested by the user: a lock-screen verify scan may be holding the camera, so stop it and retry
        PFLog(@"start mode=%d: stopping running scan (mode %d) first", mode, self.mode);
        [self finish:NO info:@"cancelled"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self start:mode timeout:t done:done]; });
        return;
    }
    if (mode == 1 || mode == 3) {
        _db = PFLoadDB();
        if (!_db) { done(NO, @"no face enrolled yet"); return; }
    }
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    PFLog(@"start mode=%d camera-auth=%ld", mode, (long)st);
    PFLogEnv("start");
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
    _retries = 0; _miss = 0; self.sawMismatch = NO;
    PFGuardBegin();
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
    // give the backlight / lock screen a moment to settle before grabbing the camera
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)gStartDelayMs * NSEC_PER_MSEC), _cfg, ^{
        if (!self.mode || s != self->_s) return;
        [s startRunning];
        PFLog(@"startRunning returned, running=%d interrupted=%d (try %d)", s.isRunning, s.isInterrupted, self->_retries);
    });
}

- (void)tick {
    if (!self.mode) return;
    NSTimeInterval n = CACurrentMediaTime();
    // no frames: rebuild a brand-new session (new device input), up to 2 times
    if (self.mode == 1 && !PFScreenActive()) { [self finish:NO info:@"screen dimmed/off (AOD)"]; return; }
    BOOL patient = (self.mode != 1);   // setup/test: the previous foreground app can take a few seconds to release the camera
    int maxRetries = patient ? 6 : 2;
    NSTimeInterval step = patient ? 1.5 : 1.0, giveUp = patient ? 13.0 : 5.5;
    BOOL held = _s.isInterrupted;
    if (patient && held) giveUp = 25.0;   // wait for the interruption to end instead of rebuilding
    BOOL staleHold = patient && held && _intReason == 1 && _retries < 8 && n - MAX(_lastRebuild, _startTS) > 3.0;   // "not foreground": rebuild instead of waiting
    if (_frames == 0 && ((!held && _retries < maxRetries && n - _startTS > step * (_retries + 1)) || staleHold)) {
        _lastRebuild = n;
        _retries++;
        PFLog(@"no frames after %.1fs (running=%d interrupted=%d) - rebuilding session (retry %d)",
              n - _startTS, _s.isRunning, _s.isInterrupted, _retries);
        NSString *err = [self build];
        if (err) { [self finish:NO info:err]; return; }
        [self launchSession];
        return;
    }
    if (_frames == 0 && n - _startTS > giveUp) {
        [self finish:NO info:[NSString stringWithFormat:@"the camera isn't delivering frames (session running: %@, interrupted: %@%@)",
                              _s.isRunning ? @"yes" : @"no", _s.isInterrupted ? @"yes" : @"no",
                              _interrupt ? [NSString stringWithFormat:@", %@", _interrupt] : @""]];
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
    PFGuardEnd();
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

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)c {
    NSTimeInterval now = CACurrentMediaTime();
    _frames++; _lastFrameTS = now;
    int mode = self.mode;
    if (!mode) return;
    if (now - _lastProc < (mode == 1 ? 0.1 : 0.15)) return;
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

    if (mode == 1) {
        // protection: only accept a face that is looking at the phone (frontal pose)
        float yw = f.yaw ? f.yaw.floatValue : 0, pt = 0;
        if (@available(iOS 15.0, *)) { if (f.pitch) pt = f.pitch.floatValue; }
        if (fabsf(yw) > 0.45f || fabsf(pt) > 0.45f) { _hits = 0; return; }
    }
    VNFeaturePrintObservation *fp = [self printFor:img face:f.boundingBox];
    if (!fp) return;
    float best = FLT_MAX;
    for (VNFeaturePrintObservation *p in _db[@"prints"]) {
        float d; if ([fp computeDistance:&d toFeaturePrintObservation:p error:nil]) best = MIN(best, d);
    }
    float limit = PFLimit(_db);
    if (mode == 3) { [self report:@{@"best": @(best), @"limit": @(limit), @"face": @YES}]; return; }
    if (best < limit) { _hits++; }
    else { _hits = 0; if (mode == 1 && ++_miss >= 3) self.sawMismatch = YES; }
    if (_hits >= gConfirmFrames) [self finish:YES info:[NSString stringWithFormat:@"match %.2f", best]];
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
    if (gEnrolling) { PFLog(@"begin(%d): setup already running, ignoring", mode); return; }
    gEnrolling = YES; gEnrollMode = mode;
    int gen = ++gEnrollGen;
    PFLogEnv("before-launch");
    if ([PFScanner shared].mode) [[PFScanner shared] cancel];   // free the camera from any lock-screen scan
    [[NSFileManager defaultManager] removeItemAtPath:[kDir stringByAppendingPathComponent:@"status.txt"] error:nil];
    // kill any stale Enroll process first (respring/updates don't stop a backgrounded app, so old code could keep running)
    id svc = [%c(FBSSystemService) sharedService];
    SEL tsel = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if (svc && [svc respondsToSelector:tsel]) ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(svc, tsel, kEnrollApp, 1, NO, @"PhotoFace restart");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!gEnrolling || gEnrollGen != gen) return;
        NSString *mp = [kDir stringByAppendingPathComponent:@"mode.txt"];
        [[NSString stringWithFormat:@"%d", mode] writeToFile:mp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(mp.fileSystemRepresentation, 0644);
        if (!PFLaunchEnrollApp()) PFEnrollAbort(@"couldn't launch the PhotoFace Enroll app (is it installed? run uicache)");
    });
    // if the app never reports back (killed, crashed) don't stay stuck
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gEnrolling && gEnrollGen == gen) {
            PFLog(@"enroll app never reported back, resetting");
            if (gEnrollMode == 2) PFEnrollAbort(@"the Enroll app didn't finish");
            else gEnrolling = NO;
        }
    });
}
// Settings normally suspends itself (prefs bundle). If anything is still in front we ask for Home,
// then close it through FrontBoard. We never lock the device: the setup UI can't show there.
+ (void)awaitHome:(int)mode tries:(int)n {
    NSString *fid = PFFrontAppID();
    if (!fid) {
        PFLog(@"home reached (waited %dms)", n * 200);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (n ? 1500 : 1000) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [[PFSetup shared] present:mode]; });
        return;
    }
    if (n == 0) { PFLog(@"front app is %@, trying Home", fid); PFGoHome(); }
    if (n == 5 || n == 15) PFCloseFrontApp(fid);   // ~1s and ~3s: Home didn't work, close the app
    if (n >= 40) {
        PFEnrollAbort([NSString stringWithFormat:@"couldn't close %@ (see log)", fid]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self awaitHome:mode tries:n + 1]; });
}

static UIColor *PFGreen(void) { return [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1]; }

- (UILabel *)label:(CGRect)f size:(CGFloat)s weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.font = [UIFont systemFontOfSize:s weight:w]; l.textColor = c;
    l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0;
    return l;
}

- (void)present:(int)mode {
    gEnrolling = YES;
    if (_w) {
        if (_finished) [self teardown];            // stale window from a previous run (never closed)
        else { PFLog(@"present: setup window already active"); return; }
    }
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
    if (_pl && s && _pl.session != s) _pl.session = s;   // session was rebuilt after a retry
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
        NSString *lg = [NSString stringWithContentsOfFile:[kDir stringByAppendingPathComponent:@"log.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSArray *ls = [lg componentsSeparatedByString:@"\n"]; NSMutableArray *tail = [NSMutableArray new];
        NSArray *keys = @[@"env[", @"interrupt", @"nudge", @"camera-auth", @"front app", @"close:", @"home ", @"no frames", @"finish", @"start mode", @"session did", @"runtime error"];
        for (NSInteger k = (NSInteger)ls.count - 1; k >= 0 && tail.count < 16; k--) {
            NSString *l = ls[k]; if (!l.length) continue;
            BOOL hit = NO; for (NSString *key in keys) if ([l containsString:key]) { hit = YES; break; }
            if (!hit) continue;
            if (l.length > 26) l = [l substringFromIndex:26];   // drop the date prefix
            [tail insertObject:l atIndex:0];
        }
        _sub.frame = CGRectMake(14, _sub.frame.origin.y, _w.bounds.size.width - 28, _w.bounds.size.height - _sub.frame.origin.y - 140);
        _sub.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
        _sub.textAlignment = NSTextAlignmentLeft;
        _sub.text = [NSString stringWithFormat:@"Reason: %@\n\n%@", info, [tail componentsJoinedByString:@"\n"]];
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
    gEnrolling = NO;
    [_pl removeFromSuperlayer]; _pl = nil;
    _w.hidden = YES; _w = nil; _ticks = nil; _circle = nil;
}
- (void)close {
    [self teardown];
    gPendingPW = nil;
}
@end

#pragma mark - lock screen icon

static void PFRetry(void);
static int gBlankTok = 0;
static BOOL PFScreenOn(void) { uint64_t st = 1; if (gBlankTok) notify_get_state(gBlankTok, &st); return st == 0; }
static BOOL PFScreenActive(void) {   // fully awake: not off, not dimmed by an always-on display
    if (!gAODSafe) return YES;
    SBBacklightController *b = [%c(SBBacklightController) sharedInstance];
    if ([b respondsToSelector:@selector(screenIsOn)] && ![b screenIsOn]) return NO;
    if ([b respondsToSelector:@selector(screenIsDim)] && [b screenIsDim]) return NO;
    return YES;
}
typedef NS_ENUM(int, PFIconState) { PFIconLocked, PFIconScanning, PFIconUnlocked, PFIconFailed };

@interface CSCoverSheetViewController : UIViewController
@end

@interface PFLockIcon : UIView
+ (instancetype)shared;
+ (void)setState:(PFIconState)s;
+ (void)attachTo:(UIView *)host refresh:(BOOL)refresh;
+ (void)reload;
+ (void)watch:(BOOL)on host:(UIView *)host;
@end

@implementation PFLockIcon {
    UIImageView *_face, *_lock; PFIconState _state; int _gen; BOOL _pcHidden;
}
+ (instancetype)shared {
    static PFLockIcon *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [[PFLockIcon alloc] initWithFrame:CGRectMake(0, 0, 48, 64)]; });
    return i;
}
static UIImage *PFSym(NSString *n, CGFloat pt) {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightLight];
    return [[UIImage systemImageNamed:n withConfiguration:c] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.userInteractionEnabled = YES;   // tap to retry
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
    _face = [[UIImageView alloc] initWithFrame:CGRectMake(4, 0, 40, 40)];
    _face.contentMode = UIViewContentModeScaleAspectFit;
    _lock = [[UIImageView alloc] initWithFrame:CGRectMake(15, 43, 18, 20)];
    _lock.contentMode = UIViewContentModeScaleAspectFit;
    for (UIView *v in @[_face, _lock]) {
        v.layer.shadowColor = UIColor.blackColor.CGColor; v.layer.shadowOpacity = 0.45;
        v.layer.shadowRadius = 3; v.layer.shadowOffset = CGSizeZero;
        [self addSubview:v];
    }
    [self apply:PFIconLocked];
    return self;
}
- (void)tapped { if (_state != PFIconScanning) PFRetry(); }
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { return CGRectContainsPoint(CGRectInset(self.bounds, -24, -24), p); }
- (void)apply:(PFIconState)s {
    _state = s;
    [self.layer removeAllAnimations]; [_face.layer removeAllAnimations];
    UIColor *c = UIColor.whiteColor; NSString *lock = @"lock.fill";
    switch (s) {
        case PFIconLocked:   c = [UIColor colorWithWhite:1 alpha:0.9]; break;
        case PFIconScanning: c = UIColor.whiteColor; break;
        case PFIconUnlocked: c = PFGreen(); lock = @"lock.open.fill"; break;
        case PFIconFailed:   c = [UIColor colorWithRed:1 green:0.35 blue:0.3 alpha:1]; break;
    }
    _face.image = PFSym(@"faceid", 34);
    _lock.image = PFSym(lock, 15);
    _face.tintColor = c; _lock.tintColor = c;
    _face.alpha = 1;
    if (s == PFIconScanning) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @1; a.toValue = @0.3; a.duration = 0.7; a.autoreverses = YES; a.repeatCount = HUGE_VALF;
        [_face.layer addAnimation:a forKey:@"pulse"];
    } else if (s == PFIconFailed) {
        CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        k.values = @[@0, @-8, @8, @-6, @6, @0]; k.duration = 0.4;
        [self.layer addAnimation:k forKey:@"shake"];
    }
}
- (void)refresh {
    id en = PFPrefGet(@"enabled"), si = PFPrefGet(@"showIcon");
    self.hidden = (en && ![en boolValue]) || (si && ![si boolValue]);
}
+ (void)setState:(PFIconState)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        PFLockIcon *i = [PFLockIcon shared];
        int g = ++i->_gen;
        [i apply:s];
        if (s == PFIconFailed)   // fall back to the plain locked look after a moment
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (i->_gen == g) [i apply:PFIconLocked];
            });
    });
}
+ (void)attachTo:(UIView *)host refresh:(BOOL)refresh {
    if (!host) return;
    PFLockIcon *i = [PFLockIcon shared];
    if (i.superview != host) { [i removeFromSuperview]; [host addSubview:i]; }
    [host bringSubviewToFront:i];
    CGSize sz = host.bounds.size;
    i.center = PFIconCenter(sz);
    if (refresh) [i refresh];
}
+ (void)reload {
    dispatch_async(dispatch_get_main_queue(), ^{
        PFLoadIconPos();
        PFLockIcon *i = [PFLockIcon shared];
        [i refresh];
        if (i.superview) i.center = PFIconCenter(i.superview.bounds.size);
    });
}

// ---- hide the icon while the passcode keypad is on screen ----
static BOOL PFFindPasscode(UIView *v, UIView *host, CGFloat acc, NSString **name) {
    if ([v isKindOfClass:PFLockIcon.class] || v.hidden) return NO;
    acc *= v.alpha;
    if (acc < 0.1) return NO;
    NSString *cn = NSStringFromClass(v.class);
    if ([cn rangeOfString:@"Passcode" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        CGRect r = [v convertRect:v.bounds toView:host];
        if (r.size.width > 150 && r.size.height > 150 && CGRectIntersectsRect(host.bounds, CGRectInset(r, 20, 20))) { if (name) *name = cn; return YES; }
    }
    for (UIView *sv in v.subviews) if (PFFindPasscode(sv, host, acc, name)) return YES;
    return NO;
}
- (void)updatePasscodeVisibility:(UIView *)host {
    NSString *name = nil;
    BOOL pc = gHideOnPasscode && PFFindPasscode(host, host, 1, &name);
    if (pc == _pcHidden) return;
    _pcHidden = pc;
    PFLog(@"icon: passcode screen %@ %@", pc ? @"visible, hiding icon" : @"gone, showing icon", name ?: @"");
    [UIView animateWithDuration:0.15 animations:^{ self.alpha = pc ? 0 : 1; }];
}
+ (void)watch:(BOOL)on host:(UIView *)host {
    static NSTimer *t;
    [t invalidate]; t = nil;
    PFLockIcon *i = [PFLockIcon shared];
    if (!on) return;
    i->_pcHidden = NO; i.alpha = 1;
    __weak UIView *wh = host;
    t = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *tm) {
        UIView *h = wh; if (!h) { [tm invalidate]; return; }
        [i updatePasscodeVisibility:h];
    }];
}
@end

#pragma mark - unlock logic

static BOOL PFIsLocked(void);
static void PFUnlock(NSString *pw) {
    SBLockScreenManager *m = [%c(SBLockScreenManager) sharedInstance];
    NSString *how = @"none";
    if ([m respondsToSelector:@selector(_attemptUnlockWithPasscode:mesa:finishUIUnlock:completion:)]) {
        [m _attemptUnlockWithPasscode:pw mesa:NO finishUIUnlock:YES completion:nil]; how = @"_attemptUnlockWithPasscode:mesa:";
    } else if ([m respondsToSelector:@selector(attemptUnlockWithPasscode:finishUIUnlock:completion:)]) {
        [m attemptUnlockWithPasscode:pw finishUIUnlock:YES completion:nil]; how = @"attemptUnlockWithPasscode:finishUIUnlock:completion:";
    } else if ([m respondsToSelector:@selector(attemptUnlockWithPasscode:)]) {
        [m attemptUnlockWithPasscode:pw]; how = @"attemptUnlockWithPasscode:";
    }
    PFLog(@"unlock: authenticated via %@", how);
    // Authenticating does not always dismiss the lock UI -> push it through to the home screen.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!PFIsLocked()) { PFLog(@"unlock: lock UI dismissed"); return; }
        SBLockScreenManager *mm = [%c(SBLockScreenManager) sharedInstance];
        SEL u = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
        if ([mm respondsToSelector:u]) { ((void (*)(id, SEL, int, id))objc_msgSend)(mm, u, 0, nil); PFLog(@"unlock: unlockUIFromSource sent"); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!PFIsLocked()) { PFLog(@"unlock: lock UI dismissed (2)"); return; }
            id app = [UIApplication sharedApplication];
            if ([app respondsToSelector:@selector(_simulateHomeButtonPress)]) { [(SpringBoard *)app _simulateHomeButtonPress]; PFLog(@"unlock: home press sent"); }
        });
    });
}

static BOOL PFIsLocked(void) {
    SBLockScreenManager *m = [%c(SBLockScreenManager) sharedInstance];
    if (!m) return NO;
    if ([m respondsToSelector:@selector(isUILocked)]) return [m isUILocked];
    if ([m respondsToSelector:@selector(isUIUnlocked)]) return ![m isUIUnlocked];
    if ([m respondsToSelector:@selector(isLockScreenVisible)]) return [m isLockScreenVisible];
    return NO;
}

static void PFWakeInner(void) {
    if ([PFScanner shared].mode || gEnrolling) return;   // already scanning / setup UI is up
    if (!PFIsLocked()) { gFails = 0; return; }
    {
        SBBacklightController *bc = [%c(SBBacklightController) sharedInstance];
        PFLog(@"wake: screen on=%d dim=%d blanked-token-on=%d forced=%d", [bc respondsToSelector:@selector(screenIsOn)] ? (int)[bc screenIsOn] : -1,
              [bc respondsToSelector:@selector(screenIsDim)] ? (int)[bc screenIsDim] : -1, (int)PFScreenOn(), (int)gForceScan);
    }
    if (!gForceScan && !PFScreenActive()) { PFLog(@"wake: skipped, screen is dimmed/off (always-on display?)"); return; }
    id en = PFPrefGet(@"enabled");
    if (en && ![en boolValue]) { PFLog(@"wake: skipped, tweak switched off"); return; }      // master switch
    if (gFails >= 3) { PFLog(@"wake: skipped, locked out after %d fails", gFails); return; }
    NSString *pw = PFLoadPW(); // nil before first unlock after boot -> passcode required, like Touch ID
    BOOL hasDB = [[NSFileManager defaultManager] fileExistsAtPath:PFDBPath()];
    if (!pw || !hasDB) { PFLog(@"wake: skipped, passcode stored=%d face enrolled=%d", pw != nil, hasDB); return; }
    PFLogEnv("wake");
    [PFLockIcon setState:PFIconScanning];
    [[PFScanner shared] start:1 timeout:6 done:^(BOOL ok, NSString *i) {
        if (!ok) {
            BOOL seen = [PFScanner shared].sawMismatch;
            if (seen) { gFails++; PFLog(@"face seen but not matched (fails=%d)", gFails); }
            else PFLog(@"verify ended without a match: %@", i);
            [PFLockIcon setState:seen ? PFIconFailed : PFIconLocked];
            return;
        }
        if (!gForceScan && !PFScreenActive()) { PFLog(@"match ignored: screen dimmed/off (always-on display?)"); [PFLockIcon setState:PFIconLocked]; return; }
        [PFLockIcon setState:PFIconUnlocked];
        if (!PFIsLocked()) return;
        // brief pause so the open padlock is visible, like Face ID
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!PFIsLocked()) return;
            @try { PFUnlock(pw); } @catch (NSException *e) { PFLog(@"unlock exception: %@", e); }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (PFIsLocked()) { gFails++; [PFLockIcon setState:PFIconFailed]; PFLog(@"still locked after unlock attempt (fails=%d)", gFails); }
            });
        });
    }];
}

static void PFWake(void) {
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 1.5) return;   // wake can be signalled twice
    last = now;
    PFGuardBegin();
    @try { PFWakeInner(); } @catch (NSException *e) { PFLog(@"wake exception: %@", e); }
    if (![PFScanner shared].mode) PFGuardEnd();
}

// tap on the lock icon: clear the lockout and scan again right now
static void PFRetry(void) {
    if ([PFScanner shared].mode) return;
    gFails = 0;
    PFLog(@"retry: icon tapped");
    PFGuardBegin();
    gForceScan = YES;
    @try { PFWakeInner(); } @catch (NSException *e) { PFLog(@"retry exception: %@", e); }
    gForceScan = NO;
    if (![PFScanner shared].mode) PFGuardEnd();
}

%hook CSCoverSheetViewController
- (void)viewWillAppear:(BOOL)a {
    %orig;
    [PFLockIcon attachTo:self.view refresh:YES]; [PFLockIcon watch:YES host:self.view];
    if (gEarlyTrigger && PFScreenOn() && PFScreenActive()) dispatch_async(dispatch_get_main_queue(), ^{ PFWake(); });   // start the camera as soon as the lock screen appears
}
- (void)viewDidDisappear:(BOOL)a { %orig; [PFLockIcon watch:NO host:nil]; }
- (void)viewDidLayoutSubviews { %orig; [PFLockIcon attachTo:self.view refresh:NO]; }
%end

%hook SBBacklightController
- (void)turnOnScreenFullyWithBacklightSource:(long long)source {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ PFWake(); });
}
%end

// Settings writes the passcode pref and posts the notification back to back; the pref can reach
// SpringBoard a moment later, so retry for ~1.6s instead of failing on the first read.
static void PFBeginEnroll(int attempt) {
    NSString *p = [kDir stringByAppendingPathComponent:@"passcode.tmp"];
    NSString *pw = PFPrefGet(@"pendingPasscode");
    if (!pw.length) pw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!pw.length && attempt < 8) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ PFBeginEnroll(attempt + 1); });
        return;
    }
    PFPrefSet(@"pendingPasscode", nil);
    [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    if (!pw.length) {
        PFStatus(@"fail: no passcode received");
        PFPrefSet(@"status", @"Failed: no passcode received");
        return;
    }
    if (gEnrolling) { PFLog(@"enroll ignored: setup already running"); return; }
    PFLog(@"enroll requested (passcode read after %d retries)", attempt);
    gPendingPW = pw;
    PFPrefSet(@"status", @"Setup in progress");
    [PFSetup begin:2];
}

%ctor {
    @autoreleasepool {
        %init;
        PFLoadIconPos();
        static int t5;
        notify_register_dispatch("com.photoface.prefschanged", &t5, dispatch_get_main_queue(), ^(int t) { [PFLockIcon reload]; });
        static int t1, t2, t3;
        notify_register_dispatch("com.photoface.enroll", &t1, dispatch_get_main_queue(), ^(int t) {
            PFLog(@"enroll notification received");
            PFBeginEnroll(0);
        });
        notify_register_dispatch("com.photoface.test", &t2, dispatch_get_main_queue(), ^(int t) {
            PFLog(@"test requested");
            [PFSetup begin:3];
        });
        static int t6;
        notify_register_dispatch("com.photoface.enrolldone", &t6, dispatch_get_main_queue(), ^(int t) {
            int mode = gEnrollMode;
            PFLog(@"enroll app reported done (mode %d)", mode);
            gEnrolling = NO; gEnrollMode = 0;
            if (mode != 2) return;
            NSString *st = [NSString stringWithContentsOfFile:[kDir stringByAppendingPathComponent:@"status.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
            if ([st hasPrefix:@"ok"]) {
                if (gPendingPW) PFSavePW(gPendingPW);
                gPendingPW = nil; gFails = 0;
                NSString *info = st.length > 4 ? [st substringFromIndex:4] : @"";
                PFPrefSet(@"status", [NSString stringWithFormat:@"Enrolled (%@)", info]);
            } else if ([st hasPrefix:@"cancel"]) {
                gPendingPW = nil; PFRefreshStatus();
            } else {
                gPendingPW = nil;
                PFPrefSet(@"status", [@"Failed: " stringByAppendingString:st.length > 6 ? [st substringFromIndex:6] : @"unknown"]);
            }
        });
        notify_register_dispatch("com.photoface.clear", &t3, dispatch_get_main_queue(), ^(int t) {
            [[NSFileManager defaultManager] removeItemAtPath:PFDBPath() error:nil];
            SecItemDelete((__bridge CFDictionaryRef)PFQ());
            PFPrefSet(@"status", @"Not enrolled");
        });
        notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &gBlankTok, dispatch_get_main_queue(), ^(int t) {
            uint64_t st = 1; notify_get_state(t, &st);
            if (st == 0) PFWake(); else [PFLockIcon setState:PFIconLocked];
        });
        PFPrefSet(@"pendingPasscode", nil);
        if ([[NSFileManager defaultManager] fileExistsAtPath:PFGuardPath()]) {
            PFGuardEnd();
            PFPrefSet(@"enabled", @NO);
            PFPrefSet(@"status", @"Switched off: SpringBoard crashed while PhotoFace was running");
            PFLog(@"crash guard tripped: previous run did not finish; tweak switched off");
        } else {
            PFRefreshStatus();
        }
        {
            NSMutableArray *hits = [NSMutableArray new];
            for (uint32_t k = 0; k < _dyld_image_count(); k++) {
                const char *n = _dyld_get_image_name(k);
                if (!n) continue;
                NSString *ns = [NSString stringWithUTF8String:n], *l = ns.lowercaseString;
                if ([l containsString:@"/tweaks/"] || [l containsString:@"/tweakinject"]) [hits addObject:ns.lastPathComponent];
            }
            PFLog(@"loaded tweaks in SpringBoard: %@", [hits componentsJoinedByString:@" "]);
        }
        PFLog(@"PhotoFace loaded in SpringBoard");
        PFDumpCameraSwitches();
        PFDumpHomeSelectors();
    }
}
