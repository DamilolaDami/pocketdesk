#import "PDVirtualDisplayRuntime.h"
#import <TargetConditionals.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Independently written runtime bridge. No private headers or third-party implementation
// are vendored. Runtime signature checks bound this experiment; they do not make a private
// ABI supported or guarantee that Apple preserves its semantics.
// SwiftPM enables ARC for Objective-C. Only this dictionary retains live displays;
// every operation holds its monitor, and destruction requires the exact ownership token.
static NSMutableDictionary<NSNumber *, id> *ownedDisplays;
static uint64_t nextToken = 0;

static NSMutableDictionary *registry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ownedDisplays = [[NSMutableDictionary alloc] init]; });
    return ownedDisplays;
}

// Method-family declarations let ARC correctly consume alloc/init ownership. Only these
// messages are sent after the runtime signatures above have been checked.
@protocol PDVDDisplayConstruction
- (instancetype)initWithDescriptor:(id)value;
@end
@protocol PDVDModeConstruction
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(CGFloat)hz;
@end

static bool failure(char *error, size_t capacity, NSString *message) {
    if (capacity) snprintf(error, capacity, "%s", message.UTF8String);
    return false;
}

static BOOL sameType(const char *actual, const char *expected) {
    return (actual[0] == '@' && expected[0] == '@') || strcmp(actual, expected) == 0;
}

static BOOL signature(Class cls, NSString *name, const char *result, NSArray<NSString *> *arguments) {
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:NSSelectorFromString(name)];
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    const char *encoding = method ? method_getTypeEncoding(method) : "missing";
    if (!sig || !sameType(sig.methodReturnType, result) || sig.numberOfArguments != arguments.count + 2) {
        fprintf(stderr, "ABI mismatch %s.%s: %s; expected return %s, %lu explicit arguments\n",
                class_getName(cls), name.UTF8String, encoding, result, (unsigned long)arguments.count);
        return NO;
    }
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (!sameType([sig getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) {
            fprintf(stderr, "ABI mismatch %s.%s: %s; argument %lu expected %s, found %s\n",
                    class_getName(cls), name.UTF8String, encoding, (unsigned long)i,
                    arguments[i].UTF8String, [sig getArgumentTypeAtIndex:i + 2]);
            return NO;
        }
    }
    return YES;
}

bool PDVDAvailable(char *error, size_t capacity) {
#if TARGET_OS_OSX
    @autoreleasepool {
        Class descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class display = NSClassFromString(@"CGVirtualDisplay");
        Class settings = NSClassFromString(@"CGVirtualDisplaySettings");
        Class mode = NSClassFromString(@"CGVirtualDisplayMode");
        if (!descriptor || !display || !settings || !mode) return failure(error, capacity, @"Virtual-display runtime classes unavailable.");
        NSArray *object = @[@(@encode(id))];
        NSArray *integer = @[@(@encode(unsigned int))];
        for (NSString *setter in @[@"setName:", @"setDispatchQueue:"]) {
            if (!signature(descriptor, setter, @encode(void), object)) return failure(error, capacity, [@"Unexpected descriptor signature: " stringByAppendingString:setter]);
        }
        for (NSString *setter in @[@"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setVendorID:", @"setProductID:", @"setSerialNum:"]) {
            if (!signature(descriptor, setter, @encode(void), integer)) return failure(error, capacity, [@"Unexpected descriptor signature: " stringByAppendingString:setter]);
        }
        if (!signature(descriptor, @"setSizeInMillimeters:", @encode(void), @[@(@encode(CGSize))])
            || !signature(display, @"initWithDescriptor:", @encode(id), object)
            || !signature(display, @"displayID", @encode(CGDirectDisplayID), @[])
            || !signature(display, @"applySettings:", @encode(BOOL), object)
            || !signature(settings, @"setModes:", @encode(void), object)
            || !signature(settings, @"setHiDPI:", @encode(void), integer)
            || !signature(mode, @"initWithWidth:height:refreshRate:", @encode(id), @[@(@encode(unsigned int)), @(@encode(unsigned int)), @(@encode(CGFloat))])) {
            return failure(error, capacity, @"Unexpected virtual-display runtime ABI.");
        }
        return true;
    }
#else
    return failure(error, capacity, @"macOS only.");
#endif
}

uint64_t PDVDCreate(uint32_t width, uint32_t height, double refreshRate, uint32_t serial, char *error, size_t capacity) {
    @autoreleasepool {
      @synchronized (registry()) {
        if (ownedDisplays.count || width < 640 || height < 480 || width > 1920 || height > 1200
            || (refreshRate != 30 && refreshRate != 60) || nextToken == UINT64_MAX) {
            failure(error, capacity, @"Only one bounded 1x display at 30 or 60 Hz is supported."); return 0;
        }
        if (!PDVDAvailable(error, capacity)) return 0;
        @try {
            id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            void (*setObject)(id, SEL, id) = (void *)objc_msgSend;
            void (*setInteger)(id, SEL, unsigned int) = (void *)objc_msgSend;
            void (*setSize)(id, SEL, CGSize) = (void *)objc_msgSend;
            setObject(descriptor, NSSelectorFromString(@"setName:"), @"PocketDesk Virtual Display");
            setObject(descriptor, NSSelectorFromString(@"setDispatchQueue:"), dispatch_get_main_queue());
            setInteger(descriptor, NSSelectorFromString(@"setMaxPixelsWide:"), width);
            setInteger(descriptor, NSSelectorFromString(@"setMaxPixelsHigh:"), height);
            setInteger(descriptor, NSSelectorFromString(@"setVendorID:"), 0x5044);
            setInteger(descriptor, NSSelectorFromString(@"setProductID:"), 0x5052);
            setInteger(descriptor, NSSelectorFromString(@"setSerialNum:"), serial);
            // Keep the intended 1x desktop density consistent across sizes. A fixed small
            // physical size can make macOS choose a different desktop scale for larger modes.
            setSize(descriptor, NSSelectorFromString(@"setSizeInMillimeters:"), CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0));
            id display = [(id<PDVDDisplayConstruction>)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
            if (!display) { failure(error, capacity, @"WindowServer refused display creation."); return 0; }
            id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
            id mode = [(id<PDVDModeConstruction>)[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:refreshRate];
            setInteger(settings, NSSelectorFromString(@"setHiDPI:"), 0);
            setObject(settings, NSSelectorFromString(@"setModes:"), @[mode]);
            BOOL (*apply)(id, SEL, id) = (void *)objc_msgSend;
            if (!apply(display, NSSelectorFromString(@"applySettings:"), settings)) {
                failure(error, capacity, @"Virtual-display mode rejected."); return 0;
            }
            CGDirectDisplayID (*getID)(id, SEL) = (void *)objc_msgSend;
            CGDirectDisplayID displayID = getID(display, NSSelectorFromString(@"displayID"));
            if (!displayID) { failure(error, capacity, @"Virtual display has no capture ID."); return 0; }
            uint64_t token = ++nextToken;
            ownedDisplays[@(token)] = display;
            return token;
        } @catch (NSException *exception) {
            failure(error, capacity, [@"Virtual-display exception: " stringByAppendingString:exception.name]);
            return 0;
        }
      }
    }
}

uint32_t PDVDCaptureID(uint64_t token) {
    @autoreleasepool { @synchronized (registry()) {
        id display = ownedDisplays[@(token)];
        if (!display) return 0;
        CGDirectDisplayID (*getID)(id, SEL) = (void *)objc_msgSend;
        return getID(display, NSSelectorFromString(@"displayID"));
    } }
}

bool PDVDDestroy(uint64_t token) {
    @autoreleasepool { @synchronized (registry()) {
        if (!ownedDisplays[@(token)]) return false;
        [ownedDisplays removeObjectForKey:@(token)];
        return true;
    } }
}
