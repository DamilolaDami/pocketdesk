#import "PDVirtualDisplayRuntime.h"
#import <TargetConditionals.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

// Independently written runtime bridge. No private headers or third-party implementation
// are vendored. Runtime signature checks bound this experiment; they do not make a private
// ABI supported or guarantee that Apple preserves its semantics.
// SwiftPM enables ARC for Objective-C. Only this dictionary retains live displays;
// every operation holds its monitor, and destruction requires the exact ownership token.
static NSMutableDictionary<NSNumber *, id> *ownedDisplays;
static uint64_t nextToken = 0;
static NSMutableDictionary<NSNumber *, NSArray *> *ownedModeTables;
static NSMutableDictionary<NSNumber *, NSNumber *> *ownedOrientations;

static NSMutableDictionary *registry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ownedDisplays = [[NSMutableDictionary alloc] init]; ownedModeTables = [[NSMutableDictionary alloc] init]; ownedOrientations = [[NSMutableDictionary alloc] init]; });
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

static NSArray *modeTable(uint32_t width, uint32_t height, uint32_t scale, double rate) {
    NSMutableArray *modes = [NSMutableArray array];
    uint32_t preferredWidth = width * scale, preferredHeight = height * scale;
    bool portrait = width < height;
    [modes addObject:[(id<PDVDModeConstruction>)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:preferredWidth height:preferredHeight refreshRate:rate]];
    const unsigned int sizes[][2] = {{1024, 768}, {1280, 800}, {1280, 960}};
    for (unsigned int i = 0; i < 3; i++) for (unsigned int backing = 1; backing <= 2; backing++)
        for (unsigned int hz = 30; hz <= 60; hz += 30) {
            unsigned int w = sizes[i][portrait ? 1 : 0] * backing, h = sizes[i][portrait ? 0 : 1] * backing;
            if (w == preferredWidth && h == preferredHeight && hz == rate) continue;
            [modes addObject:[(id<PDVDModeConstruction>)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                initWithWidth:w height:h refreshRate:hz]];
        }
    return [modes copy];
}

static bool applyTable(id display, NSArray *modes, char *error, size_t capacity) {
    id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(settings, NSSelectorFromString(@"setHiDPI:"), 1);
    ((void (*)(id, SEL, id))objc_msgSend)(settings, NSSelectorFromString(@"setModes:"), modes);
    if (!((BOOL (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(@"applySettings:"), settings))
        return failure(error, capacity, @"Virtual-display settings rejected.");
    return true;
}

uint64_t PDVDCreate(uint32_t width, uint32_t height, double rate, uint32_t serial, char *error, size_t capacity) {
    return PDVDCreateScaled(width, height, 1, rate, serial, error, capacity);
}

bool PDVDConfigure(uint64_t token, uint32_t width, uint32_t height, uint32_t scale, double rate, char *error, size_t capacity) {
    @autoreleasepool { @synchronized (registry()) {
        id display = ownedDisplays[@(token)];
        if (!display) return failure(error, capacity, @"That display lease has ended.");
        if (width < 600 || height < 600 || width > 1280 || height > 1280 || (scale != 1 && scale != 2)
            || (uint64_t)width * height * scale * scale > 4915200 || (rate != 30 && rate != 60))
            return failure(error, capacity, @"Invalid virtual display mode.");
        unsigned int orientation = width < height ? 90 : 0;
        @try {
            if (ownedOrientations[@(token)].unsignedIntValue != orientation) {
                NSArray *table = modeTable(width, height, scale, rate);
                if (!applyTable(display, table, error, capacity)) return false;
                ownedModeTables[@(token)] = table;
                ownedOrientations[@(token)] = @(orientation);
            }
        } @catch (NSException *exception) { return failure(error, capacity, @"Virtual orientation couldn't be applied."); }
        CGDirectDisplayID displayID = ((CGDirectDisplayID (*)(id, SEL))objc_msgSend)(display, NSSelectorFromString(@"displayID"));
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID,
            (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
        bool selected = false;
        if (modes) {
            for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                double hz = CGDisplayModeGetRefreshRate(mode);
                size_t w = CGDisplayModeGetWidth(mode), h = CGDisplayModeGetHeight(mode);
                size_t pw = CGDisplayModeGetPixelWidth(mode), ph = CGDisplayModeGetPixelHeight(mode);
                if (w == width && h == height && pw == width * scale && ph == height * scale
                    && (hz == 0 || fabs(hz - rate) < 0.1)) {
                    selected = CGDisplaySetDisplayMode(displayID, mode, NULL) == kCGErrorSuccess;
                    if (selected) break;
                }
            }
            CFRelease(modes);
        }
        return selected ? true : failure(error, capacity, @"That size, Retina scale or refresh mode isn't offered by this Mac.");
    } }
}

uint64_t PDVDCreateScaled(uint32_t width, uint32_t height, uint32_t scale, double refreshRate, uint32_t serial, char *error, size_t capacity) {
    @autoreleasepool {
      @synchronized (registry()) {
        if (ownedDisplays.count || width < 600 || height < 600 || width > 1280 || height > 1280 || (scale != 1 && scale != 2)
            || (uint64_t)width * height * scale * scale > 4915200
            || (refreshRate != 30 && refreshRate != 60) || nextToken == UINT64_MAX) {
            failure(error, capacity, @"Only one bounded display at 1x/2x and 30/60 Hz is supported."); return 0;
        }
        if (!PDVDAvailable(error, capacity)) return 0;
        @try {
            id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            void (*setObject)(id, SEL, id) = (void *)objc_msgSend;
            void (*setInteger)(id, SEL, unsigned int) = (void *)objc_msgSend;
            void (*setSize)(id, SEL, CGSize) = (void *)objc_msgSend;
            setObject(descriptor, NSSelectorFromString(@"setName:"), @"PocketDesk Virtual Display");
            setObject(descriptor, NSSelectorFromString(@"setDispatchQueue:"), dispatch_get_main_queue());
            setInteger(descriptor, NSSelectorFromString(@"setMaxPixelsWide:"), 2560);
            setInteger(descriptor, NSSelectorFromString(@"setMaxPixelsHigh:"), 2560);
            setInteger(descriptor, NSSelectorFromString(@"setVendorID:"), 0x5044);
            setInteger(descriptor, NSSelectorFromString(@"setProductID:"), 0x5052);
            setInteger(descriptor, NSSelectorFromString(@"setSerialNum:"), serial);
            // Keep the intended 1x desktop density consistent across sizes. A fixed small
            // physical size can make macOS choose a different desktop scale for larger modes.
            setSize(descriptor, NSSelectorFromString(@"setSizeInMillimeters:"), CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0));
            id display = [(id<PDVDDisplayConstruction>)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
            if (!display) { failure(error, capacity, @"WindowServer refused display creation."); return 0; }
            NSArray *modes = modeTable(width, height, scale, refreshRate);
            unsigned int orientation = width < height ? 90 : 0;
            if (!applyTable(display, modes, error, capacity)) return 0;
            CGDirectDisplayID (*getID)(id, SEL) = (void *)objc_msgSend;
            CGDirectDisplayID displayID = getID(display, NSSelectorFromString(@"displayID"));
            if (!displayID) { failure(error, capacity, @"Virtual display has no capture ID."); return 0; }
            uint64_t token = ++nextToken;
            ownedDisplays[@(token)] = display;
            ownedModeTables[@(token)] = modes; ownedOrientations[@(token)] = @(orientation);
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
        [ownedModeTables removeObjectForKey:@(token)];
        [ownedOrientations removeObjectForKey:@(token)];
        [ownedDisplays removeObjectForKey:@(token)];
        return true;
    } }
}
