// ECDICT pronunciation helper.
//
// The native Look Up panel only forwards mouseover to dictionary content (it
// swallows clicks), so playback is triggered by a CSS background-image request
// to this local server: each mouseover refreshes a unique URL and the host must
// issue a fresh request instead of reusing a cached image. Dictionary.app uses
// the compact button and plays the entry's embedded MP3 directly.
//
// The server only ever plays recordings listed in the bundle's
// audio-manifest.json after verifying their SHA-256 up front.
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static const uint16_t kPort = 17943;
static NSData *TransparentGIF(void) {
    return [[NSData alloc] initWithBase64EncodedString:@"R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=" options:0];
}

@interface ECDICTAudioServer : NSObject <AVAudioPlayerDelegate>
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *clips;
@property(nonatomic, strong) AVAudioPlayer *player;
@property(nonatomic, strong) NSDate *lastStart;
@property(nonatomic, copy) NSString *lastClipID;
- (instancetype)initWithResources:(NSURL *)resources error:(NSError **)error;
- (void)start;
@end

@implementation ECDICTAudioServer

- (instancetype)initWithResources:(NSURL *)resources error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSURL *manifestURL = [resources URLByAppendingPathComponent:@"audio-manifest.json"];
    NSData *manifestData = [NSData dataWithContentsOfURL:manifestURL options:0 error:error];
    if (!manifestData) return nil;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error];
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"recordings"] isKindOfClass:NSArray.class]) {
        if (error) *error = [NSError errorWithDomain:@"ECDICTAudioHelper" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid audio manifest"}];
        return nil;
    }

    NSMutableDictionary *clips = [NSMutableDictionary dictionary];
    NSRegularExpression *safeID = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9-]+$" options:0 error:nil];
    for (NSDictionary *recording in manifest[@"recordings"]) {
        NSString *clipID = recording[@"id"];
        if (![clipID isKindOfClass:NSString.class] || [safeID numberOfMatchesInString:clipID options:0 range:NSMakeRange(0, clipID.length)] != 1) continue;
        NSArray *derivatives = recording[@"derivatives"];
        NSDictionary *mp3 = nil;
        for (NSDictionary *derivative in derivatives) {
            if ([derivative[@"format"] isEqual:@"mp3"]) { mp3 = derivative; break; }
        }
        NSString *expectedSHA = mp3[@"sha256"];
        if (![expectedSHA isKindOfClass:NSString.class] || expectedSHA.length != 64) continue;
        NSURL *audioURL = [[resources URLByAppendingPathComponent:@"Audio" isDirectory:YES] URLByAppendingPathComponent:[clipID stringByAppendingString:@".mp3"]];
        NSData *audio = [NSData dataWithContentsOfURL:audioURL options:0 error:nil];
        if (!audio) continue;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(audio.bytes, (CC_LONG)audio.length, digest);
        NSMutableString *actualSHA = [NSMutableString stringWithCapacity:64];
        for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [actualSHA appendFormat:@"%02x", digest[i]];
        if (![actualSHA isEqualToString:expectedSHA]) {
            if (error) *error = [NSError errorWithDomain:@"ECDICTAudioHelper" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"SHA-256 mismatch for %@", clipID]}];
            return nil;
        }
        clips[clipID] = @{ @"url": audioURL, @"sha256": expectedSHA };
    }
    if (clips.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"ECDICTAudioHelper" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No verified MP3 assets found"}];
        return nil;
    }
    self.clips = clips;
    return self;
}

- (void)playClip:(NSString *)clipID {
    NSDictionary *clip = self.clips[clipID];
    if (!clip) { NSLog(@"Rejected unknown audio id: %@", clipID); return; }
    // A single hover can reach here twice (the host may fire an extra
    // mouseover). Ignore a repeat of the same clip within 350 ms so the clip is
    // not restarted mid-word; a deliberate re-hover is slower than that.
    NSDate *now = [NSDate date];
    if (self.lastClipID && [self.lastClipID isEqualToString:clipID] &&
        self.lastStart && [now timeIntervalSinceDate:self.lastStart] < 0.35) {
        NSLog(@"IGNORE duplicate %@", clipID);
        return;
    }
    self.lastClipID = clipID;
    self.lastStart = now;
    NSError *error = nil;
    [self.player stop];
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:clip[@"url"] error:&error];
    self.player.delegate = self;
    if (!self.player || ![self.player prepareToPlay] || ![self.player play]) {
        NSLog(@"Playback failed for %@: %@", clipID, error.localizedDescription ?: @"AVAudioPlayer did not start");
        return;
    }
    NSLog(@"PLAY %@", clipID);
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    NSLog(@"FINISH %@ success=%@", player.url.lastPathComponent, flag ? @"true" : @"false");
}

- (void)sendStatus:(NSString *)status type:(NSString *)type body:(NSData *)body fd:(int)fd {
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n", status, type, (unsigned long)body.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:body];
    const uint8_t *bytes = response.bytes;
    NSUInteger remaining = response.length;
    while (remaining > 0) {
        ssize_t written = send(fd, bytes, remaining, 0);
        if (written <= 0) break;
        bytes += written;
        remaining -= (NSUInteger)written;
    }
}

- (void)handleClient:(int)fd {
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    struct timeval timeout = {3, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    NSMutableData *requestData = [NSMutableData data];
    uint8_t buffer[2048];
    NSData *headerEnd = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    while (requestData.length < 8192) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
        if (count <= 0) break;
        [requestData appendBytes:buffer length:(NSUInteger)count];
        if ([requestData rangeOfData:headerEnd options:0 range:NSMakeRange(0, requestData.length)].location != NSNotFound) break;
    }
    NSString *request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
    NSString *firstLine = [[request componentsSeparatedByString:@"\r\n"] firstObject];
    NSArray<NSString *> *parts = [firstLine componentsSeparatedByString:@" "];
    if (parts.count < 2 || ![parts[0] isEqualToString:@"GET"]) {
        [self sendStatus:@"400 Bad Request" type:@"text/plain" body:[NSData data] fd:fd];
        close(fd);
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:parts[1]]];
    NSString *path = components.path ?: @"";
    if ([path isEqualToString:@"/health"]) {
        [self sendStatus:@"200 OK" type:@"text/plain; charset=utf-8" body:[@"ECDICT audio helper ready" dataUsingEncoding:NSUTF8StringEncoding] fd:fd];
    } else if ([path hasPrefix:@"/audio/play/"]) {
        NSString *clipID = [path substringFromIndex:@"/audio/play/".length];
        if (self.clips[clipID]) {
            // Log only our fixed event names, never arbitrary URL/header data.
            NSString *event = @"unspecified";
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqual:@"event"] && [@[@"css", @"hover", @"dwell", @"click", @"over", @"down", @"move", @"press", @"link", @"smoke"] containsObject:item.value]) event = item.value;
            }
            NSLog(@"REQUEST %@ event=%@", clipID, event);
            dispatch_async(dispatch_get_main_queue(), ^{ [self playClip:clipID]; });
            [self sendStatus:@"200 OK" type:@"image/gif" body:TransparentGIF() fd:fd];
        } else {
            [self sendStatus:@"404 Not Found" type:@"image/gif" body:TransparentGIF() fd:fd];
        }
    } else {
        [self sendStatus:@"404 Not Found" type:@"image/gif" body:TransparentGIF() fd:fd];
    }
    close(fd);
}

- (void)start {
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) { perror("socket"); exit(1); }
    int reuse = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(kPort);
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(server, 16) != 0) {
        perror("bind/listen 127.0.0.1:17943");
        close(server);
        exit(1);
    }
    NSLog(@"ECDICT audio helper listening on 127.0.0.1:%u with %lu verified clips", kPort, (unsigned long)self.clips.count);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_async(queue, ^{
        while (YES) {
            int client = accept(server, NULL, NULL);
            if (client >= 0) dispatch_async(queue, ^{ [self handleClient:client]; });
        }
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: ECDICTAudioHelper <dictionary Contents/Resources directory>\n");
            return 64;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        ECDICTAudioServer *server = [[ECDICTAudioServer alloc] initWithResources:[NSURL fileURLWithPath:path isDirectory:YES] error:nil];
        if (!server) { fprintf(stderr, "Unable to load and verify local audio assets\n"); return 1; }
        [server start];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
