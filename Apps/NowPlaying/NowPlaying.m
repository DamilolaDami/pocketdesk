// Prints what's playing on this Mac as one line of JSON, then returns.
//
// Since macOS 15.4, MediaRemote (the private framework behind Control Center's Now Playing)
// answers only Apple's own processes. The host loads this library into /usr/bin/perl, which
// is one, and calls `pocketdesk_now_playing` as a perl XSUB:
//   perl -e 'use DynaLoader; ... dl_install_xsub("main::np", $sym); main::np()' <path>
// If Apple closes that door, it prints nothing and live tiles show volume alone.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <libproc.h>

// Matches NowPlaying.artworkSize: covers can be megabytes, and this runs every second.
static const int kArtworkSize = 240;

// The cover shrunk to kArtworkSize as base64 JPEG, or nil.
static NSString *ArtworkString(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @(kArtworkSize),
                              (id)kCGImageSourceCreateThumbnailWithTransform: @YES};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return nil;
    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
    BOOL done = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.75});
        done = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    return done ? [jpeg base64EncodedStringWithOptions:0] : nil;
}

typedef void (*GetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetNowPlayingPID)(dispatch_queue_t, void (^)(int));

// The outermost .app around a process: a browser's helper process plays the video, but the
// person knows the browser.
static NSString *AppPath(int pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (pid <= 0 || proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    NSString *full = [NSString stringWithUTF8String:path];
    NSRange app = [full rangeOfString:@".app/"];
    return app.location == NSNotFound ? nil : [full substringToIndex:app.location + 4];
}

// Called from perl as an XSUB: the two arguments are perl's interpreter and CV, unused.
__attribute__((visibility("default")))
void pocketdesk_now_playing(void *interpreter, void *cv) {
    void *mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetNowPlayingInfo get = mediaRemote ? (GetNowPlayingInfo)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    if (!get) return;
    GetNowPlayingPID getPID = (GetNowPlayingPID)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationPID");

    __block BOOL answered = NO;
    __block NSDictionary *playing = nil;
    // The answer comes on the main queue, so keep its run loop turning until it does.
    get(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *all = (__bridge NSDictionary *)info;
        NSString *title = all[@"kMRMediaRemoteNowPlayingInfoTitle"];
        if ([title isKindOfClass:[NSString class]] && title.length > 0) {
            NSMutableDictionary *out = [@{@"title": title} mutableCopy];
            NSString *artist = all[@"kMRMediaRemoteNowPlayingInfoArtist"];
            if ([artist isKindOfClass:[NSString class]] && artist.length > 0) out[@"artist"] = artist;
            NSNumber *rate = all[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            out[@"isPlaying"] = @((BOOL)([rate isKindOfClass:[NSNumber class]] && rate.doubleValue > 0));
            out[@"rate"] = rate ?: @0;
            for (NSString *name in @[@"ElapsedTime", @"Duration"]) {
                id value = all[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:name]];
                if ([value isKindOfClass:[NSNumber class]] && isfinite([value doubleValue]))
                    out[[name isEqualToString:@"ElapsedTime"] ? @"elapsed" : @"duration"] = value;
            }
            id timestamp = all[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([timestamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([timestamp timeIntervalSince1970]);
            NSData *cover = all[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSString *artwork = [cover isKindOfClass:[NSData class]] ? ArtworkString(cover) : nil;
            if (artwork) out[@"artwork"] = artwork;
            playing = out;
        }
        answered = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
    while (!answered && deadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);

    if (playing && getPID) {
        __block BOOL found = NO;
        __block int pid = 0;
        getPID(dispatch_get_main_queue(), ^(int value) {
            pid = value;
            found = YES;
        });
        NSDate *pidDeadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
        while (!found && pidDeadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        NSString *app = AppPath(pid);
        if (app) {
            NSMutableDictionary *out = [playing mutableCopy];
            out[@"app"] = app;
            playing = out;
        }
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:(playing ?: @{}) options:0 error:nil];
    if (json) {
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}
