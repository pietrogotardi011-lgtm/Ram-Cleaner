// PhotoFace - on-device 2D face unlock for SpringBoard (iOS 15, rootful)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <Security/Security.h>
#import <notify.h>
#import <float.h>
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

static NSString *const kDir = @"/var/mobile/Library/PhotoFace";
static NSString *const kService = @"com.photoface.passcode";

#pragma mark - storage

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
static void PFStatus(NSString *s) {
    NSString *p = [kDir stringByAppendingPathComponent:@"status.txt"];
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(p.fileSystemRepresentation, 0644);
}
static NSString *PFDBPath(void) { return [kDir stringByAppendingPathComponent:@"db.bin"]; }
static NSDictionary *PFLoadDB(void) {
    NSData *d = [NSData dataWithContentsOfFile:PFDBPath()];
    if (!d) return nil;
    NSSet *cls = [NSSet setWithObjects:NSDictionary.class, NSArray.class, NSNumber.class,
                  VNFeaturePrintObservation.class, nil];
    return [NSKeyedUnarchiver unarchivedObjectOfClasses:cls fromData:d error:nil];
}

#pragma mark - scanner

@interface PFScanner : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (atomic) int mode; // 0 idle, 1 verify, 2 enroll
+ (instancetype)shared;
- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done;
@end

@implementation PFScanner {
    AVCaptureSession *_s; dispatch_queue_t _q; CIContext *_ci;
    NSDate *_deadline, *_last; int _hits; NSMutableArray *_got; NSDictionary *_db;
    void (^_done)(BOOL, NSString *);
}
+ (instancetype)shared {
    static PFScanner *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [PFScanner new];
        i->_q = dispatch_queue_create("photoface.cam", DISPATCH_QUEUE_SERIAL);
        i->_ci = [CIContext contextWithOptions:nil]; });
    return i;
}
- (void)start:(int)mode timeout:(NSTimeInterval)t done:(void (^)(BOOL, NSString *))done {
    if (self.mode) return;
    if (mode == 1) { _db = PFLoadDB(); if (!_db) { done(NO, @"no enrollment"); return; } }
    _done = [done copy]; _hits = 0; _got = [NSMutableArray new];
    _last = [NSDate distantPast]; _deadline = [NSDate dateWithTimeIntervalSinceNow:t];
    self.mode = mode;
    dispatch_async(_q, ^{
        if (!self->_s && ![self build]) return;
        [self->_s startRunning];
    });
}
- (BOOL)build {
    AVCaptureDevice *d = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                            mediaType:AVMediaTypeVideo
                                                             position:AVCaptureDevicePositionFront];
    NSError *e = nil;
    AVCaptureDeviceInput *in = d ? [AVCaptureDeviceInput deviceInputWithDevice:d error:&e] : nil;
    if (!in) { [self finish:NO info:@"no front camera access"]; return NO; }
    _s = [AVCaptureSession new];
    _s.sessionPreset = AVCaptureSessionPreset640x480;
    [_s addInput:in];
    AVCaptureVideoDataOutput *o = [AVCaptureVideoDataOutput new];
    o.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
    o.alwaysDiscardsLateVideoFrames = YES;
    [o setSampleBufferDelegate:self queue:_q];
    [_s addOutput:o];
    AVCaptureConnection *c = [o connectionWithMediaType:AVMediaTypeVideo];
    if (c.isVideoOrientationSupported) c.videoOrientation = AVCaptureVideoOrientationPortrait;
    return YES;
}
- (void)finish:(BOOL)ok info:(NSString *)info {
    if (!self.mode) return;
    self.mode = 0;
    AVCaptureSession *s = _s;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [s stopRunning]; });
    void (^d)(BOOL, NSString *) = _done; _done = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (d) d(ok, info); });
}
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)c {
    int mode = self.mode;
    if (!mode) return;
    NSDate *now = [NSDate date];
    if ([now timeIntervalSinceDate:_last] < (mode == 2 ? 0.35 : 0.2)) return;
    _last = now;
    if ([now compare:_deadline] == NSOrderedDescending) { [self finish:NO info:@"timeout"]; return; }

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb) return;
    VNDetectFaceRectanglesRequest *fr = [VNDetectFaceRectanglesRequest new];
    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pb options:@{}];
    if (![h performRequests:@[fr] error:nil]) return;
    if (fr.results.count != 1) { _hits = 0; return; }       // exactly one face
    VNFaceObservation *f = fr.results[0];
    if (f.boundingBox.size.width < 0.25) { _hits = 0; return; } // too far away

    CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
    CGRect r = VNImageRectForNormalizedRect(f.boundingBox, img.extent.size.width, img.extent.size.height);
    r = CGRectIntersection(CGRectInset(r, -r.size.width * 0.15, -r.size.height * 0.15), img.extent);
    CGImageRef cg = [_ci createCGImage:img fromRect:r];
    if (!cg) return;
    VNGenerateImageFeaturePrintRequest *pr = [VNGenerateImageFeaturePrintRequest new];
    VNImageRequestHandler *h2 = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    BOOL okp = [h2 performRequests:@[pr] error:nil];
    CGImageRelease(cg);
    VNFeaturePrintObservation *fp = okp ? (VNFeaturePrintObservation *)pr.results.firstObject : nil;
    if (!fp) return;

    if (mode == 2) {
        [_got addObject:fp];
        if (_got.count >= 14) [self finalizeEnroll];
        return;
    }
    float best = FLT_MAX;
    for (VNFeaturePrintObservation *p in _db[@"prints"]) {
        float d; if ([fp computeDistance:&d toFeaturePrintObservation:p error:nil]) best = MIN(best, d);
    }
    _hits = (best < [_db[@"th"] floatValue]) ? _hits + 1 : 0;
    if (_hits >= 3) [self finish:YES info:[NSString stringWithFormat:@"match %.2f", best]];
}
- (void)finalizeEnroll {
    NSInteger n = _got.count; float worst = 0;
    for (NSInteger i = 0; i < n; i++) {
        float mn = FLT_MAX;
        for (NSInteger j = 0; j < n; j++) {
            if (labs(i - j) < 3) continue;   // ignore near-duplicate neighbouring frames
            float d; if ([_got[i] computeDistance:&d toFeaturePrintObservation:_got[j] error:nil]) mn = MIN(mn, d);
        }
        if (mn < FLT_MAX) worst = MAX(worst, mn);
    }
    float th = worst * 1.25f;
    NSDictionary *db = @{@"prints": [_got copy], @"th": @(th)};
    NSData *dat = [NSKeyedArchiver archivedDataWithRootObject:db requiringSecureCoding:YES error:nil];
    if (!dat || ![dat writeToFile:PFDBPath() atomically:YES]) { [self finish:NO info:@"could not save"]; return; }
    chmod(PFDBPath().fileSystemRepresentation, 0600);
    [self finish:YES info:[NSString stringWithFormat:@"%ld samples, threshold %.2f", (long)n, th]];
}
@end

#pragma mark - unlock logic

static int gFails = 0;

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
    if (gFails >= 3) return;  // stop guessing if the stored passcode seems wrong
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
        static int t1, t2;
        notify_register_dispatch("com.photoface.enroll", &t1, dispatch_get_main_queue(), ^(int t) {
            NSString *p = [kDir stringByAppendingPathComponent:@"passcode.tmp"];
            NSString *pw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
            if (!pw.length) { PFStatus(@"fail: no passcode received"); return; }
            PFSavePW(pw);
            [[PFScanner shared] start:2 timeout:25 done:^(BOOL ok, NSString *i) {
                gFails = 0;
                PFStatus([NSString stringWithFormat:@"%@: %@", ok ? @"ok" : @"fail", i ?: @"unknown"]);
            }];
        });
        notify_register_dispatch("com.photoface.clear", &t2, dispatch_get_main_queue(), ^(int t) {
            [[NSFileManager defaultManager] removeItemAtPath:PFDBPath() error:nil];
            SecItemDelete((__bridge CFDictionaryRef)PFQ());
        });
    }
}
