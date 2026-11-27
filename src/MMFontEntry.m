//
//  MMFontEntry.m
//  MMFontSubstitute
//
//  dylib 载入即生效：抽字体 → 注册 → 装两层钩子。
//

#import "MMFontCore.h"

void MMInstallUIKitHooks(void);
void MMInstallCoreTextHooks(void);
void MMInstallWebViewHooks(void);

__attribute__((constructor))
static void MMFontSubstituteInit(void) {
    @autoreleasepool {
        MMBootstrap();
        if (!MMFontReady()) return;
        MMInstallUIKitHooks();
        MMInstallCoreTextHooks();
        MMInstallWebViewHooks();
    }
}
