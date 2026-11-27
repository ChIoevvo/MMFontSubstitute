//
//  MMFontHooks.m
//  MMFontSubstitute
//
//  两层接管：
//   1) UIKit：UIFont 的类/实例方法（大多数 App、SwiftUI、第三方 UI 框架最终都落到这里）
//   2) CoreText：CTFontCreate* 系列（游戏引擎、Flutter/Skia、PDF、排版库直连这一层）
//  CoreText 是 C 函数，需要 MSHookFunction（substrate / ElleKit / libhooker）；
//  没有注入框架时自动退化成只有 UIKit 层，不会崩。
//

#import "MMFontCore.h"
#import "MMFontConfig.h"

#import <objc/runtime.h>
#import <dlfcn.h>

void MMInstallUIKitHooks(void);
void MMInstallCoreTextHooks(void);

#pragma mark - 方法交换工具

static void MMSwizzleClassMethod(Class cls, SEL sel, IMP replacement, IMP *storage) {
    if (cls == Nil || sel == NULL) return;
    Class meta = object_getClass(cls);
    Method m = class_getInstanceMethod(meta, sel);
    if (m == NULL) {
        MMLog(@"缺少类方法 +%@", NSStringFromSelector(sel));
        return;
    }
    *storage = method_getImplementation(m);
    if (!class_addMethod(meta, sel, replacement, method_getTypeEncoding(m))) {
        method_setImplementation(m, replacement);
    }
}

static void MMSwizzleInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *storage) {
    if (cls == Nil || sel == NULL) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {
        MMLog(@"缺少实例方法 -%@", NSStringFromSelector(sel));
        return;
    }
    *storage = method_getImplementation(m);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        method_setImplementation(m, replacement);
    }
}

#pragma mark - UIFont 层

typedef UIFont *(*MMSizeIMP)(id, SEL, CGFloat);
typedef UIFont *(*MMWeightIMP)(id, SEL, CGFloat, CGFloat);
typedef UIFont *(*MMDesignIMP)(id, SEL, CGFloat, CGFloat, NSString *);
typedef UIFont *(*MMNameIMP)(id, SEL, NSString *, CGFloat);
typedef UIFont *(*MMDescIMP)(id, SEL, UIFontDescriptor *, CGFloat);
typedef UIFont *(*MMStyleIMP)(id, SEL, NSString *);
typedef UIFont *(*MMStyleTraitIMP)(id, SEL, NSString *, UITraitCollection *);
typedef NSArray *(*MMArrayIMP)(id, SEL);
typedef NSArray *(*MMFamilyIMP)(id, SEL, NSString *);

static MMSizeIMP      orig_systemFontOfSize;
static MMWeightIMP    orig_systemFontOfSizeWeight;
static MMDesignIMP    orig_systemFontOfSizeWeightDesign;
static MMSizeIMP      orig_boldSystemFontOfSize;
static MMSizeIMP      orig_italicSystemFontOfSize;
static MMWeightIMP    orig_monospacedSystemFontOfSizeWeight;
static MMWeightIMP    orig_monospacedDigitSystemFontOfSizeWeight;
static MMNameIMP      orig_fontWithName;
static MMDescIMP      orig_fontWithDescriptor;
static MMStyleIMP     orig_preferredFontForTextStyle;
static MMStyleTraitIMP orig_preferredFontForTextStyleTrait;
static MMSizeIMP      orig_fontWithSize;
static MMArrayIMP     orig_familyNames;
static MMFamilyIMP    orig_fontNamesForFamilyName;

static BOOL MMShouldReplaceUIFontDescriptor(UIFontDescriptor *desc) {
    if (!MMFontReady() || desc == nil) return NO;
    NSDictionary *attrs = [desc fontAttributes];
    NSString *name = attrs[UIFontDescriptorNameAttribute];
    if (name.length > 0 && !MMShouldReplaceName(name)) return NO;
    NSString *family = attrs[UIFontDescriptorFamilyAttribute];
    if (family.length > 0 && !MMShouldReplaceName(family)) return NO;
    return YES;
}

#define MM_RETURN_REPLACEMENT(sizeValue) \
    do { \
        if (MMFontReady()) { \
            UIFont *__f = MMReplacementUIFont((sizeValue)); \
            if (__f != nil) return __f; \
        } \
    } while (0)

static UIFont *mm_systemFontOfSize(id self, SEL _cmd, CGFloat size) {
    MM_RETURN_REPLACEMENT(size);
    return orig_systemFontOfSize(self, _cmd, size);
}

static UIFont *mm_systemFontOfSizeWeight(id self, SEL _cmd, CGFloat size, CGFloat weight) {
    MM_RETURN_REPLACEMENT(size);
    return orig_systemFontOfSizeWeight(self, _cmd, size, weight);
}

static UIFont *mm_systemFontOfSizeWeightDesign(id self, SEL _cmd, CGFloat size,
                                               CGFloat weight, NSString *design) {
    MM_RETURN_REPLACEMENT(size);
    return orig_systemFontOfSizeWeightDesign(self, _cmd, size, weight, design);
}

static UIFont *mm_boldSystemFontOfSize(id self, SEL _cmd, CGFloat size) {
    MM_RETURN_REPLACEMENT(size);        // 字体本身是加粗字形，不再叠伪粗体
    return orig_boldSystemFontOfSize(self, _cmd, size);
}

static UIFont *mm_italicSystemFontOfSize(id self, SEL _cmd, CGFloat size) {
    MM_RETURN_REPLACEMENT(size);        // 没有独立斜体字面，保持同一字面
    return orig_italicSystemFontOfSize(self, _cmd, size);
}

static UIFont *mm_monospacedSystemFontOfSizeWeight(id self, SEL _cmd, CGFloat size, CGFloat weight) {
    MM_RETURN_REPLACEMENT(size);
    return orig_monospacedSystemFontOfSizeWeight(self, _cmd, size, weight);
}

static UIFont *mm_monospacedDigitSystemFontOfSizeWeight(id self, SEL _cmd, CGFloat size, CGFloat weight) {
    MM_RETURN_REPLACEMENT(size);
    return orig_monospacedDigitSystemFontOfSizeWeight(self, _cmd, size, weight);
}

static UIFont *mm_fontWithName(id self, SEL _cmd, NSString *name, CGFloat size) {
    if (MMShouldReplaceName(name)) {
        MM_RETURN_REPLACEMENT(size);
    }
    return orig_fontWithName(self, _cmd, name, size);
}

static UIFont *mm_fontWithDescriptor(id self, SEL _cmd, UIFontDescriptor *desc, CGFloat size) {
    if (MMShouldReplaceUIFontDescriptor(desc)) {
        CGFloat s = size;
        if (s <= 0.0 && desc != nil) s = desc.pointSize;
        if (s <= 0.0) s = 17.0;
        MM_RETURN_REPLACEMENT(s);
    }
    return orig_fontWithDescriptor(self, _cmd, desc, size);
}

static UIFont *mm_fontWithSize(id self, SEL _cmd, CGFloat size) {
    if (MMShouldReplaceName([self fontName])) {
        MM_RETURN_REPLACEMENT(size);
    }
    return orig_fontWithSize(self, _cmd, size);
}

static UIFont *mm_preferredFontForTextStyle(id self, SEL _cmd, NSString *style) {
    UIFont *base = orig_preferredFontForTextStyle(self, _cmd, style);
    if (MMFontReady()) {
        UIFont *f = MMReplacementUIFont(base != nil ? base.pointSize : 17.0);
        if (f != nil) return f;
    }
    return base;
}

static UIFont *mm_preferredFontForTextStyleTrait(id self, SEL _cmd, NSString *style,
                                                 UITraitCollection *traits) {
    UIFont *base = orig_preferredFontForTextStyleTrait(self, _cmd, style, traits);
    if (MMFontReady()) {
        UIFont *f = MMReplacementUIFont(base != nil ? base.pointSize : 17.0);
        if (f != nil) return f;
    }
    return base;
}

static NSArray *mm_familyNames(id self, SEL _cmd) {
    NSArray *list = orig_familyNames(self, _cmd);
#if MM_INJECT_FONT_LISTS
    if (MMFontReady() && list != nil && ![list containsObject:MMFontFamilyName()]) {
        return [list arrayByAddingObject:MMFontFamilyName()];
    }
#endif
    return list;
}

static NSArray *mm_fontNamesForFamilyName(id self, SEL _cmd, NSString *family) {
#if MM_INJECT_FONT_LISTS
    if (MMFontReady() && [family isEqualToString:MMFontFamilyName()]) {
        return @[ MMFontPSName() ];
    }
#endif
    return orig_fontNamesForFamilyName(self, _cmd, family);
}

void MMInstallUIKitHooks(void) {
    Class cls = NSClassFromString(@"UIFont");
    if (cls == Nil) {
        MMLog(@"找不到 UIFont");
        return;
    }

    MMSwizzleClassMethod(cls, @selector(systemFontOfSize:),
                         (IMP)mm_systemFontOfSize, (IMP *)&orig_systemFontOfSize);
    MMSwizzleClassMethod(cls, @selector(systemFontOfSize:weight:),
                         (IMP)mm_systemFontOfSizeWeight, (IMP *)&orig_systemFontOfSizeWeight);
    MMSwizzleClassMethod(cls, @selector(systemFontOfSize:weight:design:),
                         (IMP)mm_systemFontOfSizeWeightDesign, (IMP *)&orig_systemFontOfSizeWeightDesign);
    MMSwizzleClassMethod(cls, @selector(boldSystemFontOfSize:),
                         (IMP)mm_boldSystemFontOfSize, (IMP *)&orig_boldSystemFontOfSize);
    MMSwizzleClassMethod(cls, @selector(italicSystemFontOfSize:),
                         (IMP)mm_italicSystemFontOfSize, (IMP *)&orig_italicSystemFontOfSize);
    MMSwizzleClassMethod(cls, @selector(monospacedSystemFontOfSize:weight:),
                         (IMP)mm_monospacedSystemFontOfSizeWeight, (IMP *)&orig_monospacedSystemFontOfSizeWeight);
    MMSwizzleClassMethod(cls, @selector(monospacedDigitSystemFontOfSize:weight:),
                         (IMP)mm_monospacedDigitSystemFontOfSizeWeight, (IMP *)&orig_monospacedDigitSystemFontOfSizeWeight);
    MMSwizzleClassMethod(cls, @selector(fontWithName:size:),
                         (IMP)mm_fontWithName, (IMP *)&orig_fontWithName);
    MMSwizzleClassMethod(cls, @selector(fontWithDescriptor:size:),
                         (IMP)mm_fontWithDescriptor, (IMP *)&orig_fontWithDescriptor);
    MMSwizzleClassMethod(cls, @selector(preferredFontForTextStyle:),
                         (IMP)mm_preferredFontForTextStyle, (IMP *)&orig_preferredFontForTextStyle);
    MMSwizzleClassMethod(cls, @selector(preferredFontForTextStyle:compatibleWithTraitCollection:),
                         (IMP)mm_preferredFontForTextStyleTrait, (IMP *)&orig_preferredFontForTextStyleTrait);
    MMSwizzleClassMethod(cls, @selector(familyNames),
                         (IMP)mm_familyNames, (IMP *)&orig_familyNames);
    MMSwizzleClassMethod(cls, @selector(fontNamesForFamilyName:),
                         (IMP)mm_fontNamesForFamilyName, (IMP *)&orig_fontNamesForFamilyName);
    MMSwizzleInstanceMethod(cls, @selector(fontWithSize:),
                            (IMP)mm_fontWithSize, (IMP *)&orig_fontWithSize);

    MMLog(@"UIKit 层钩子完成");
}

#pragma mark - CoreText 层

typedef void (*MMHookFunction)(void *symbol, void *replace, void **result);

static MMHookFunction gHookFunction = NULL;

static void *MMFindHookEngine(void) {
    void *p = dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (p != NULL) return p;

    static const char *paths[] = {
        "/usr/lib/libsubstrate.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libellekit.dylib",
        "/usr/lib/libhooker.dylib",
        "/var/jb/usr/lib/libhooker.dylib",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_LAZY);
        if (handle == NULL) continue;
        p = dlsym(handle, "MSHookFunction");
        if (p != NULL) return p;
    }
    return NULL;
}

static CTFontRef (*orig_CTFontCreateWithName)(CFStringRef, CGFloat, const CGAffineTransform *);
static CTFontRef (*orig_CTFontCreateWithNameAndOptions)(CFStringRef, CGFloat, const CGAffineTransform *, CTFontOptions);
static CTFontRef (*orig_CTFontCreateUIFontForLanguage)(CTFontUIFontType, CGFloat, CFStringRef);
static CTFontRef (*orig_CTFontCreateWithFontDescriptor)(CTFontDescriptorRef, CGFloat, const CGAffineTransform *);
static CTFontRef (*orig_CTFontCreateCopyWithAttributes)(CTFontRef, CGFloat, const CGAffineTransform *, CTFontDescriptorRef);
static CTFontRef (*orig_CTFontCreateCopyWithFamily)(CTFontRef, CGFloat, const CGAffineTransform *, CFStringRef);
static CTFontRef (*orig_CTFontCreateForString)(CTFontRef, CFStringRef, CFRange);
static CFArrayRef (*orig_CTFontManagerCopyAvailableFontFamilyNames)(void);
static CFArrayRef (*orig_CTFontManagerCopyAvailablePostScriptNames)(void);

static BOOL MMCoversString(CTFontRef font, CFStringRef string, CFRange range) {
    if (font == NULL || string == NULL || range.length <= 0) return NO;
    CFIndex n = range.length > 64 ? 64 : range.length;
    UniChar chars[64];
    CGGlyph glyphs[64];
    CFStringGetCharacters(string, CFRangeMake(range.location, n), chars);
    if (!CTFontGetGlyphsForCharacters(font, chars, glyphs, n)) return NO;
    for (CFIndex i = 0; i < n; i++) {
        if (glyphs[i] == 0 && chars[i] > 0x20) return NO;
    }
    return YES;
}

static CTFontRef mm_CTFontCreateWithName(CFStringRef name, CGFloat size,
                                         const CGAffineTransform *matrix) {
    if (gMMGuard > 0) return orig_CTFontCreateWithName(name, size, matrix);
    if (MMShouldReplaceName((__bridge NSString *)name)) {
        CTFontRef f = MMCreateReplacementFont(size);
        if (f != NULL) return f;
    }
    return orig_CTFontCreateWithName(name, size, matrix);
}

static CTFontRef mm_CTFontCreateWithNameAndOptions(CFStringRef name, CGFloat size,
                                                   const CGAffineTransform *matrix,
                                                   CTFontOptions options) {
    if (gMMGuard > 0) return orig_CTFontCreateWithNameAndOptions(name, size, matrix, options);
    if (MMShouldReplaceName((__bridge NSString *)name)) {
        CTFontRef f = MMCreateReplacementFont(size);
        if (f != NULL) return f;
    }
    return orig_CTFontCreateWithNameAndOptions(name, size, matrix, options);
}

static CTFontRef mm_CTFontCreateUIFontForLanguage(CTFontUIFontType type, CGFloat size,
                                                  CFStringRef language) {
    if (gMMGuard > 0) return orig_CTFontCreateUIFontForLanguage(type, size, language);
    if (MMFontReady() && type != kCTFontUIFontNone) {
        CTFontRef f = MMCreateReplacementFont(size);
        if (f != NULL) return f;
    }
    return orig_CTFontCreateUIFontForLanguage(type, size, language);
}

static CTFontRef mm_CTFontCreateWithFontDescriptor(CTFontDescriptorRef desc, CGFloat size,
                                                   const CGAffineTransform *matrix) {
    if (gMMGuard == 0 && MMShouldReplaceDescriptor(desc)) {
        CTFontRef f = MMCreateReplacementFont(size);
        if (f != NULL) return f;
    }
    return orig_CTFontCreateWithFontDescriptor(desc, size, matrix);
}

static CTFontRef mm_CTFontCreateCopyWithAttributes(CTFontRef font, CGFloat size,
                                                   const CGAffineTransform *matrix,
                                                   CTFontDescriptorRef attributes) {
    if (gMMGuard == 0 && MMFontShouldReplaceFont(font)) {
        CGFloat s = (size > 0.0) ? size : CTFontGetSize(font);
        CTFontRef f = MMCreateReplacementFont(s);
        if (f != NULL) return f;
    }
    return orig_CTFontCreateCopyWithAttributes(font, size, matrix, attributes);
}

static CTFontRef mm_CTFontCreateCopyWithFamily(CTFontRef font, CGFloat size,
                                               const CGAffineTransform *matrix,
                                               CFStringRef family) {
    if (gMMGuard == 0 && MMShouldReplaceName((__bridge NSString *)family)) {
        CGFloat s = (size > 0.0) ? size : CTFontGetSize(font);
        CTFontRef f = MMCreateReplacementFont(s);
        if (f != NULL) return f;
    }
    return orig_CTFontCreateCopyWithFamily(font, size, matrix, family);
}

static CTFontRef mm_CTFontCreateForString(CTFontRef base, CFStringRef string, CFRange range) {
    if (gMMGuard == 0 && base != NULL && string != NULL && range.length > 0 &&
        MMFontShouldReplaceFont(base)) {
        /* base 是还没被换掉的系统/App 字体；这段文字本字体有字形就直接给本字体，
           缺字（emoji、生僻符号）则交回系统级联，避免豆腐块。 */
        CTFontRef cand = MMCreateReplacementFont(CTFontGetSize(base));
        if (cand != NULL) {
            if (MMCoversString(cand, string, range)) return cand;
            CFRelease(cand);
        }
    }
    return orig_CTFontCreateForString(base, string, range);
}

static CFArrayRef mm_CTFontManagerCopyAvailableFontFamilyNames(void) {
    CFArrayRef list = orig_CTFontManagerCopyAvailableFontFamilyNames();
#if MM_INJECT_FONT_LISTS
    if (!MMFontReady() || list == NULL) return list;
    CFIndex count = CFArrayGetCount(list);
    CFStringRef ours = (__bridge CFStringRef)MMFontFamilyName();
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(list, i);
        if (s != NULL && CFStringCompare(s, ours, 0) == kCFCompareEqualTo) return list;
    }
    CFMutableArrayRef out = CFArrayCreateMutableCopy(kCFAllocatorDefault, count + 1, list);
    CFRelease(list);
    if (out == NULL) return NULL;
    CFArrayAppendValue(out, ours);
    return out;
#else
    return list;
#endif
}

static CFArrayRef mm_CTFontManagerCopyAvailablePostScriptNames(void) {
    CFArrayRef list = orig_CTFontManagerCopyAvailablePostScriptNames();
#if MM_INJECT_FONT_LISTS
    if (!MMFontReady() || list == NULL) return list;
    CFIndex count = CFArrayGetCount(list);
    CFStringRef ours = (__bridge CFStringRef)MMFontPSName();
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(list, i);
        if (s != NULL && CFStringCompare(s, ours, 0) == kCFCompareEqualTo) return list;
    }
    CFMutableArrayRef out = CFArrayCreateMutableCopy(kCFAllocatorDefault, count + 1, list);
    CFRelease(list);
    if (out == NULL) return NULL;
    CFArrayAppendValue(out, ours);
    return out;
#else
    return list;
#endif
}

void MMInstallCoreTextHooks(void) {
    if (!MMFontReady()) return;

    gHookFunction = (MMHookFunction)MMFindHookEngine();
    if (gHookFunction == NULL) {
        MMLog(@"没有 MSHookFunction（无 substrate/ElleKit），CoreText 层跳过");
        return;
    }

    void *coreText = dlopen("/System/Library/Frameworks/CoreText.framework/CoreText", RTLD_LAZY);
    if (coreText == NULL) {
        MMLog(@"dlopen CoreText 失败");
        return;
    }

    struct { const char *name; void *replacement; void **original; } items[] = {
        { "CTFontCreateWithName",                 (void *)mm_CTFontCreateWithName,                 (void **)&orig_CTFontCreateWithName },
        { "CTFontCreateWithNameAndOptions",       (void *)mm_CTFontCreateWithNameAndOptions,       (void **)&orig_CTFontCreateWithNameAndOptions },
        { "CTFontCreateUIFontForLanguage",        (void *)mm_CTFontCreateUIFontForLanguage,        (void **)&orig_CTFontCreateUIFontForLanguage },
        { "CTFontCreateWithFontDescriptor",       (void *)mm_CTFontCreateWithFontDescriptor,       (void **)&orig_CTFontCreateWithFontDescriptor },
        { "CTFontCreateCopyWithAttributes",       (void *)mm_CTFontCreateCopyWithAttributes,       (void **)&orig_CTFontCreateCopyWithAttributes },
        { "CTFontCreateCopyWithFamily",           (void *)mm_CTFontCreateCopyWithFamily,           (void **)&orig_CTFontCreateCopyWithFamily },
        { "CTFontCreateForString",                (void *)mm_CTFontCreateForString,                (void **)&orig_CTFontCreateForString },
        { "CTFontManagerCopyAvailableFontFamilyNames", (void *)mm_CTFontManagerCopyAvailableFontFamilyNames, (void **)&orig_CTFontManagerCopyAvailableFontFamilyNames },
        { "CTFontManagerCopyAvailablePostScriptNames", (void *)mm_CTFontManagerCopyAvailablePostScriptNames, (void **)&orig_CTFontManagerCopyAvailablePostScriptNames },
    };

    size_t total = sizeof(items) / sizeof(items[0]);
    size_t hooked = 0;
    for (size_t i = 0; i < total; i++) {
        if (items[i].original != NULL && *(items[i].original) != NULL) {
            hooked++;
            continue;
        }
        void *symbol = dlsym(coreText, items[i].name);
        if (symbol == NULL) {
            MMLog(@"CoreText 缺符号 %s", items[i].name);
            continue;
        }
        gHookFunction(symbol, items[i].replacement, items[i].original);
        if (*(items[i].original) != NULL) hooked++;
    }
    MMLog(@"CoreText 层钩子 %zu/%zu", hooked, total);
}
