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
        self.state = TarStateSkip;  // captured in the skip branch below
        continue;
      }
      if (type == 'x' || type == 'g') {
        // pax extended header. Its body holds "len key=value\n" records; the
        // path record, when present, overrides the next entry's name.
        self.pendingLongNameBuf = [NSMutableData data];
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
          // pax record form: "<len> path=<value>\n"
          NSRange r = [raw rangeOfString:@" path="];
          if (r.location != NSNotFound) {
            NSString *rest = [raw substringFromIndex:NSMaxRange(r)];
            NSRange nl = [rest rangeOfString:@"\n"];
            path = (nl.location != NSNotFound) ? [rest substringToIndex:nl.location] : rest;
          } else {
            // GNU 'L': body is the raw path, NUL-terminated.
            path = [raw stringByTrimmingCharactersInSet:
                             [NSCharacterSet characterSetWithCharactersInString:
                                                 @"\0\n"]];
          }
          if (path.length) self.pendingLongName = path;
        }
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

@implementation RuntimeFetcher

+ (NSData *)downloadURL:(NSURL *)url statusCode:(NSInteger *)statusOut {
  __block NSData *result = nil;
  __block NSInteger status = 0;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);

  NSURLSessionConfiguration *cfg =
      [NSURLSessionConfiguration ephemeralSessionConfiguration];
  cfg.timeoutIntervalForRequest = 60;
  cfg.timeoutIntervalForResource = 3600;  // chunks are large
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

+ (BOOL)fetchTag:(NSString *)tag
             into:(NSString *)destDir
         progress:(void (^)(NSString *))progress
            error:(NSError **)error {
  NSFileManager *fm = [NSFileManager defaultManager];

  // Wipe first: a previous attempt could otherwise leave a second copy of a
  // multi-GB tree behind.
  if ([fm fileExistsAtPath:destDir]) {
    if (progress) progress(@"removing previous download");
    [fm removeItemAtPath:destDir error:NULL];
  }
  [fm createDirectoryAtPath:destDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];

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

    if (progress) progress([NSString stringWithFormat:@"downloading %@", assetName]);
    NSInteger status = 0;
    NSData *chunk = [self downloadURL:url statusCode:&status];

    if (status == 404) {
      // Walking until a 404 is how the chunk count is discovered; the CI side
      // clears stale assets so a leftover chunk can't extend the walk.
      if (progress) progress([NSString stringWithFormat:@"no %@ (end of archive)", assetName]);
      break;
    }
    if (status != 200 || !chunk.length) {
      if (error) {
        *error = [NSError errorWithDomain:@"RuntimeFetcher"
                                     code:2
                                 userInfo:@{
                                   NSLocalizedDescriptionKey : [NSString
                                       stringWithFormat:@"%@ -> HTTP %ld, %lu bytes",
                                                        assetName, (long)status,
                                                        (unsigned long)chunk.length]
                                 }];
      }
      ok = NO;
      break;
    }

    totalIn += chunk.length;
    if (progress) {
      progress([NSString stringWithFormat:@"  got %lu bytes, inflating",
                                          (unsigned long)chunk.length]);
    }

    strm.next_in = (Bytef *)chunk.bytes;
    strm.avail_in = (uInt)chunk.length;
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

    // The chunk lived in memory, but remove any scratch file defensively so a
    // failed run can't leave one behind.
    [fm removeItemAtPath:scratch error:NULL];
    chunkIndex++;
  }

  [tar finish];
  inflateEnd(&strm);
  free(outBuf);

  if (ok && progress) {
    progress([NSString stringWithFormat:
                           @"extracted %ld files, %llu bytes in -> %llu bytes out",
                           (long)tar.fileCount, totalIn, totalOut]);
  }
  return ok;
}

@end
