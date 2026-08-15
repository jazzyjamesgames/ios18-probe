#import <Foundation/Foundation.h>

// Downloads a chunked, gzipped tar of a real simulator RuntimeRoot from a
// GitHub release and extracts it into destDir, streaming so that peak disk
// usage stays at one chunk rather than the whole archive.
//
// Blocking by design: the probe already runs on a background queue and
// serialises its steps, and a callback-based API would only complicate that.
@interface RuntimeFetcher : NSObject

// Returns YES on success.
//
// `progress` reports overall completion in [0,1] plus a one-line status, and
// may be called very frequently -- callers should throttle UI updates rather
// than assume otherwise. `fraction` is negative when the total isn't known
// yet (before the manifest is read).
//
// `log` receives durable, one-per-event lines worth keeping in the transcript.
+ (BOOL)fetchTag:(NSString *)tag
             into:(NSString *)destDir
         progress:(void (^)(double fraction, NSString *status))progress
              log:(void (^)(NSString *line))log
            error:(NSError **)error;

@end
