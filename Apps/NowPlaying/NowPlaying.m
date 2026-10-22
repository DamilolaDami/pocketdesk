// Prints what's playing on this Mac as one line of JSON, then returns.
//
// Since macOS 15.4, MediaRemote (the private framework behind Control Center's Now Playing)
// answers only Apple's own processes. The host loads this library into /usr/bin/perl, which
// is one, and calls `pocketdesk_now_playing` as a perl XSUB:
//   perl -e 'use DynaLoader; ... dl_install_xsub("main::np", $sym); main::np()' <path>
// If Apple closes that door, it prints nothing and live tiles show volume alone.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));

// Called from perl as an XSUB: the two arguments are perl's interpreter and CV, unused.
__attribute__((visibility("default")))
void pocketdesk_now_playing(void *interpreter, void *cv) {
    void *mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetNowPlayingInfo get = mediaRemote ? (GetNowPlayingInfo)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    if (!get) return;

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
            playing = out;
        }
        answered = YES;
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
    while (!answered && deadline.timeIntervalSinceNow > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);

    NSData *json = [NSJSONSerialization dataWithJSONObject:(playing ?: @{}) options:0 error:nil];
    if (json) {
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}
