//
//  MMFontWeb.m
//  MMFontSubstitute
//
//  让 WKWebView 里的网页文字也用目标字体。
//
//  网页文字在独立的 WebContent 进程里排版，主进程的字体钩子够不着，
//  所以这里走另一条路：
//    1) 在每个 WKWebViewConfiguration 上注册自定义 scheme（mmfont://），
//       把内嵌字体直接喂给 web 进程（不落盘、不占 18MB base64）；
//    2) 注入 documentStart 用户脚本：用 CSSOM 给每个有文字的元素把
//       "MMFontWeb" 插到它原有 font-family 栈的最前面。
//  这样图标字体/emoji 仍然按原字体回落，不会变方块。
//
//  不链接 WebKit.framework（避免给所有进程白扛一个框架），
//  全部用 NSClassFromString + 运行时方法交换。
//

#import "MMFontCore.h"
#import "MMFontConfig.h"

#import <objc/runtime.h>

void MMInstallWebViewHooks(void);

#pragma mark - 与 WebKit 同名的协议声明
//
// 不 import <WebKit/WebKit.h>，所以这里自带一份声明；
// 运行时按协议名比对，WebKit 的 conformsToProtocol: 检查能通过。

@protocol WKURLSchemeHandler <NSObject>
@required
- (void)webView:(id)webView startURLSchemeTask:(id)urlSchemeTask;
- (void)webView:(id)webView stopURLSchemeTask:(id)urlSchemeTask;
@end

@protocol MMSchemeTask <NSObject>
@required
- (NSURLRequest *)request;
- (void)didReceiveResponse:(NSURLResponse *)response;
- (void)didReceiveData:(NSData *)data;
- (void)didFinish;
- (void)didFailWithError:(NSError *)error;
@end

#pragma mark - 字体 scheme handler

@interface MMFontSchemeHandler : NSObject <WKURLSchemeHandler>
+ (instancetype)shared;
@end

@implementation MMFontSchemeHandler

+ (instancetype)shared {
    static MMFontSchemeHandler *handler = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handler = [[MMFontSchemeHandler alloc] init]; });
    return handler;
}

- (void)webView:(id)webView startURLSchemeTask:(id)urlSchemeTask {
    id<MMSchemeTask> task = (id<MMSchemeTask>)urlSchemeTask;
    NSData *data = MMFontEmbeddedData();
    if (data == nil) {
        NSError *err = [NSError errorWithDomain:@"MMFontSubstitute" code:1 userInfo:nil];
        [task didFailWithError:err];
        return;
    }
    NSURL *url = [[task request] URL];
    NSDictionary *headers = @{
        @"Content-Type" : @"font/ttf",
        @"Access-Control-Allow-Origin" : @"*",
        @"Cache-Control" : @"max-age=31536000",
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                             statusCode:200
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:headers];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(id)webView stopURLSchemeTask:(id)urlSchemeTask {
    /* 同步返回，无需处理 */
}

@end

#pragma mark - 注入脚本

static NSString *MMWebScriptSource(void) {
    static NSString *source = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source =
        @"(function(){\n"
        @"  if (window.__mmFontWeb) return;\n"
        @"  window.__mmFontWeb = 1;\n"
        @"  var FAM = 'MMFontWeb';\n"
        @"  var SRC = 'mmfont://font/MMFont.ttf';\n"
        @"  function apply(){\n"
        @"    var root = document.body;\n"
        @"    if (!root) return;\n"
        @"    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null, false);\n"
        @"    var n;\n"
        @"    while ((n = walker.nextNode())) {\n"
        @"      var p = n.parentElement;\n"
        @"      if (!p) continue;\n"
        @"      var tag = p.tagName;\n"
        @"      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TITLE' || tag === 'TEXTAREA') continue;\n"
        @"      var t = n.nodeValue;\n"
        @"      if (!t || !t.replace(/\\s+/g, '')) continue;\n"
        @"      var fam = getComputedStyle(p).fontFamily;\n"
        @"      if (!fam) continue;\n"
        @"      if (p.__mmFontFam === fam) continue;\n"
        @"      p.__mmFontFam = fam;\n"
        @"      p.style.setProperty('font-family', '\"' + FAM + '\", ' + fam, 'important');\n"
        @"    }\n"
        @"  }\n"
        @"  function boot(){\n"
        @"    apply();\n"
        @"    setTimeout(apply, 350);\n"
        @"    setTimeout(apply, 1200);\n"
        @"    var timer = null;\n"
        @"    var mo = new MutationObserver(function(){\n"
        @"      if (timer) return;\n"
        @"      timer = setTimeout(function(){ timer = null; apply(); }, 500);\n"
        @"    });\n"
        @"    mo.observe(document.documentElement, { childList: true, subtree: true });\n"
        @"  }\n"
        @"  function start(){\n"
        @"    if (document.body) boot();\n"
        @"    else document.addEventListener('DOMContentLoaded', boot, { once: true });\n"
        @"  }\n"
        @"  var f = null;\n"
        @"  try { f = new FontFace(FAM, 'url(\"' + SRC + '\")'); } catch (e) { f = null; }\n"
        @"  if (f) {\n"
        @"    try { document.fonts.add(f); } catch (e) {}\n"
        @"    f.load().then(start, start);\n"
        @"  } else {\n"
        @"    start();\n"
        @"  }\n"
        @"})();\n";
    });
    return source;
}

#pragma mark - 方法交换

static void MMSwizzleInstance(Class cls, SEL sel, IMP replacement, IMP *storage) {
    if (cls == Nil || sel == NULL) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {
        MMLog(@"WebKit 缺方法 -%@", NSStringFromSelector(sel));
        return;
    }
    *storage = method_getImplementation(m);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        method_setImplementation(m, replacement);
    }
}

#pragma mark - 配置 WKWebViewConfiguration

static const void *kMMWebPrepared = &kMMWebPrepared;

static id (*orig_cfgInit)(id, SEL);
static id (*orig_cfgInitCoder)(id, SEL, NSCoder *);
static id (*orig_wvInit)(id, SEL, CGRect, id);

static void MMPrepareConfiguration(id config) {
    if (!MMFontReady() || config == nil) return;
    if (objc_getAssociatedObject(config, kMMWebPrepared) != nil) return;
    objc_setAssociatedObject(config, kMMWebPrepared, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        [config setURLSchemeHandler:[MMFontSchemeHandler shared] forURLScheme:@"mmfont"];
    } @catch (NSException *e) {
        MMLog(@"注册 mmfont scheme 失败: %@", e.reason);
    }

    id controller = [config userContentController];
    Class scriptClass = NSClassFromString(@"WKUserScript");
    if (controller != nil && scriptClass != Nil) {
        id script = [[scriptClass alloc] initWithSource:MMWebScriptSource()
                                          injectionTime:0          /* AtDocumentStart */
                                       forMainFrameOnly:YES];      /* 只主框架：iframe 各自拉 13MB 字体不划算 */
        if (script != nil) [controller addUserScript:script];
    }
}

static id mm_cfgInit(id self, SEL _cmd) {
    if (orig_cfgInit == NULL) return self;
    id config = orig_cfgInit(self, _cmd);
    MMPrepareConfiguration(config);
    return config;
}

static id mm_cfgInitCoder(id self, SEL _cmd, NSCoder *coder) {
    if (orig_cfgInitCoder == NULL) return self;
    id config = orig_cfgInitCoder(self, _cmd, coder);
    MMPrepareConfiguration(config);
    return config;
}

static id mm_wvInit(id self, SEL _cmd, CGRect frame, id configuration) {
    if (orig_wvInit == NULL) return self;
    MMPrepareConfiguration(configuration);   /* 建 webview 前先改配置 */
    return orig_wvInit(self, _cmd, frame, configuration);
}

#pragma mark - 安装

static BOOL gWebHooksInstalled = NO;
static BOOL gRetryObserverAdded = NO;

void MMInstallWebViewHooks(void) {
    if (gWebHooksInstalled || !MMFontReady()) return;

    Class configClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");

    if (configClass == Nil && webViewClass == Nil) {
        /* 该进程还没加载 WebKit，等 App 激活时再试一次 */
        if (!gRetryObserverAdded) {
            gRetryObserverAdded = YES;
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            MMInstallWebViewHooks();
                        }];
        }
        return;
    }

    if (configClass != Nil) {
        MMSwizzleInstance(configClass, @selector(init), (IMP)mm_cfgInit, (IMP *)&orig_cfgInit);
        MMSwizzleInstance(configClass, @selector(initWithCoder:), (IMP)mm_cfgInitCoder, (IMP *)&orig_cfgInitCoder);
    }
    if (webViewClass != Nil) {
        MMSwizzleInstance(webViewClass, @selector(initWithFrame:configuration:),
                          (IMP)mm_wvInit, (IMP *)&orig_wvInit);
    }

    gWebHooksInstalled = YES;
    MMLog(@"WebView 层钩子完成");
}
