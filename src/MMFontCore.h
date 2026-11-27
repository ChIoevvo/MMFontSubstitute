//
//  MMFontCore.h
//  MMFontSubstitute
//

#ifndef MMFontCore_h
#define MMFontCore_h

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 状态 / 信息 */
BOOL      MMFontReady(void);
NSString *MMFontPSName(void);
NSString *MMFontFamilyName(void);
BOOL      MMFontIsOwnName(NSString *name);

/* 启动：抽字体、注册、准备缓存。可重复调用。 */
void MMBootstrap(void);

/* 内嵌字体原始字节（不复制，直接引用 __DATA,__mmfont 映射页；WebView 用） */
NSData   *MMFontEmbeddedData(void);

/* 取替换字体（CT 版返回 +1，调用方负责 CFRelease；UIFont 版自动管理） */
CTFontRef MMCreateReplacementFont(CGFloat size);
UIFont   *MMReplacementUIFont(CGFloat size);

/* 替换策略 */
BOOL MMShouldReplaceName(NSString *name);
BOOL MMShouldReplaceDescriptor(CTFontDescriptorRef desc);
/* 某个已存在的 CTFont 是否该被换掉（带指针级缓存，热路径用） */
BOOL MMFontShouldReplaceFont(CTFontRef font);

/* 日志（MMFontVerbose=YES 时才输出） */
void MMLog(NSString *fmt, ...);

/* 防止钩子自递归的线程级计数 */
extern __thread int gMMGuard;
extern BOOL gMMVerbose;

#ifdef __cplusplus
}
#endif

#endif /* MMFontCore_h */
