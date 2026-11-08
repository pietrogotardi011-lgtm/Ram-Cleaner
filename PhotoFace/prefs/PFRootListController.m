#import <UIKit/UIKit.h>
#import <notify.h>

// Minimal declarations; the real classes live in Preferences.framework (loaded inside Settings).
@interface PSSpecifier : NSObject
@end
@interface PSListController : UIViewController { NSArray *_specifiers; }
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

static CFStringRef const kDom = CFSTR("com.photoface.tweak");
static id PFGet(NSString *k) {
    CFPreferencesAppSynchronize(kDom);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k, kDom));
}
static void PFSet(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, kDom);
    CFPreferencesAppSynchronize(kDom);
}

@interface PFRootListController : PSListController
@end

@implementation PFRootListController {
    NSTimer *_timer; int _ticks;
}
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
- (id)statusText:(PSSpecifier *)s {
    NSString *v = PFGet(@"status");
    return v.length ? v : @"Not enrolled";
}
- (void)enroll:(PSSpecifier *)s {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Set Up PhotoFace"
        message:@"Enter your device passcode. It is stored in the Keychain and used to unlock when your face matches.\n\nAfter tapping Start, look at the front camera and slowly move your head for about 8 seconds."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.secureTextEntry = YES; t.placeholder = @"Passcode";
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Start" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *pw = wa.textFields.firstObject.text;
        if (!pw.length) return;
        PFSet(@"pendingPasscode", pw);
        PFSet(@"status", @"Scanning… look at the front camera");
        notify_post("com.photoface.enroll");
        [self reloadSpecifiers];
        [self startPolling];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)startPolling {
    [_timer invalidate]; _ticks = 0;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.7 repeats:YES block:^(NSTimer *t) {
        self->_ticks++;
        NSString *st = PFGet(@"status") ?: @"";
        BOOL done = ![st hasPrefix:@"Scanning"];
        if (done || self->_ticks > 60) {
            [t invalidate];
            if (!done) PFSet(@"status", @"Failed: no response from SpringBoard");
            [self reloadSpecifiers];
        }
    }];
}
- (void)clearData:(PSSpecifier *)s {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Remove Face Data?"
        message:@"Deletes your enrolled face data and the stored passcode." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        notify_post("com.photoface.clear");
        PFSet(@"status", @"Not enrolled");
        [self reloadSpecifiers];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
