//
//  MMFontCore.m
//  MMFontSubstitute
//
//  字体来源、注册、替换策略、字体构造。
//

#import "MMFontCore.h"
#import "MMFontConfig.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import <stdlib.h>

BOOL gMMVerbose = NO;
__thread int gMMGuard = 0;

static BOOL                        gReady   = NO;
static CTFontDescriptorRef         gDesc    = NULL;
static NSString                   *gPS      = nil;
static NSString                   *gFamily  = nil;
static NSMutableDictionary        *gUICache = nil;
static NSMutableDictionary        *gCTCache = nil;
static NSArray<NSString *>        *gSkip    = nil;
static NSArray<NSString *>        *gMono    = nil;
static os_unfair_lock              gLock    = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t             gBootOnce;

#pragma mark - 日志

void MMLog(NSString *fmt, ...) {
    if (!gMMVerbose) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[MMFont] %@", s);
}

#pragma mark - 基本信息

BOOL      MMFontReady(void)      { return gReady; }
NSString *MMFontPSName(void)     { return gPS.length ? gPS : MM_FONT_PS_NAME; }
NSString *MMFontFamilyName(void) { return gFamily.length ? gFamily : MM_FONT_FAMILY_NAME; }

BOOL MMFontIsOwnName(NSString *name) {
    if (name.length == 0) return NO;
    if ([name isEqualToString:MMFontPSName()]) return YES;
    if ([name isEqualToString:MMFontFamilyName()]) return YES;
    return NO;
}

#pragma mark - 替换策略

static BOOL MMContainsAny(NSString *hay, NSArray<NSString *> *needles) {
    if (hay.length == 0) return NO;
    for (NSString *n in needles) {
        if ([hay rangeOfString:n options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

BOOL MMShouldReplaceName(NSString *name) {
    if (!gReady || name.length == 0) return NO;
    if (MMFontIsOwnName(name)) return NO;                    // 自己的字体，别再套娃
    if (MMContainsAny(name, gSkip)) return NO;               // emoji / 图标字体
#if !MM_REPLACE_MONOSPACE
    if (MMContainsAny(name, gMono)) return NO;               // 保留等宽
#endif
#if !MM_REPLACE_ALL_FONTS
    /* 保守模式：只换系统字体名 */
    if (!MMContainsAny(name, @[ @".SF", @"SFPro", @"SFUI", @"SFMono", @"PingFang",
                                @"Hiragino", @"STHeiti", @"Helvetica", @"Arial",
                                @"UICTFontTextStyle", @"AppleSystemUIFont", @"System" ])) return NO;
#endif
    return YES;
}

BOOL MMShouldReplaceDescriptor(CTFontDescriptorRef desc) {
    if (!gReady || desc == NULL) return NO;
    if (desc == gDesc) return NO;                            // 我们自己造的
    CFStringRef nm = CTFontDescriptorCopyAttribute(desc, kCTFontNameAttribute);
    if (nm) {
        BOOL ok = MMShouldReplaceName((__bridge NSString *)nm);
        CFRelease(nm);
        if (!ok) return NO;
    }
    CFStringRef fam = CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute);
    if (fam) {
        BOOL ok = MMShouldReplaceName((__bridge NSString *)fam);
        CFRelease(fam);
        if (!ok) return NO;
    }
    return YES;
}

/* 热路径：CoreText 每次排版都会问 CTFontCreateForString，
   按字体指针缓存结论，避免每次分配 PS 名字符串 + 扫跳过表。 */
#define MM_FONT_CACHE_SLOTS 16
static CTFontRef gFontSlot[MM_FONT_CACHE_SLOTS];
static uint8_t   gFontSlotAct[MM_FONT_CACHE_SLOTS];
static int       gFontSlotNext = 0;

BOOL MMFontShouldReplaceFont(CTFontRef font) {
    if (!gReady || font == NULL) return NO;

    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < MM_FONT_CACHE_SLOTS; i++) {
        if (gFontSlot[i] == font) {
            BOOL act = (gFontSlotAct[i] != 0);
            os_unfair_lock_unlock(&gLock);
            return act;
        }
    }
    os_unfair_lock_unlock(&gLock);

    BOOL act = NO;
    CFStringRef ps = CTFontCopyPostScriptName(font);
    if (ps != NULL) {
        act = MMShouldReplaceName((__bridge NSString *)ps);
        CFRelease(ps);
    }

    os_unfair_lock_lock(&gLock);
    int slot = gFontSlotNext % MM_FONT_CACHE_SLOTS;
    gFontSlotNext++;
    if (gFontSlot[slot] != NULL) CFRelease(gFontSlot[slot]);
    gFontSlot[slot] = (CTFontRef)CFRetain(font);
    gFontSlotAct[slot] = act ? 1 : 0;
    os_unfair_lock_unlock(&gLock);
    return act;
}

#pragma mark - 从 dylib 里取字体

/* 在自身 Mach-O 里找 __DATA,__mmfont 段（构建时 -sectcreate 塞进去的 ttf）。*/
static const uint8_t *MMEmbeddedFontData(size_t *outLen) {
    *outLen = 0;
    Dl_info info;
    if (dladdr((const void *)&MMBootstrap, &info) == 0 || info.dli_fbase == NULL) return NULL;

    const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
    if (mh->magic != MH_MAGIC_64) return NULL;

    const uint8_t *p = (const uint8_t *)mh + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            const struct section_64 *sect = (const struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) {
                if (strncmp(sect[j].sectname, "__mmfont", 16) == 0) {
                    *outLen = (size_t)sect[j].size;
                    return (const uint8_t *)mh + (uintptr_t)sect[j].addr;
                }
            }
        }
        if (lc->cmdsize == 0) break;
        p += lc->cmdsize;
    }
    return NULL;
}

NSData *MMFontEmbeddedData(void) {
    static NSData *data = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t len = 0;
        const uint8_t *bytes = MMEmbeddedFontData(&len);
        if (bytes != NULL && len > 4096) {
            data = [NSData dataWithBytesNoCopy:(void *)bytes length:len freeWhenDone:NO];
        }
    });
    return data;
}

static NSString *MMEnsureFontFile(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in MM_FONT_SYSTEM_PATHS) {
        if ([fm fileExistsAtPath:p]) {
            MMLog(@"用系统路径的字体 %@", p);
            return p;
        }
    }

    size_t len = 0;
    const uint8_t *bytes = MMEmbeddedFontData(&len);
    if (bytes == NULL || len < 4096) {
        MMLog(@"dylib 里没有嵌入字体");
        return nil;
    }

    NSString *dir = nil;
    const char *tmp = getenv("TMPDIR");
    if (tmp != NULL && tmp[0] != '\0') {
        dir = [NSString stringWithUTF8String:tmp];
    }
    if (dir.length == 0) dir = NSTemporaryDirectory();
    if (dir.length == 0) dir = @"/tmp";

    NSString *path = [dir stringByAppendingPathComponent:MM_FONT_FILE_NAME];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (attrs != nil && [attrs[NSFileSize] unsignedLongLongValue] == (unsigned long long)len) {
        return path;
    }

    /* 不复制这 13MB：直接引用 dylib 里映射的只读页写盘 */
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:len freeWhenDone:NO];
    if ([data writeToFile:path atomically:YES]) {
        MMLog(@"字体从 dylib 落盘 -> %@ (%lu bytes)", path, (unsigned long)len);
        return path;
    }
    MMLog(@"字体落盘失败 %@", path);
    return nil;
}

#pragma mark - 注册

static BOOL MMRegisterFont(NSString *path) {
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                 (__bridge CFStringRef)path,
                                                 kCFURLPOSIXPathStyle, false);
    if (url == NULL) return NO;

    CFErrorRef err = NULL;
    (void)CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &err);
    if (err != NULL) {
        /* 105 = already registered，可忽略 */
        MMLog(@"RegisterFontsForURL 返回错误码 %ld", (long)CFErrorGetCode(err));
        CFRelease(err);
    }

    CFArrayRef descs = CTFontManagerCreateFontDescriptorsFromURL(url);
    CFRelease(url);
    if (descs == NULL || CFArrayGetCount(descs) == 0) {
        if (descs != NULL) CFRelease(descs);
        MMLog(@"CreateFontDescriptorsFromURL 失败");
        return NO;
    }

    gDesc = (CTFontDescriptorRef)CFRetain((CFTypeRef)CFArrayGetValueAtIndex(descs, 0));
    CFRelease(descs);
    if (gDesc == NULL) return NO;

    CFStringRef ps = CTFontDescriptorCopyAttribute(gDesc, kCTFontNameAttribute);
    if (ps != NULL) {
        gPS = [(__bridge NSString *)ps copy];
        CFRelease(ps);
    }
    CFStringRef fam = CTFontDescriptorCopyAttribute(gDesc, kCTFontFamilyNameAttribute);
    if (fam != NULL) {
        gFamily = [(__bridge NSString *)fam copy];
        CFRelease(fam);
    }

    gMMGuard++;
    CTFontRef probe = CTFontCreateWithFontDescriptor(gDesc, 12.0, NULL);
    gMMGuard--;
    CFIndex glyphs = (probe != NULL) ? CTFontGetGlyphCount(probe) : 0;
    if (probe != NULL) CFRelease(probe);

    MMLog(@"注册完成 ps=%@ family=%@ glyphs=%ld", gPS, gFamily, (long)glyphs);
    return glyphs > 1000;
}

#pragma mark - 启动

void MMBootstrap(void) {
    dispatch_once(&gBootOnce, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        if (bundle.bundleIdentifier.length == 0) return;          // 非 App 进程
        if (NSClassFromString(@"UIApplication") == nil) return;   // 没有 UI 的守护进程

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        gMMVerbose = [defaults boolForKey:@"MMFontVerbose"];
        if ([defaults boolForKey:@"MMFontDisabled"]) {
            MMLog(@"MMFontDisabled=YES，本 App 不替换");
            return;
        }

        gSkip    = MM_SKIP_SUBSTRINGS;
        gMono    = MM_MONO_SUBSTRINGS;
        gUICache = [NSMutableDictionary dictionary];
        gCTCache = [NSMutableDictionary dictionary];

        NSString *path = MMEnsureFontFile();
        if (path == nil) return;

        gReady = MMRegisterFont(path);
        MMLog(@"%@ ready=%d", bundle.bundleIdentifier, gReady);
    });
}

#pragma mark - 造字体

CTFontRef MMCreateReplacementFont(CGFloat size) {
    if (!gReady || gDesc == NULL) return NULL;
    if (size <= 0.0) size = 12.0;

    NSNumber *key = @(size);
    os_unfair_lock_lock(&gLock);
    CTFontRef cached = (__bridge CTFontRef)gCTCache[key];
    if (cached != NULL) CFRetain(cached);
    os_unfair_lock_unlock(&gLock);
    if (cached != NULL) return cached;

    gMMGuard++;
    NSDictionary *attrs = @{ (__bridge NSString *)kCTFontSizeAttribute : key };
    CTFontDescriptorRef sized = CTFontDescriptorCreateCopyWithAttributes(
        gDesc, (__bridge CFDictionaryRef)attrs);
    CTFontRef font = CTFontCreateWithFontDescriptor(sized, size, NULL);
    if (sized != NULL) CFRelease(sized);
    gMMGuard--;

    if (font == NULL) return NULL;

    os_unfair_lock_lock(&gLock);
    gCTCache[key] = (__bridge id)font;
    os_unfair_lock_unlock(&gLock);
    return font;
}

UIFont *MMReplacementUIFont(CGFloat size) {
    if (!gReady) return nil;
    if (size <= 0.0) size = 17.0;

    NSNumber *key = @(size);
    os_unfair_lock_lock(&gLock);
    UIFont *cached = gUICache[key];
    os_unfair_lock_unlock(&gLock);
    if (cached != nil) return cached;

    UIFont *font = [UIFont fontWithName:MMFontPSName() size:size];
    if (font == nil) {
        UIFontDescriptor *desc = [UIFontDescriptor fontDescriptorWithName:MMFontPSName() size:size];
        font = [UIFont fontWithDescriptor:desc size:size];
    }
    if (font != nil) {
        os_unfair_lock_lock(&gLock);
        gUICache[key] = font;
        os_unfair_lock_unlock(&gLock);
    } else {
        MMLog(@"UIFont 构造失败 size=%.1f", (double)size);
    }
    return font;
}
