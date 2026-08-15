// Streaming download + gzip + tar extraction of a real simulator RuntimeRoot.
//
// This file is the reason the whole "get a real runtime onto the phone" plan
// is tractable. Apple ships runtimes as UDIF disk images wrapping APFS
// volumes; macOS mounts those with one call, but iOS has no hdiutil, no
// mount, and no APFS reader available to an app, so consuming the dmg
// directly would mean writing a UDIF parser AND an APFS reader. Repacking to
// tar.gz in CI reduces the device side to two well-understood things: zlib
// (which iOS already ships) and the tar format (512-byte headers).
//
// Three constraints shaped the design:
//
//   1. Peak disk. The extracted tree is ~16GB and the archive several GB.
//      Downloading everything and then extracting would need both at once.
//      Instead each chunk is downloaded, fed through inflate straight into
//      the tar writer, and deleted before the next is fetched -- so peak
//      usage is one chunk plus the tree.
//
//   2. Chunk boundaries are arbitrary. The gzip stream is split at fixed byte
//      offsets with no regard for gzip or tar structure, so a tar header can
//      straddle two chunks. Both the inflate stream and the tar parser
//      therefore persist across chunks as explicit state machines rather than
//      per-chunk operations.
//
//   3. Re-runs must not accumulate. destDir is wiped before the first chunk,
//      and each chunk file is deleted immediately after use -- otherwise a
//      second attempt could leave two 16GB trees on the device.
#import "RuntimeFetcher.h"
#import <zlib.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kReleaseURLFormat =
    @"https://github.com/jazzyjamesgames/ios18-probe/releases/download/%@/%@";

// --- tar parsing -----------------------------------------------------------
// Only the subset bsdtar actually emits for this payload: regular files,
// directories, symlinks, and the pax/GNU long-name records it uses when a
// path exceeds the 100-byte legacy field.

typedef NS_ENUM(NSInteger, TarState) {
  TarStateHeader = 0,  // accumulating a 512-byte header
  TarStateBody,        // writing file contents
  TarStateSkip,        // discarding content we don't act on (pax metadata)
};

@interface TarExtractor : NSObject
@property(nonatomic, copy) NSString *destDir;
@property(nonatomic, assign) TarState state;
@property(nonatomic, strong) NSMutableData *headerBuf;
@property(nonatomic, strong) NSFileHandle *currentFile;
@property(nonatomic, assign) unsigned long long remaining;   // bytes left in body
@property(nonatomic, assign) unsigned long long padding;     // bytes to 512 boundary
@property(nonatomic, copy) NSString *pendingLongName;        // from pax/GNU record
@property(nonatomic, strong) NSMutableData *pendingLongNameBuf;
@property(nonatomic, assign) BOOL pendingIsPax;  // distinguishes pax 'x' from GNU 'L'
@property(nonatomic, assign) NSInteger fileCount;
@property(nonatomic, copy) NSString *lastError;
@end

@implementation TarExtractor

- (instancetype)initWithDestDir:(NSString *)destDir {
  if ((self = [super init])) {
    _destDir = [destDir copy];
    _headerBuf = [NSMutableData data];
    _state = TarStateHeader;
  }
  return self;
}

static unsigned long long tarOctal(const char *field, size_t len) {
  // Fields are octal ASCII, space/NUL padded. GNU also uses a base-256
  // extension (high bit set) for large values; handle it since a runtime
  // contains files past the 8GB octal ceiling only in theory, but the dyld
  // shared cache is large enough to be worth not guessing about.
  if (len && (field[0] & 0x80)) {
    unsigned long long v = 0;
    for (size_t i = 1; i < len; i++) v = (v << 8) | (unsigned char)field[i];
    return v;
  }
  unsigned long long v = 0;
  for (size_t i = 0; i < len; i++) {
    char c = field[i];
    if (c < '0' || c > '7') break;
    v = v * 8 + (unsigned long long)(c - '0');
  }
  return v;
}

- (BOOL)ensureParentDirectoryFor:(NSString *)path {
  NSString *parent = [path stringByDeletingLastPathComponent];
  if (!parent.length) return YES;
  return [[NSFileManager defaultManager] createDirectoryAtPath:parent
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:NULL];
}

// Returns NO on a fatal error. `consumed` reports how much of `bytes` was used.
- (BOOL)consume:(const uint8_t *)bytes length:(size_t)length {
  size_t offset = 0;
  NSFileManager *fm = [NSFileManager defaultManager];

  while (offset < length) {
    if (self.state == TarStateHeader) {
      size_t need = 512 - self.headerBuf.length;
      size_t take = MIN(need, length - offset);
      [self.headerBuf appendBytes:bytes + offset length:take];
      offset += take;
      if (self.headerBuf.length < 512) return YES;  // header straddles chunks

      const char *h = (const char *)self.headerBuf.bytes;

      // Two consecutive zero blocks mark end of archive; a single zero block
      // is enough to treat as "done" for our purposes.
      BOOL allZero = YES;
      for (int i = 0; i < 512; i++) {
        if (h[i] != 0) { allZero = NO; break; }
      }
      if (allZero) {
        [self.headerBuf setLength:0];
        continue;
      }

      char nameField[101] = {0};
      memcpy(nameField, h, 100);
      NSString *name = self.pendingLongName
                           ?: [NSString stringWithUTF8String:nameField]
                           ?: @"";
      self.pendingLongName = nil;

      // ustar prefix field extends the path when the name alone won't fit.
      if (!self.pendingLongName && h[257] == 'u' && h[258] == 's') {
        char prefixField[156] = {0};
        memcpy(prefixField, h + 345, 155);
        if (prefixField[0]) {
          NSString *prefix = [NSString stringWithUTF8String:prefixField];
          if (prefix.length) name = [prefix stringByAppendingPathComponent:name];
        }
      }

      unsigned long long size = tarOctal(h + 124, 12);
      char type = h[156];
      [self.headerBuf setLength:0];

      self.remaining = size;
      self.padding = (512 - (size % 512)) % 512;

      NSString *outPath = [self.destDir stringByAppendingPathComponent:name];

      if (type == 'L' || type == 'K') {
        // GNU long name/link: the NEXT entry's path is this record's body.
        self.pendingLongNameBuf = [NSMutableData data];
        self.pendingIsPax = NO;
        self.state = TarStateSkip;  // captured in the skip branch below
        continue;
      }
      if (type == 'x' || type == 'g') {
        // pax extended header. Its body holds "len key=value\n" records, and
        // ONLY a path= record renames the next entry -- linkpath= and friends
        // must not be mistaken for one (see the parsing branch below).
        self.pendingLongNameBuf = [NSMutableData data];
        self.pendingIsPax = YES;
        self.state = TarStateSkip;
        continue;
      }

      if (type == '5') {  // directory
        [fm createDirectoryAtPath:outPath
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:NULL];
        self.state = (self.remaining > 0) ? TarStateSkip : TarStateHeader;
        continue;
      }

      if (type == '2') {  // symlink
        char linkField[101] = {0};
        memcpy(linkField, h + 157, 100);
        NSString *target = [NSString stringWithUTF8String:linkField];
        if (target.length) {
          [self ensureParentDirectoryFor:outPath];
          [fm removeItemAtPath:outPath error:NULL];
          [fm createSymbolicLinkAtPath:outPath withDestinationPath:target error:NULL];
        }
        self.state = (self.remaining > 0) ? TarStateSkip : TarStateHeader;
        continue;
      }

      if (type == '0' || type == '\0') {  // regular file
        [self ensureParentDirectoryFor:outPath];
        [fm removeItemAtPath:outPath error:NULL];
        if (![fm createFileAtPath:outPath contents:nil attributes:nil]) {
          self.lastError = [NSString stringWithFormat:@"cannot create %@", outPath];
          return NO;
        }
        self.currentFile = [NSFileHandle fileHandleForWritingAtPath:outPath];
        if (!self.currentFile) {
          self.lastError = [NSString stringWithFormat:@"cannot open %@", outPath];
          return NO;
        }
        self.fileCount++;
        self.state = (self.remaining > 0) ? TarStateBody : TarStateHeader;
        if (self.remaining == 0) {
          [self.currentFile closeFile];
          self.currentFile = nil;
          // still need to consume padding, which is zero here
        }
        continue;
      }

      // Anything else (block/char devices, fifos): skip its body.
      self.state = (self.remaining > 0) ? TarStateSkip : TarStateHeader;
      continue;
    }

    if (self.state == TarStateBody) {
      size_t take = (size_t)MIN((unsigned long long)(length - offset), self.remaining);
      @try {
        [self.currentFile writeData:[NSData dataWithBytesNoCopy:(void *)(bytes + offset)
                                                         length:take
                                                   freeWhenDone:NO]];
      } @catch (NSException *ex) {
        self.lastError = [NSString stringWithFormat:@"write failed: %@", ex.reason];
        return NO;
      }
      offset += take;
      self.remaining -= take;
      if (self.remaining == 0) {
        [self.currentFile closeFile];
        self.currentFile = nil;
        self.state = TarStateSkip;  // consume padding
        self.remaining = self.padding;
        self.padding = 0;
        if (self.remaining == 0) self.state = TarStateHeader;
      }
      continue;
    }

    // TarStateSkip: discard `remaining` bytes, capturing them first if this
    // is a long-name / pax record whose body we need.
    size_t take = (size_t)MIN((unsigned long long)(length - offset), self.remaining);
    if (self.pendingLongNameBuf) {
      [self.pendingLongNameBuf appendBytes:bytes + offset length:take];
    }
    offset += take;
    self.remaining -= take;
    if (self.remaining == 0) {
      if (self.pendingLongNameBuf) {
        NSString *raw = [[NSString alloc] initWithData:self.pendingLongNameBuf
                                              encoding:NSUTF8StringEncoding];
        self.pendingLongNameBuf = nil;
        if (raw.length) {
          NSString *path = nil;
          if (self.pendingIsPax) {
            // pax body is a series of "<len> key=value\n" records. ONLY a
            // path= record renames the next entry.
            //
            // The first version fell through to the GNU branch whenever no
            // " path=" was found, which meant a pax header carrying only
            // linkpath= (very common -- every symlink with a long target) had
            // its entire raw body adopted as the next entry's NAME. That's
            // where the junk "134 linkpath=" entries in RuntimeRoot came from:
            // roughly twenty top-level symlinks were created under garbage
            // names instead of as links.
            for (NSString *record in [raw componentsSeparatedByString:@"\n"]) {
              NSRange sp = [record rangeOfString:@" "];
              if (sp.location == NSNotFound) continue;
              NSString *kv = [record substringFromIndex:NSMaxRange(sp)];
              if ([kv hasPrefix:@"path="]) {
                path = [kv substringFromIndex:5];
                break;
              }
            }
          } else {
            // GNU 'L': body is the raw path, NUL-terminated.
            path = [raw stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:
                                                 @"\0\n"]];
          }
          if (path.length) self.pendingLongName = path;
        }
        self.pendingIsPax = NO;
      }
      // Padding after these records still has to go.
      if (self.padding) {
        self.remaining = self.padding;
        self.padding = 0;
      } else {
        self.state = TarStateHeader;
      }
    }
  }
  return YES;
}

- (void)finish {
  [self.currentFile closeFile];
  self.currentFile = nil;
}

@end

// --- fetcher ---------------------------------------------------------------

// Downloads to a FILE, not memory, and reports byte-level progress.
//
// The first version used dataTaskWithURL, which buffers the whole response in
// RAM. That was survivable for a 6.7MB test slice and fatal for a real 1.9GB
// chunk -- a phone will not hold that. downloadTask streams to disk, which
// also gives per-byte progress callbacks for free.
@interface RFDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) NSString *destPath;
@property(nonatomic, assign) NSInteger statusCode;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic, copy) void (^byteProgress)(unsigned long long written,
                                                unsigned long long expected);
@end

@implementation RFDownloadDelegate

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalWritten
    totalBytesExpectedToWrite:(int64_t)totalExpected {
  if ([task.response isKindOfClass:[NSHTTPURLResponse class]]) {
    self.statusCode = ((NSHTTPURLResponse *)task.response).statusCode;
  }
  if (self.byteProgress) {
    self.byteProgress((unsigned long long)totalWritten,
                      (unsigned long long)MAX((int64_t)0, totalExpected));
  }
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
    didFinishDownloadingToURL:(NSURL *)location {
  if ([task.response isKindOfClass:[NSHTTPURLResponse class]]) {
    self.statusCode = ((NSHTTPURLResponse *)task.response).statusCode;
  }
  // Must move synchronously here: the temp file is deleted as soon as this
  // returns.
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath:self.destPath error:NULL];
  NSError *moveErr = nil;
  if (![fm moveItemAtURL:location
                   toURL:[NSURL fileURLWithPath:self.destPath]
                   error:&moveErr]) {
    self.failure = moveErr;
  }
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  if (error) self.failure = error;
  if ([task.response isKindOfClass:[NSHTTPURLResponse class]]) {
    self.statusCode = ((NSHTTPURLResponse *)task.response).statusCode;
  }
  dispatch_semaphore_signal(self.done);
}

@end

@implementation RuntimeFetcher

// Small responses (the manifest) still come back in memory; only chunks need
// the streaming path.
+ (NSData *)downloadSmallURL:(NSURL *)url statusCode:(NSInteger *)statusOut {
  __block NSData *result = nil;
  __block NSInteger status = 0;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);

  NSURLSessionConfiguration *cfg =
      [NSURLSessionConfiguration ephemeralSessionConfiguration];
  cfg.timeoutIntervalForRequest = 60;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
  NSURLSessionDataTask *task =
      [session dataTaskWithURL:url
             completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
               if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                 status = ((NSHTTPURLResponse *)response).statusCode;
               }
               result = data;
               dispatch_semaphore_signal(done);
             }];
  [task resume];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  [session finishTasksAndInvalidate];
  if (statusOut) *statusOut = status;
  return result;
}

+ (NSInteger)downloadURL:(NSURL *)url
                  toPath:(NSString *)path
            byteProgress:(void (^)(unsigned long long, unsigned long long))byteProgress
                   error:(NSError **)error {
  RFDownloadDelegate *delegate = [RFDownloadDelegate new];
  delegate.destPath = path;
  delegate.done = dispatch_semaphore_create(0);
  delegate.byteProgress = byteProgress;

  NSURLSessionConfiguration *cfg =
      [NSURLSessionConfiguration ephemeralSessionConfiguration];
  cfg.timeoutIntervalForRequest = 120;
  cfg.timeoutIntervalForResource = 7200;  // multi-GB chunks on phone networks
  NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg
                                                       delegate:delegate
                                                  delegateQueue:nil];
  [[session downloadTaskWithURL:url] resume];
  dispatch_semaphore_wait(delegate.done, DISPATCH_TIME_FOREVER);
  [session finishTasksAndInvalidate];

  if (error) *error = delegate.failure;
  return delegate.statusCode;
}

+ (NSString *)sha256OfFile:(NSString *)path {
  NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!fh) return nil;
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  while (YES) {
    @autoreleasepool {
      NSData *block = [fh readDataOfLength:1024 * 1024];
      if (!block.length) break;
      CC_SHA256_Update(&ctx, block.bytes, (CC_LONG)block.length);
    }
  }
  [fh closeFile];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(digest, &ctx);
  NSMutableString *hex = [NSMutableString string];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    [hex appendFormat:@"%02x", digest[i]];
  }
  return hex;
}

+ (BOOL)fetchTag:(NSString *)tag
             into:(NSString *)destDir
         progress:(void (^)(double, NSString *))progress
              log:(void (^)(NSString *))log
            error:(NSError **)error {
  NSFileManager *fm = [NSFileManager defaultManager];
#define RFLOG(fmt, ...) if (log) log([NSString stringWithFormat:fmt, ##__VA_ARGS__])
#define RFPROGRESS(f, fmt, ...) \
  if (progress) progress((f), [NSString stringWithFormat:fmt, ##__VA_ARGS__])

  // Wipe first: a previous attempt could otherwise leave a second copy of a
  // multi-GB tree behind.
  if ([fm fileExistsAtPath:destDir]) {
    RFLOG(@"removing previous download at %@", destDir);
    [fm removeItemAtPath:destDir error:NULL];
  }
  [fm createDirectoryAtPath:destDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];

  // Keep a multi-GB runtime out of iCloud backup. Without this, a tree this
  // size under the app container would be queued for backup, which is both
  // hostile to the user's iCloud storage and pointless -- it's re-downloadable.
  NSURL *destURL = [NSURL fileURLWithPath:destDir];
  NSError *excludeErr = nil;
  if (![destURL setResourceValue:@YES
                          forKey:NSURLIsExcludedFromBackupKey
                           error:&excludeErr]) {
    RFLOG(@"warning: could not exclude from backup: %@", excludeErr.localizedDescription);
  } else {
    RFLOG(@"marked excluded from iCloud backup");
  }

  // Report free space before starting: the full tree is ~16GB, and finding
  // that out by filling the device is a bad way to find out.
  NSDictionary *fsAttrs = [fm attributesOfFileSystemForPath:destDir error:NULL];
  unsigned long long freeBytes =
      [fsAttrs[NSFileSystemFreeSize] unsignedLongLongValue];
  RFLOG(@"free space: %.1f GB", freeBytes / 1073741824.0);

  // The manifest gives the chunk count and total size up front, which is what
  // makes real progress reporting possible -- and its per-chunk sha256 lets
  // each transfer be verified rather than assumed.
  NSMutableArray<NSString *> *expectedHashes = [NSMutableArray array];
  NSInteger manifestChunks = 0;
  unsigned long long manifestTotal = 0;
  {
    NSURL *manifestURL =
        [NSURL URLWithString:[NSString stringWithFormat:kReleaseURLFormat, tag,
                                                        @"manifest.txt"]];
    NSInteger status = 0;
    NSData *data = [self downloadSmallURL:manifestURL statusCode:&status];
    if (status == 200 && data.length) {
      NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@" "];
        if (parts.count == 2 && [parts[0] isEqualToString:@"chunks"]) {
          manifestChunks = [parts[1] integerValue];
        } else if (parts.count == 2 && [parts[0] isEqualToString:@"total"]) {
          manifestTotal = strtoull([parts[1] UTF8String], NULL, 10);
        } else if (parts.count == 3) {
          [expectedHashes addObject:parts[2]];
        }
      }
      RFLOG(@"manifest: %ld chunks, %.2f GB total", (long)manifestChunks,
            manifestTotal / 1073741824.0);
      if (manifestTotal > 0 && freeBytes > 0 && freeBytes < manifestTotal * 3) {
        // x3 is a rough guide: compressed download + extracted tree, which for
        // this payload expands several-fold.
        RFLOG(@"WARNING: free space looks tight for this download");
      }
    } else {
      RFLOG(@"no manifest (HTTP %ld) -- progress will be chunk-based only",
            (long)status);
    }
  }

  // One inflate stream and one tar parser for the WHOLE archive: chunk
  // boundaries fall at arbitrary byte offsets, so neither can be per-chunk.
  z_stream strm;
  memset(&strm, 0, sizeof(strm));
  if (inflateInit2(&strm, 16 + MAX_WBITS) != Z_OK) {  // 16 = expect gzip header
    if (error) {
      *error = [NSError errorWithDomain:@"RuntimeFetcher"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey : @"inflateInit2 failed"}];
    }
    return NO;
  }

  TarExtractor *tar = [[TarExtractor alloc] initWithDestDir:destDir];
  NSString *scratch = [destDir stringByAppendingPathComponent:@"__chunk"];
  const size_t outCap = 1024 * 1024;
  uint8_t *outBuf = malloc(outCap);
  BOOL ok = YES;
  NSInteger chunkIndex = 0;
  unsigned long long totalIn = 0, totalOut = 0;

  while (ok) {
    NSString *assetName =
        [NSString stringWithFormat:@"runtimeroot.tar.gz.%03ld", (long)chunkIndex];
    NSURL *url = [NSURL URLWithString:
                            [NSString stringWithFormat:kReleaseURLFormat, tag, assetName]];

    unsigned long long baseBytes = totalIn;
    NSInteger displayTotal = manifestChunks > 0 ? manifestChunks : (chunkIndex + 1);
    RFPROGRESS(manifestTotal ? (double)baseBytes / (double)manifestTotal : -1.0,
               @"chunk %ld/%ld: connecting", (long)(chunkIndex + 1), (long)displayTotal);

    NSError *dlErr = nil;
    NSInteger status = [self
        downloadURL:url
             toPath:scratch
       byteProgress:^(unsigned long long written, unsigned long long expected) {
         double frac = -1.0;
         if (manifestTotal > 0) {
           frac = (double)(baseBytes + written) / (double)manifestTotal;
         } else if (expected > 0) {
           frac = (double)written / (double)expected;
         }
         RFPROGRESS(frac, @"chunk %ld/%ld: %.1f / %.1f MB", (long)(chunkIndex + 1),
                    (long)displayTotal, written / 1048576.0, expected / 1048576.0);
       }
              error:&dlErr];

    if (status == 404) {
      // Walking until a 404 is how the chunk count is discovered when there's
      // no manifest; the CI side clears stale assets so a leftover chunk from
      // an earlier, larger run can't extend the walk and corrupt the stream.
      RFLOG(@"no %@ (end of archive)", assetName);
      [fm removeItemAtPath:scratch error:NULL];
      break;
    }
    if (status != 200 || dlErr) {
      if (error) {
        *error = [NSError errorWithDomain:@"RuntimeFetcher"
                                     code:2
                                 userInfo:@{
                                   NSLocalizedDescriptionKey : [NSString
                                       stringWithFormat:@"%@ -> HTTP %ld%@", assetName,
                                                        (long)status,
                                                        dlErr ? [@": " stringByAppendingString:
                                                                     dlErr.localizedDescription]
                                                              : @""]
                                 }];
      }
      ok = NO;
      break;
    }

    unsigned long long chunkSize =
        [[fm attributesOfItemAtPath:scratch error:NULL] fileSize];

    // Verify against the manifest before feeding it to inflate: a corrupt
    // chunk would otherwise surface as a baffling tar or inflate error much
    // later, with nothing pointing at the transfer as the cause.
    if (chunkIndex < (NSInteger)expectedHashes.count) {
      RFPROGRESS(manifestTotal ? (double)(baseBytes + chunkSize) / (double)manifestTotal : -1.0,
                 @"chunk %ld/%ld: verifying", (long)(chunkIndex + 1), (long)displayTotal);
      NSString *actual = [self sha256OfFile:scratch];
      NSString *expected = expectedHashes[chunkIndex];
      if (actual && ![actual isEqualToString:expected]) {
        if (error) {
          *error = [NSError errorWithDomain:@"RuntimeFetcher"
                                       code:5
                                   userInfo:@{
                                     NSLocalizedDescriptionKey : [NSString
                                         stringWithFormat:@"%@ sha256 mismatch\n  expected %@\n  got      %@",
                                                          assetName, expected, actual]
                                   }];
        }
        [fm removeItemAtPath:scratch error:NULL];
        ok = NO;
        break;
      }
      RFLOG(@"%@ verified (%llu bytes)", assetName, chunkSize);
    } else {
      RFLOG(@"%@ downloaded (%llu bytes, no hash to check)", assetName, chunkSize);
    }

    totalIn += chunkSize;
    RFPROGRESS(manifestTotal ? (double)totalIn / (double)manifestTotal : -1.0,
               @"chunk %ld/%ld: extracting", (long)(chunkIndex + 1), (long)displayTotal);

    // Read the chunk back in 1MB blocks rather than loading it whole: a real
    // chunk is ~1.9GB and would not fit in memory on a phone.
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:scratch];
    if (!fh) {
      if (error) {
        *error = [NSError errorWithDomain:@"RuntimeFetcher"
                                     code:6
                                 userInfo:@{NSLocalizedDescriptionKey :
                                                @"cannot reopen downloaded chunk"}];
      }
      ok = NO;
      break;
    }

    while (ok) {
      @autoreleasepool {
        NSData *block = [fh readDataOfLength:4 * 1024 * 1024];
        if (!block.length) break;

        strm.next_in = (Bytef *)block.bytes;
        strm.avail_in = (uInt)block.length;
        while (strm.avail_in > 0) {
          strm.next_out = outBuf;
          strm.avail_out = (uInt)outCap;
          int zr = inflate(&strm, Z_NO_FLUSH);
          if (zr != Z_OK && zr != Z_STREAM_END && zr != Z_BUF_ERROR) {
            if (error) {
              *error = [NSError errorWithDomain:@"RuntimeFetcher"
                                           code:3
                                       userInfo:@{
                                         NSLocalizedDescriptionKey : [NSString
                                             stringWithFormat:@"inflate error %d (%s)", zr,
                                                              strm.msg ?: "no message"]
                                       }];
            }
            ok = NO;
            break;
          }
          size_t produced = outCap - strm.avail_out;
          if (produced) {
            totalOut += produced;
            if (![tar consume:outBuf length:produced]) {
              if (error) {
                *error = [NSError errorWithDomain:@"RuntimeFetcher"
                                             code:4
                                         userInfo:@{
                                           NSLocalizedDescriptionKey :
                                               tar.lastError ?: @"tar extraction failed"
                                         }];
              }
              ok = NO;
              break;
            }
          }
          if (zr == Z_STREAM_END) break;
          if (produced == 0 && zr == Z_BUF_ERROR) break;  // needs more input
        }
      }
    }
    [fh closeFile];

    // Delete before fetching the next one: this is what keeps peak disk at
    // one chunk instead of the whole archive.
    [fm removeItemAtPath:scratch error:NULL];
    chunkIndex++;

    if (manifestChunks > 0 && chunkIndex >= manifestChunks) {
      RFLOG(@"all %ld chunks consumed", (long)manifestChunks);
      break;
    }
  }

  [tar finish];
  inflateEnd(&strm);
  free(outBuf);

  if (ok) {
    RFLOG(@"extracted %ld files, %.1f MB in -> %.1f MB out", (long)tar.fileCount,
          totalIn / 1048576.0, totalOut / 1048576.0);
    RFPROGRESS(1.0, @"done: %ld files", (long)tar.fileCount);
  }
  return ok;
#undef RFLOG
#undef RFPROGRESS
}

@end
