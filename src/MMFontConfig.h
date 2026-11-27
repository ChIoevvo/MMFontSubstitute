//
//  MMFontConfig.h
//  MMFontSubstitute
//
//  目标字体与替换策略。换字体只需要改这里 + 换 font/MMFont.ttf。
//

#ifndef MMFontConfig_h
#define MMFontConfig_h

/* ===== 目标字体（与 font/MMFont.ttf 的 name 表一致） ===== */
#define MM_FONT_FILE_NAME    @"MMFont.ttf"
#define MM_FONT_PS_NAME      @"MMFontSub"
#define MM_FONT_FAMILY_NAME  @"渡-果の棉花宝宝加粗改の"

/* 嵌入在 dylib 的 __DATA,__mmfont 段里的字体砸不烂，优先用它；
   下面这些路径存在时优先读文件（方便手动换字体，不用重编）。 */
#define MM_FONT_SYSTEM_PATHS @[@"/Library/Fonts/MMFont.ttf", @"/var/jb/Library/Fonts/MMFont.ttf"]

/* ===== 策略 =====
   默认「全部替换」：不管 App 用系统字体、自带字体还是写死的 PostScript 名，
   一律换成目标字体；只放过 emoji / 图标字体（否则图标变豆腐块）。 */
#define MM_REPLACE_ALL_FONTS   1
#define MM_REPLACE_MONOSPACE   1   /* 0 = 等宽字体（Menlo/SF Mono/Courier）保留系统 */
#define MM_INJECT_FONT_LISTS   1   /* familyNames / CTFontManager 列表里补上本字体 */

/* 名字里带这些子串的一律不换（大小写不敏感） */
#define MM_SKIP_SUBSTRINGS @[ \
    @"emoji", @"sfproicons", @"lastresort", @"fontawesome", @"materialicons", \
    @"ionicons", @"iconfont", @"octicons", @"glyphicons", @"fontello", \
    @"themify", @"typicons", @"entypo", @"wings" ]

/* 等宽字体保留名单（MM_REPLACE_MONOSPACE=0 时生效） */
#define MM_MONO_SUBSTRINGS @[ @"menlo", @"monaco", @"courier", @"sfmono", @"monospaced", @"andale" ]

#endif /* MMFontConfig_h */
