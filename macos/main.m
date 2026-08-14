// DSH Launcher — DeepSeek Web 启动器（原生 macOS App，Objective-C + AppKit + WebKit）
// 双击打开窗口；「启动」后台拉起 dsh web 并自动开浏览器；只停自己拉起的进程。
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <poll.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static NSString *const kBundleID = @"local.dsh.launcher";
static NSString *const kDSHHost = @"127.0.0.1";
static int kDshPort = 3080;

#pragma mark - 基础工具

static int DshPortFromEnv(void) {
    NSString *s = [[NSProcessInfo processInfo] environment][@"DSH_LAUNCHER_DSH_PORT"];
    return s.intValue > 0 ? s.intValue : 3080;
}

static NSURL *StateDir(void) {
    NSString *custom = [[NSProcessInfo processInfo] environment][@"DSH_LAUNCHER_STATE_DIR"];
    NSURL *base;
    if (custom.length) base = [NSURL fileURLWithPath:custom isDirectory:YES];
    else base = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask].firstObject
                 URLByAppendingPathComponent:@"DSH Launcher" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:base
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return base;
}

static NSString *Timestamp(void) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    return [df stringFromDate:[NSDate date]];
}

static void AppendFile(NSString *path, NSString *line) {
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) return;
    }
    [h seekToEndOfFile];
    [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void AppLog(NSString *s) {
    NSString *line = [@"[app] " stringByAppendingString:s];
    printf("%s\n", line.UTF8String);
    AppendFile([StateDir().path stringByAppendingPathComponent:@"app.log"], line);
}

#pragma mark - 安装 / 更新 / 自启

// npx 本地缓存里的 dsh 版本：扫 ~/.npm/_npx/*/node_modules/@deepseek-ai/dsh/package.json
static NSDictionary *NpxDshInfo(void) {
    NSString *npxDir = [@"~/.npm/_npx" stringByExpandingTildeInPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *dirs = [NSMutableArray new];
    NSString *bestVer = nil;
    for (NSString *ent in [fm contentsOfDirectoryAtPath:npxDir error:nil]) {
        NSString *dir = [npxDir stringByAppendingPathComponent:ent];
        NSString *pj = [[dir stringByAppendingPathComponent:@"node_modules"]
            stringByAppendingPathComponent:@"@deepseek-ai/dsh/package.json"];
        NSData *d = [NSData dataWithContentsOfFile:pj];
        if (!d) continue;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSString *v = json[@"version"];
        if (![v isKindOfClass:[NSString class]]) continue;
        [dirs addObject:dir];
        if (!bestVer || [bestVer compare:v options:NSNumericSearch] == NSOrderedAscending) bestVer = v;
    }
    return bestVer ? @{@"version": bestVer, @"dirs": dirs} : @{@"dirs": @[]};
}

// 用户 npm 源（~/.npmrc 的 registry，缺省官方源）
static NSString *RegistryBase(void) {
    NSString *npmrc = [NSString stringWithContentsOfFile:[@"~/.npmrc" stringByExpandingTildeInPath]
                                                 encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [npmrc componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"registry="]) {
            NSString *v = [t substringFromIndex:@"registry=".length];
            while ([v hasSuffix:@"/"]) v = [v substringToIndex:v.length - 1];
            if (v.length) return v;
        }
    }
    return @"https://registry.npmjs.org";
}

static void FetchLatestDshVersion(void (^cb)(NSString *ver, NSString *err)) {
    NSURL *url = [NSURL URLWithString:[RegistryBase() stringByAppendingString:@"/@deepseek-ai/dsh/latest"]];
    if (!url) { cb(nil, @"registry 地址无效"); return; }
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
            if (e) { cb(nil, e.localizedDescription); return; }
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            NSString *v = j[@"version"];
            if (![v isKindOfClass:[NSString class]]) { cb(nil, @"registry 响应异常"); return; }
            cb(v, nil);
        }];
    [t resume];
}

// 复制 App 到目标位置；relaunch=先起新副本再退出当前
static NSDictionary *InstallAppTo(NSString *dstPath, BOOL relaunch) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *src = NSBundle.mainBundle.bundlePath;
    if ([src isEqualToString:dstPath]) return @{@"installed": @YES, @"already": @YES};
    if ([fm fileExistsAtPath:dstPath]) {
        // 旧副本若在运行先请它退出
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:kBundleID]) {
            if ([app.bundleURL.path isEqualToString:dstPath]) [app terminate];
        }
        [NSThread sleepForTimeInterval:0.8];
        if (![fm removeItemAtPath:dstPath error:nil])
            return @{@"error": @"无法移除旧副本（可能正在运行），请手动删除后重试"};
    }
    NSError *e = nil;
    if (![fm copyItemAtPath:src toPath:dstPath error:&e])
        return @{@"error": e.localizedDescription ?: @"复制失败（/Applications 可能需要管理员权限）"};
    if (relaunch) {
        NSURL *u = [NSURL fileURLWithPath:dstPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWorkspaceOpenConfiguration *conf = [NSWorkspaceOpenConfiguration configuration];
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:u configuration:conf completionHandler:nil];
            [NSApp terminate:nil];
        });
    }
    return @{@"installed": @YES, @"path": dstPath};
}

#pragma mark - 进程管理器

@interface ProcMan : NSObject
@property (strong) NSMutableArray<NSString *> *ring;
@property (strong) NSTask *child;
@property (strong) NSDate *childStartedAt;
@property (strong) NSNumber *adoptedPid;
@property (strong) NSDictionary *lastExit;
@property BOOL pollerShouldRun;
@end

@implementation ProcMan

+ (instancetype)shared {
    static ProcMan *pm;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pm = [ProcMan new]; });
    return pm;
}

- (instancetype)init {
    self = [super init];
    _ring = [NSMutableArray new];
    kDshPort = DshPortFromEnv();
    return self;
}

- (void)logLine:(NSString *)s {
    for (NSString *l in [s componentsSeparatedByString:@"\n"]) {
        if (!l.length) continue;
        NSString *entry = [NSString stringWithFormat:@"[%@] %@", Timestamp(), l];
        @synchronized (self.ring) {
            [self.ring addObject:entry];
            if (self.ring.count > 800) [self.ring removeObjectsInRange:NSMakeRange(0, self.ring.count - 800)];
        }
        AppendFile([StateDir().path stringByAppendingPathComponent:@"dsh-web.log"], entry);
    }
}

- (NSArray<NSString *> *)tail:(NSInteger)n {
    @synchronized (self.ring) {
        if (self.ring.count <= n) return [self.ring copy];
        return [self.ring subarrayWithRange:NSMakeRange(self.ring.count - n, n)];
    }
}

- (BOOL)pidAlive:(pid_t)pid {
    if (pid <= 0) return NO;
    int r = kill(pid, 0);
    return r == 0 || errno == EPERM;
}

- (NSString *)psCommandOf:(pid_t)pid {
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/ps";
    t.arguments = @[@"-p", [NSString stringWithFormat:@"%d", pid], @"-o", @"command="];
    t.standardOutput = [NSPipe pipe];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return @""; }
    NSData *d = ((NSPipe *)t.standardOutput).fileHandleForReading.readDataToEndOfFile;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}

- (BOOL)pidIsDsh:(pid_t)pid {
    NSString *cmd = [self psCommandOf:pid];
    return cmd && [cmd containsString:@"dsh"];
}

// 探测：TCP 连接 + GET /，校验响应含 __DSH_BOOT__
- (BOOL)probeDsh:(int)timeoutMs {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)kDshPort);
    addr.sin_addr.s_addr = inet_addr(kDSHHost.UTF8String);

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int cr = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (cr != 0 && errno != EINPROGRESS) { close(fd); return NO; }
    struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
    if (poll(&pfd, 1, timeoutMs) <= 0) { close(fd); return NO; }

    fcntl(fd, F_SETFL, flags);
    struct timeval tv = { .tv_sec = timeoutMs / 1000, .tv_usec = (suseconds_t)((timeoutMs % 1000) * 1000) };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    const char *req = [[NSString stringWithFormat:
        @"GET / HTTP/1.1\r\nHost: %@:%d\r\nConnection: close\r\n\r\n", kDSHHost, kDshPort]
        cStringUsingEncoding:NSASCIIStringEncoding];
    ssize_t unusedSnd = send(fd, req, strlen(req), 0);
    (void)unusedSnd;

    NSMutableData *buf = [NSMutableData new];
    char chunk[4096];
    while (buf.length < 8192) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [buf appendBytes:chunk length:(NSUInteger)n];
        NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        if (s && [s containsString:@"__DSH_BOOT__"]) { close(fd); return YES; }
    }
    close(fd);
    NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    return s && [s containsString:@"__DSH_BOOT__"];
}

- (NSURL *)pidFileURL { return [StateDir() URLByAppendingPathComponent:@"child.pid"]; }

- (void)adoptFromPidFile {
    NSString *txt = [NSString stringWithContentsOfURL:self.pidFileURL
                                             encoding:NSUTF8StringEncoding error:nil];
    NSInteger pid = [[txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] integerValue];
    if (pid <= 0) return;
    if ([self pidAlive:(pid_t)pid] && [self pidIsDsh:(pid_t)pid]) {
        self.adoptedPid = @(pid);
        AppLog([NSString stringWithFormat:@"认领上次拉起的 dsh 进程 pid=%ld", (long)pid]);
    } else {
        [[NSFileManager defaultManager] removeItemAtURL:self.pidFileURL error:nil];
    }
}

- (BOOL)oursRunning {
    if (self.child.isRunning) return YES;
    if (self.adoptedPid && [self pidAlive:self.adoptedPid.intValue]) return YES;
    return NO;
}

- (NSNumber *)managedPid {
    if (self.child.isRunning) return @(self.child.processIdentifier);
    if (self.adoptedPid && [self pidAlive:self.adoptedPid.intValue]) return self.adoptedPid;
    return nil;
}

- (void)attachReader:(NSFileHandle *)h tag:(NSString *)tag {
    NSMutableData *buf = [NSMutableData new];
    __weak typeof(self) weakSelf = self;
    h.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *d = fh.availableData;
        if (d.length == 0) { fh.readabilityHandler = nil; return; }
        [buf appendData:d];
        while (buf.length > 0) {
            const char *p = buf.bytes;
            const void *nl = memchr(p, '\n', buf.length);
            if (!nl) break;
            NSUInteger len = (NSUInteger)((const char *)nl - p);
            NSData *lineData = [buf subdataWithRange:NSMakeRange(0, len)];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length)
                [weakSelf logLine:[NSString stringWithFormat:@"%@ %@", tag, trimmed]];
            [buf replaceBytesInRange:NSMakeRange(0, len + 1) withBytes:NULL length:0];
        }
    };
}

- (NSDictionary *)startWithAutoOpen:(BOOL)autoOpen onReady:(void(^)(BOOL))onReady error:(NSString **)err {
    if ([self oursRunning]) { *err = @"已有实例正在启动或运行"; return nil; }

    NSTask *p = [NSTask new];
    p.launchPath = @"/bin/zsh";
    p.arguments = @[@"-lc", [NSString stringWithFormat:@"exec npx -y @deepseek-ai/dsh web --port %d", kDshPort]];
    p.environment = [[NSProcessInfo processInfo] environment];

    NSPipe *outPipe = [NSPipe pipe], *errPipe = [NSPipe pipe];
    p.standardOutput = outPipe;
    p.standardError = errPipe;
    [self attachReader:outPipe.fileHandleForReading tag:@"[dsh]"];
    [self attachReader:errPipe.fileHandleForReading tag:@"[dsh err]"];

    __weak typeof(self) weakSelf = self;
    p.terminationHandler = ^(NSTask *proc) {
        ProcMan *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.child == proc) {
            strongSelf.child = nil;
            strongSelf.childStartedAt = nil;
            strongSelf.lastExit = @{@"code": @(proc.terminationStatus),
                                    @"at": @((NSInteger)([NSDate date].timeIntervalSince1970 * 1000))};
        }
        [strongSelf logLine:[NSString stringWithFormat:@"[dsh %d] 退出 code=%d", proc.processIdentifier, proc.terminationStatus]];
        [[NSFileManager defaultManager] removeItemAtURL:strongSelf.pidFileURL error:nil];
    };

    @try { [p launch]; }
    @catch (NSException *e) { *err = [@"spawn 失败: " stringByAppendingString:e.reason]; return nil; }

    self.child = p;
    self.childStartedAt = [NSDate date];
    self.adoptedPid = nil;
    self.lastExit = nil;
    [[NSString stringWithFormat:@"%d", (int)p.processIdentifier]
        writeToFile:self.pidFileURL.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self logLine:[NSString stringWithFormat:@"正在启动 dsh web（预期端口 %d）…", kDshPort]];
    AppLog([NSString stringWithFormat:@"spawn dsh pid=%d", p.processIdentifier]);

    // 就绪轮询
    self.pollerShouldRun = YES;
    NSDate *started = [NSDate date];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ProcMan *strongSelf = weakSelf;
        while (strongSelf.pollerShouldRun && [started timeIntervalSinceNow] > -120) {
            [NSThread sleepForTimeInterval:1.0];
            if (!strongSelf.child.isRunning) return;
            if ([strongSelf probeDsh:800]) {
                [strongSelf logLine:[NSString stringWithFormat:@"dsh web 已就绪: http://%@:%d", kDSHHost, kDshPort]];
                if (autoOpen) [strongSelf openBrowser];
                if (onReady) onReady(YES);
                return;
            }
        }
        if ([started timeIntervalSinceNow] <= -120) {
            [strongSelf logLine:@"等待就绪超时（120s）。请展开日志查看原因。"];
            if (onReady) onReady(NO);
        }
    });

    return @{@"status": @"starting", @"pid": @(p.processIdentifier)};
}

- (NSArray<NSNumber *> *)childrenOf:(pid_t)pid {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/pgrep";
    t.arguments = @[@"-P", [NSString stringWithFormat:@"%d", pid]];
    t.standardOutput = [NSPipe pipe];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return @[]; }
    NSData *d = ((NSPipe *)t.standardOutput).fileHandleForReading.readDataToEndOfFile;
    NSString *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray<NSNumber *> *kids = [NSMutableArray new];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSString *t2 = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        int v = t2.intValue;
        if (v > 0) [kids addObject:@(v)];
    }
    return kids;
}

// 先收集整棵树再杀（先子孙后根），5 秒后补 SIGKILL
- (void)collectTree:(pid_t)root into:(NSMutableArray<NSNumber *> *)out {
    for (NSNumber *kid in [self childrenOf:root]) [self collectTree:kid.intValue into:out];
    [out addObject:@(root)];
}

- (void)stopManaged {
    NSNumber *pidNum = [self managedPid];
    if (!pidNum) { self.child = nil; return; }
    pid_t pid = pidNum.intValue;
    [self logLine:[NSString stringWithFormat:@"停止 dsh web（pid %d，按进程树）…", pid]];
    NSMutableArray<NSNumber *> *tree = [NSMutableArray new];
    [self collectTree:pid into:tree];
    for (NSNumber *t in [tree subarrayWithRange:NSMakeRange(0, tree.count - 1)]) kill(t.intValue, SIGTERM);
    kill(pid, SIGTERM);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSNumber *> *left = [NSMutableArray new];
        [weakSelf collectTree:pid into:left];
        for (NSNumber *t in left) kill(t.intValue, SIGKILL);
    });
    [[NSFileManager defaultManager] removeItemAtURL:self.pidFileURL error:nil];
    self.child = nil;
    self.childStartedAt = nil;
    self.adoptedPid = nil;
}

// 端口 → pid（lsof）
- (NSNumber *)pidByPort:(int)port {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/sbin/lsof";
    t.arguments = @[@"-nP", [NSString stringWithFormat:@"-tiTCP:%d", port], @"-sTCP:LISTEN"];
    t.standardOutput = [NSPipe pipe];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return nil; }
    NSData *d = ((NSPipe *)t.standardOutput).fileHandleForReading.readDataToEndOfFile;
    NSString *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        int v = [[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] intValue];
        if (v > 0) return @(v);
    }
    return nil;
}

// 强制停止端口上的外部实例（二次确认后调用；按进程树先子后父）
- (NSDictionary *)forceStopByPort:(int)port {
    NSNumber *pidNum = [self pidByPort:port];
    if (!pidNum) return @{@"error": [NSString stringWithFormat:@"端口 %d 上没有发现进程", port]};
    pid_t pid = pidNum.intValue;
    [self logLine:[NSString stringWithFormat:@"强制停止外部实例 pid=%d（端口 %d）", pid, port]];
    NSMutableArray<NSNumber *> *tree = [NSMutableArray new];
    [self collectTree:pid into:tree];
    for (NSNumber *t in [tree subarrayWithRange:NSMakeRange(0, tree.count - 1)]) kill(t.intValue, SIGTERM);
    kill(pid, SIGTERM);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSNumber *> *left = [NSMutableArray new];
        [self collectTree:pid into:left];
        for (NSNumber *t in left) kill(t.intValue, SIGKILL);
    });
    return @{@"stopped": @YES, @"forced": @YES, @"pid": pidNum};
}

- (void)openBrowser {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d", kDSHHost, kDshPort]];
    void (^open)(void) = ^{ [[NSWorkspace sharedWorkspace] openURL:url]; };
    if ([NSThread isMainThread]) open();
    else dispatch_async(dispatch_get_main_queue(), open);
}

- (NSDictionary *)statusDict {
    BOOL alive = [self probeDsh:1500];
    BOOL ours = [self oursRunning];
    NSNumber *startedAt = nil;
    if (ours && self.childStartedAt)
        startedAt = @((NSInteger)(self.childStartedAt.timeIntervalSince1970 * 1000));
    return @{
        @"dsh": @{
            @"alive": @(alive),
            @"host": kDSHHost,
            @"port": @(kDshPort),
            @"url": [NSString stringWithFormat:@"http://%@:%d", kDSHHost, kDshPort],
            @"ours": @(ours),
            @"pid": [self managedPid] ?: [NSNull null],
            @"startedAt": startedAt ?: [NSNull null],
            @"adopted": @(ours && self.child == nil),
        },
        @"lastExit": self.lastExit ?: [NSNull null],
    };
}

@end

#pragma mark - JS 桥接

@interface BridgeVC : NSObject <WKScriptMessageHandlerWithReply>
@end

@implementation BridgeVC

- (void)userContentController:(WKUserContentController *)ucc
       didReceiveScriptMessage:(WKScriptMessage *)message
                replyHandler:(void (^)(id, NSString *))replyHandler {
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) { replyHandler(nil, @"bad message"); return; }
    NSString *cmd = body[@"cmd"];
    NSDictionary *payload = body[@"body"] ?: @{};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        NSDictionary *r = [BridgeVC executeCmd:cmd payload:payload error:&err];
        if (err) replyHandler(nil, err);
        else replyHandler(r, nil);
    });
}

// 所有界面指令的单一入口（App 桥接与 --bridge-test 共用）
+ (NSDictionary *)executeCmd:(NSString *)cmd payload:(NSDictionary *)payload error:(NSString **)err {
    ProcMan *pm = ProcMan.shared;

    if ([cmd isEqualToString:@"status"]) {
        return [pm statusDict];
    }
    if ([cmd isEqualToString:@"start"]) {
        BOOL autoOpen = payload[@"autoOpen"] ? [payload[@"autoOpen"] boolValue] : YES;
        if ([pm probeDsh:1500]) {
            [pm openBrowser];
            return @{@"status": @"already-running", @"opened": @YES};
        }
        NSString *e = nil;
        NSDictionary *r = [pm startWithAutoOpen:autoOpen onReady:nil error:&e];
        if (e) { *err = e; return nil; }
        return r;
    }
    if ([cmd isEqualToString:@"open"]) {
        if ([pm probeDsh:1500]) { [pm openBrowser]; return @{@"opened": @YES}; }
        *err = @"dsh web 未在运行";
        return nil;
    }
    if ([cmd isEqualToString:@"stop"]) {
        NSDictionary *st = [pm statusDict];
        NSDictionary *d = st[@"dsh"];
        BOOL alive = [d[@"alive"] boolValue], ours = [d[@"ours"] boolValue];
        BOOL force = [payload[@"force"] boolValue];
        if (!alive && !ours) return @{@"stopped": @YES, @"already": @YES};
        if (ours) {
            [pm stopManaged];
            return @{@"stopped": @YES};
        }
        if (force) {
            NSDictionary *r = [pm forceStopByPort:kDshPort];
            if (r[@"error"]) { *err = r[@"error"]; return nil; }
            return r;
        }
        *err = [NSString stringWithFormat:
            @"端口 %d 上的实例不是本启动台拉起的。强制停止外部实例需要二次确认（force）。", kDshPort];
        return nil;
    }
    if ([cmd isEqualToString:@"logs"]) {
        return @{@"lines": [pm tail:180]};
    }
    if ([cmd isEqualToString:@"autostart-status"]) {
        BOOL on = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled);
        return @{@"enabled": @(on)};
    }
    if ([cmd isEqualToString:@"autostart"]) {
        BOOL enable = [payload[@"enable"] boolValue];
        NSError *e = nil;
        BOOL ok = enable ? [SMAppService.mainAppService registerAndReturnError:&e]
                         : [SMAppService.mainAppService unregisterAndReturnError:&e];
        if (!ok) { *err = e.localizedDescription ?: @"设置失败"; return nil; }
        return @{@"enabled": @(enable)};
    }
    if ([cmd isEqualToString:@"install-status"]) {
        return @{@"installed": @([NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]),
                 @"path": NSBundle.mainBundle.bundlePath};
    }
    if ([cmd isEqualToString:@"install"]) {
        NSString *dst = [[NSProcessInfo processInfo] environment][@"DSH_LAUNCHER_INSTALL_DST"]
                        ?: @"/Applications/DeepSeek Harness 启动台.app";
        NSString *noRelaunch = [[NSProcessInfo processInfo] environment][@"DSH_LAUNCHER_NO_RELAUNCH"];
        return InstallAppTo(dst, noRelaunch.length == 0);
    }
    if ([cmd isEqualToString:@"update-check"]) {
        NSDictionary *info = NpxDshInfo();
        __block NSString *latest = nil, *lerr = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        FetchLatestDshVersion(^(NSString *v, NSString *e) {
            latest = v; lerr = e; dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
        if (lerr) { *err = [@"检查更新失败: " stringByAppendingString:lerr]; return nil; }
        return @{@"current": info[@"version"] ?: @"", @"latest": latest, @"dirs": info[@"dirs"]};
    }
    if ([cmd isEqualToString:@"update-apply"]) {
        NSArray<NSString *> *dirs = payload[@"dirs"] ?: @[];
        __block NSInteger removed = 0;
        for (NSString *dir in dirs) {
            if ([dir hasPrefix:[@"~/.npm/_npx" stringByExpandingTildeInPath]]
                && [[NSFileManager defaultManager] removeItemAtPath:dir error:nil]) removed++;
        }
        AppLog([NSString stringWithFormat:@"更新：清理 npx 缓存 %ld 处", (long)removed]);
        return @{@"ok": @(removed > 0), @"removed": @(removed)};
    }
    *err = [@"unknown cmd " stringByAppendingString:cmd ?: @""];
    return nil;
}

@end

#pragma mark - App 委托

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) WKWebView *webView;
@end

@implementation AppDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    // 单实例：已在跑就激活退出
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:kBundleID]) {
        if (app.processIdentifier != [NSProcessInfo processInfo].processIdentifier) {
            [app activateWithOptions:NSApplicationActivateAllWindows];
            [NSApp terminate:nil];
            return;
        }
    }

    [ProcMan.shared adoptFromPidFile];

    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandlerWithReply:[BridgeVC new] contentWorld:WKContentWorld.pageWorld name:@"bridge"];
    WKWebViewConfiguration *conf = [WKWebViewConfiguration new];
    conf.userContentController = ucc;

    WKWebView *wv = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:conf];
    [wv setValue:@NO forKey:@"drawsBackground"];
    wv.underPageBackgroundColor = [NSColor colorWithRed:0.024 green:0.063 blue:0.122 alpha:1];
    _webView = wv;

    NSView *content = [NSView new];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor colorWithRed:0.024 green:0.063 blue:0.122 alpha:1].CGColor;
    [content addSubview:wv];
    wv.translatesAutoresizingMaskIntoConstraints = NO;
    [content addConstraints:@[
        [NSLayoutConstraint constraintWithItem:wv attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual
            toItem:content attribute:NSLayoutAttributeTop multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:wv attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual
            toItem:content attribute:NSLayoutAttributeBottom multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:wv attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual
            toItem:content attribute:NSLayoutAttributeLeading multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:wv attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual
            toItem:content attribute:NSLayoutAttributeTrailing multiplier:1 constant:0],
    ]];

    // UI 自检可指定窗口尺寸（DSH_LAUNCHER_TEST_SIZE=宽x高），默认 820x680
    CGFloat winW = 820, winH = 680;
    NSString *sz = [[NSProcessInfo processInfo] environment][@"DSH_LAUNCHER_TEST_SIZE"];
    if (sz.length) {
        NSArray *parts = [sz componentsSeparatedByString:@"x"];
        NSString *sw = parts.count > 0 ? parts[0] : @"";
        NSString *sh = parts.count > 1 ? parts[1] : @"";
        if (sw.integerValue > 300 && sh.integerValue > 300) {
            winW = sw.integerValue; winH = sh.integerValue;
        }
    }
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, winW, winH)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
              | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    win.titleVisibility = NSWindowTitleHidden;
    win.titlebarAppearsTransparent = YES;
    win.title = @"DeepSeek Harness 启动台";
    win.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    win.backgroundColor = [NSColor colorWithCalibratedWhite:0.05 alpha:1];
    win.contentView = content;
    win.minSize = NSMakeSize(600, 560);
    [win center];
    [win makeKeyAndOrderFront:nil];
    _window = win;

    // 资源定位：bundle 内 → 可执行文件旁（开发直跑）→ 源码目录
    NSString *exe = [[NSProcessInfo processInfo] arguments].firstObject;
    NSString *exeDir = [exe stringByDeletingLastPathComponent];
    NSURL *htmlURL = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html"];
    if (!htmlURL) {
        NSString *adjacent = [exeDir stringByAppendingPathComponent:@"index.html"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:adjacent])
            htmlURL = [NSURL fileURLWithPath:adjacent];
    }
    AppLog([@"load html: " stringByAppendingString:htmlURL.path ?: @"(nil)"]);
    [wv loadFileURL:htmlURL allowingReadAccessToURL:htmlURL.URLByDeletingLastPathComponent];

    // UI 自动化自检（环境变量开启，结果写入 app.log 后退出）
    if ([[[NSProcessInfo processInfo] environment][@"DSH_LAUNCHER_UI_CHECK"] isEqualToString:@"1"]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf.webView evaluateJavaScript:@"window.__selfcheck ? window.__selfcheck() : 'no-selfcheck'"
                completionHandler:^(id result, NSError *error) {
                AppLog([NSString stringWithFormat:@"UI_CHECK result: %@ error: %@",
                        result ?: @"(nil)", error.localizedDescription ?: @"(none)"]);
                AppLog([NSString stringWithFormat:@"UI_CHECK done — window alive: %d", weakSelf.window != nil]);
                exit(0);
            }];
        });
    }
}

@end

#pragma mark - main（含 CLI 自测模式）

int main(int argc, const char *argv[]) {
    NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];

    if ([args containsObject:@"--probe"]) {
        [ProcMan.shared adoptFromPidFile];
        NSDictionary *st = [ProcMan.shared statusDict];
        NSDictionary *d = st[@"dsh"];
        NSString *pidStr = [d[@"pid"] isKindOfClass:[NSNull class]] ? @"-" : [d[@"pid"] stringValue];
        printf("alive=%d ours=%d pid=%s port=%d\n",
               [d[@"alive"] boolValue], [d[@"ours"] boolValue], pidStr.UTF8String, kDshPort);
        return 0;
    }

    if ([args containsObject:@"--bridge-test"]) {
        [ProcMan.shared adoptFromPidFile];
        __block NSInteger pass = 0, fail = 0;
        void (^check)(NSString *, NSDictionary *, NSString *) = ^(NSString *name, NSDictionary *r, NSString *e) {
            if (!e) { pass++; printf("[ok]   %-13s %s\n", name.UTF8String, r ? [[r description] UTF8String] : ""); }
            else    { fail++; printf("[FAIL] %-13s %s\n", name.UTF8String, e.UTF8String); }
        };
        NSString *err = nil; NSDictionary *r;
        r = [BridgeVC executeCmd:@"status" payload:@{} error:&err]; check(@"status", r, err); err = nil;
        r = [BridgeVC executeCmd:@"update-check" payload:@{} error:&err]; check(@"update-check", r, err); err = nil;
        r = [BridgeVC executeCmd:@"logs" payload:@{} error:&err]; check(@"logs", r, err); err = nil;

        // 启动→就绪→停止 生命周期（用环境变量的隔离端口，不碰 3080）
        r = [BridgeVC executeCmd:@"start" payload:@{@"autoOpen": @NO} error:&err];
        if (!err) {
            BOOL ready = NO;
            for (int i = 0; i < 30 && !ready; i++) { [NSThread sleepForTimeInterval:1.0]; ready = [ProcMan.shared probeDsh:800]; }
            printf("[info] start pid=%s ready=%d\n", [r[@"pid"] stringValue].UTF8String, ready);
            if (!ready) { fail++; printf("[FAIL] start 就绪超时\n"); }
            else {
                r = [BridgeVC executeCmd:@"stop" payload:@{} error:&err];
                check(@"stop", r, err); err = nil;
            }
        } else { check(@"start", nil, err); err = nil; }

        // 外部实例强制停止：起一个无关 http 服务冒充外部进程再按端口强停
        NSTask *dummy = [NSTask new];
        dummy.launchPath = @"/usr/bin/python3";
        dummy.arguments = @[@"-m", @"http.server", @"4892", @"--bind", @"127.0.0.1"];
        dummy.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        dummy.standardError = [NSFileHandle fileHandleWithNullDevice];
        @try { [dummy launch]; } @catch (NSException *e) {}
        [NSThread sleepForTimeInterval:1.2];
        NSDictionary *fr = [ProcMan.shared forceStopByPort:4892];
        [NSThread sleepForTimeInterval:1.5];
        BOOL dummyDead = ![ProcMan.shared pidByPort:4892];
        if (![fr objectForKey:@"error"] && dummyDead) { pass++; printf("[ok]   force-stop     pid=%s\n", [fr[@"pid"] stringValue].UTF8String); }
        else { fail++; printf("[FAIL] force-stop   %@\n", fr); }

        printf("bridge-test: %ld 通过 / %ld 失败\n", (long)pass, (long)fail);
        return fail ? 1 : 0;
    }

    if ([args containsObject:@"--check-update"]) {
        NSDictionary *info = NpxDshInfo();
        printf("current=%s\n", info[@"version"] ? [info[@"version"] UTF8String] : "(无本地缓存)");
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSString *latest = nil, *lerr = nil;
        FetchLatestDshVersion(^(NSString *v, NSString *e) {
            latest = v; lerr = e;
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
        if (lerr) printf("latest=ERROR: %s\n", lerr.UTF8String);
        else printf("latest=%s\n", latest.UTF8String);
        return 0;
    }

    if ([args containsObject:@"--install"] && args.count >= 3) {
        NSDictionary *r = InstallAppTo(args[2], NO);
        printf("%s\n", [r description].UTF8String);
        return r[@"error"] ? 1 : 0;
    }

    if ([args containsObject:@"--autostart-test"]) {
        NSError *e = nil;
        BOOL ok = [SMAppService.mainAppService registerAndReturnError:&e];
        printf("register=%d status=%ld err=%s\n", ok, (long)SMAppService.mainAppService.status,
               e.localizedDescription.UTF8String ?: "-");
        [NSThread sleepForTimeInterval:0.5];
        ok = [SMAppService.mainAppService unregisterAndReturnError:&e];
        printf("unregister=%d status=%ld err=%s\n", ok, (long)SMAppService.mainAppService.status,
               e.localizedDescription.UTF8String ?: "-");
        return 0;
    }

    if ([args containsObject:@"--selftest"]) {
        ProcMan *pm = ProcMan.shared;
        printf("[selftest] target port = %d\n", kDshPort);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block BOOL readyOK = NO;
        NSString *err = nil;
        NSDictionary *r = [pm startWithAutoOpen:NO onReady:^(BOOL ok) {
            readyOK = ok;
            dispatch_semaphore_signal(sem);
        } error:&err];
        if (err) { printf("[selftest] FAIL spawn: %s\n", err.UTF8String); return 1; }
        printf("[selftest] spawned pid=%s\n", [r[@"pid"] stringValue].UTF8String);
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC))) {
            printf("[selftest] FAIL timeout\n");
            [pm stopManaged];
            return 1;
        }
        BOOL alive = [pm probeDsh:1500];
        printf("[selftest] ready=%d probeAlive=%d\n", readyOK, alive);
        [pm stopManaged];
        [NSThread sleepForTimeInterval:3];
        BOOL still = [pm probeDsh:1500];
        printf("[selftest] after stop alive=%d\n", still);
        printf("[selftest] %s\n", (readyOK && alive && !still) ? "PASS" : "FAIL");
        return (readyOK && alive && !still) ? 0 : 1;
    }

    NSApplication *app = [NSApplication sharedApplication];
    AppDelegate *delegate = [AppDelegate new];
    app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"退出启动台" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];
    NSMenuItem *editItem = [NSMenuItem new];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    editItem.submenu = editMenu;
    [mainMenu addItem:editItem];
    app.mainMenu = mainMenu;

    [app activateIgnoringOtherApps:YES];
    [app run];
    return 0;
}
