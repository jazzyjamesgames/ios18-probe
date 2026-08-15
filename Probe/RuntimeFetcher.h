#import <Foundation/Foundation.h>

// Downloads a chunked, gzipped tar of a real simulator RuntimeRoot from a
// GitHub release and extracts it into destDir, streaming so that peak disk
// usage stays at one chunk rather than the whole archive.
//
// Blocking by design: the probe already runs on a background queue and
// serialises its steps, and a callback-based API would only complicate that.
@interface RuntimeFetcher : NSObject

// Returns YES on success. `progress` is called with human-readable status
// lines (already newline-free) and may be nil.
+ (BOOL)fetchTag:(NSString *)tag
             into:(NSString *)destDir
         progress:(void (^)(NSString *line))progress
            error:(NSError **)error;

@end
