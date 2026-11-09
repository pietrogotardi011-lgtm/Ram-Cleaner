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
        message:@"Enter your device passcode twice. It is stored in the Keychain and entered for you when your face matches.\n\nAfter you tap Start, you'll be taken to the Home Screen where the face setup circle appears."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.secureTextEntry = YES; t.placeholder = @"Passcode"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.secureTextEntry = YES; t.placeholder = @"Confirm passcode"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Start" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *pw = wa.textFields[0].text, *pw2 = wa.textFields[1].text;
        if (!pw.length) return;
        if (![pw isEqualToString:pw2]) { [self alert:@"Passcodes don't match" msg:@"Try again."]; return; }
        PFSet(@"pendingPasscode", pw);
        PFSet(@"status", @"Starting…");
        notify_post("com.photoface.enroll");
        [self reloadSpecifiers];
        [self startPolling];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)testRecognition:(PSSpecifier *)s {
    notify_post("com.photoface.test");
}
- (void)alert:(NSString *)t msg:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)startPolling {
    [_timer invalidate]; _ticks = 0;
    __block NSString *last = PFGet(@"status");
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        self->_ticks++;
        NSString *st = PFGet(@"status") ?: @"";
        if (![st isEqualToString:last]) { last = st; [self reloadSpecifiers]; }
        if ([st hasPrefix:@"Starting"] && self->_ticks > 24) {
            [t invalidate];
            PFSet(@"status", @"Failed: tweak not responding");
            [self reloadSpecifiers];
            [self alert:@"SpringBoard didn't respond" msg:@"PhotoFace isn't running in SpringBoard. Respring, make sure the tweak is installed, then try again."];
            return;
        }
        BOOL inProgress = [st hasPrefix:@"Starting"] || [st hasPrefix:@"Setup in progress"];
        if (!inProgress || self->_ticks > 220) [t invalidate];
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
