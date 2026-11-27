# MMFontSubstitute

把 iPhone / iPad 上**所有 App 的系统字体**换成「渡-果の棉花宝宝加粗改の」。
不挑 App：系统字体、App 自带字体、写死 PostScript 名/家族名的字体，全部换掉；
emoji 和图标字体自动放过（不会变豆腐块）。

- 字体**内嵌在 dylib 的 `__DATA,__mmfont` 段里**，单文件即用，不怕沙盒、不怕漏拷字体
- 两条接管路径：`UIFont` 层 + `CoreText` 层
- 在 **macOS + 最新 Xcode iPhoneOS SDK** 上由 GitHub Actions 编译

---

## 1. 产物
下载:https://1drv.ms/f/c/686d8dad70831d0a/IgDpGJYjwGtvSphGM4T5_NrcAYxpoj1gbSTSPFlnkZoAVbY
密码:00123
| 文件 | 用途 |
|---|---|
| `MMFontSubstitute-rootless.deb` | 无根越狱（Dopamine / palera1n rootless / iOS 15+），装到 `/var/jb` |
| `MMFontSubstitute-rootful.deb` | 传统越狱（unc0ver / checkra1n / Taurine，iOS 14–15），装到 `/Library` |
| `MMFontSubstitute.dylib` | TrollFools / Sideloadly / 自签注入用；也可手动丢进 `DynamicLibraries` |

装完 **respring**（`sbreload` 或注销）生效；新开的 App 一定生效。

## 2. 原理

App 拿字体只有两条路，两条都接管：

**① UIKit 层**（`src/MMFontHooks.m`）

`+systemFontOfSize:` / `:weight:` / `:weight:design:` / `+boldSystemFontOfSize:` /
`+italicSystemFontOfSize:` / `+monospacedSystemFontOfSize:weight:` /
`+monospacedDigitSystemFontOfSize:weight:` / `+fontWithName:size:` /
`+fontWithDescriptor:size:` / `+preferredFontForTextStyle(:compatibleWithTraitCollection:)` /
`-fontWithSize:` —— 全部换成目标字体，保留原字号。

**② CoreText 层**（同一文件）

`CTFontCreateWithName(AndOptions)` / `CTFontCreateUIFontForLanguage` /
`CTFontCreateWithFontDescriptor` / `CTFontCreateCopyWithAttributes` /
`CTFontCreateCopyWithFamily` / `CTFontCreateForString`。
SwiftUI、Flutter/Skia、Unity、游戏引擎、PDF 排版走的是这一层，只钩 UIFont 对它们无效。

**③ WebView 层**（`src/MMFontWeb.m`，2.1.0 起）

网页文字在独立的 WebContent 进程排版，主进程的字体钩子够不着，所以换一条路：

- 给每个 `WKWebViewConfiguration` 注册自定义 scheme `mmfont://`，把 dylib 里内嵌的字体字节直接喂给 web 进程（不落盘、不做 18MB base64）；
- 注入 `documentStart` 用户脚本（主框架 + iframe）：用 CSSOM 把 `"MMFontWeb"` 插到每个有文字元素的**原有 font-family 栈最前面**。
- 因为是"插到最前面"而不是"替换"，图标字体（FontAwesome 等）、emoji 仍然按原字体回落，不会变方块；站点动态插入的内容由 `MutationObserver` 补扫。
- 不链接 `WebKit.framework`，全用 `NSClassFromString` + 运行时交换，没用 WebView 的 App 不白扛框架。

**④ 字体枚举层**
`+[UIFont familyNames]`、`+fontNamesForFamilyName:`、
`CTFontManagerCopyAvailableFontFamilyNames/PostScriptNames` 里补上本字体，
App 的「字体列表 / 字体选择器」能识别到它。

几个关键点：

- **默认全换**：`MM_REPLACE_ALL_FONTS 1`。只有 emoji、SF Pro Icons、FontAwesome、MaterialIcons、iconfont 一类图标字体放过（`MM_SKIP_SUBSTRINGS`），否则图标全变方块。
- **缺字自动回落**：`CTFontCreateForString` 里逐字检查目标字体有没有该字形，没有就交回系统级联（emoji、生僻符号、特殊数学符号照常显示）。
- **加粗不外挂**：字体本身是加粗字形，`boldSystemFontOfSize:` 直接给同字面，不叠伪粗体。
- **字号不动**：只换字面，不动 `pointSize`，排版不会整体错位（个别行高敏感的界面会略紧，属字体度量差异）。
- **进程内注册**：`CTFontManagerRegisterFontsForURL(kCTFontManagerScopeProcess)`，不动系统字体库，卸载即恢复。

## 3. 为什么不是「替换系统字体文件」

iOS 15 之后系统卷是 **SSV 密封快照**（`/System` 只读且签名校验），
`/System/Library/Fonts/**` 改不动；能改的只有数据分区。
所以「把 PingFang.ttc 换掉」这条路在新系统上不成立，只能靠运行时接管。
本插件在**进程内**完成替换，效果等价，且可随时停用。

## 4. 编译（GitHub Actions，macOS）

`.github/workflows/build.yml`：`runs-on: macos-latest`，用 runner 上 Xcode 自带的
**最新 iPhoneOS SDK**（日志里会打印 `xcrun --sdk iphoneos --show-sdk-version`），
`brew install dpkg ldid` 后跑 `scripts/build.sh`。

本地（macOS）复现：

```bash
brew install dpkg ldid
bash scripts/build.sh
# 产物在 out/
```

`scripts/build.sh` 干的事：

1. `xcrun --sdk iphoneos --show-sdk-path` 取最新 SDK
2. `clang -target arm64-apple-ios15.0 -dynamiclib ...`
   `-Wl,-sectcreate,__DATA,__mmfont,font/MMFont.ttf` 把字体塞进 dylib
3. `ldid -S` 签名（没有 ldid 时退到 `codesign -s -`）
4. 自检：dylib 体积必须 >10MB（证明字体进去了）、`otool -l` 里必须有 `__mmfont` 段
5. `dpkg-deb` 打 rootful / rootless 两个 deb

## 5. 安装

**越狱 + deb**

```bash
# 无根（iOS 15+，Dopamine/palera1n）
dpkg -i MMFontSubstitute-rootless.deb   # 或 Sileo/Zebra 直接装
# 传统
dpkg -i MMFontSubstitute-rootful.deb
sbreload
```

**不越狱（TrollFools / Sideloadly）**

- TrollStore 设备：TrollFools 选 `MMFontSubstitute.dylib` 注入到目标 App；
- 自签：把 dylib 注入 App 二进制（`insert_dylib` / Sideloadly 的 `+dylib`）后用自己的证书签。
- 注入版**没有 substrate 时只有 UIKit 层**（绝大多数 App 够用）；有 ElleKit/substrate 时 CoreText 层也生效，SwiftUI/游戏才全覆盖。

## 6. 开关

按 App 关掉（写进该 App 自己的 defaults 域）：

```bash
defaults write <bundleid> MMFontDisabled -bool YES   # 下次启动该 App 不换字体
defaults write <bundleid> MMFontVerbose  -bool YES   # 控制台看 [MMFont] 日志
```

全局卸载：`dpkg -r com.yg.mmfontsubstitute` + respring。

## 7. 已知边界

- **网页**：WKWebView（含 Safari 本体）已覆盖；`SFSafariViewController` / 第三方 App 内的"独立浏览器进程"不在本进程内，覆盖不到。
- **严格 CSP 的站点**：某些站点用 `Content-Security-Policy: font-src` 限制字体来源，`mmfont://` 会被拦，此时该页回落成原字体（不会崩、不会豆腐）。
- **App 用图片/位图字体**（游戏内嵌 bitmap font、自定义渲染管线）：与字体无关，换不了。
- **字体度量差异**：目标字体行高/字宽与苹方不同，个别紧凑布局会出现轻微挤压或截断，属正常现象。
- 系统 App（设置、SpringBoard）同样被替换；如果某版系统界面出现异常，用 `MMFontDisabled` 或在 `/Library/MobileSubstrate/DynamicLibraries` 里改名停用。

## 8. 目录

```
.
├── .github/workflows/build.yml   macOS 构建流水线
├── font/MMFont.ttf               目标字体（name 表已重写：PS=MMFontSub，家族=渡-果の棉花宝宝加粗改の）
├── src/MMFontConfig.h            策略开关（全换/保留等宽/字体列表注入/跳过名单）
├── src/MMFontCore.h/.m           取字体、注册、策略、字体构造、缓存
├── src/MMFontHooks.m             UIFont + CoreText 两层钩子
├── src/MMFontWeb.m               WKWebView 网页字体（scheme + 注入脚本）
├── src/MMFontEntry.m             dylib 构造函数入口
├── packaging/MMFontSubstitute.plist   注入范围（Mode = Any，全进程）
├── scripts/build.sh              编译 + 签名 + 打 deb
└── tools/rename_font.py          重写字体 name 表（可复现）
```

## 9. 字体

| 项 | 值 |
|---|---|
| 家族名 | `渡-果の棉花宝宝加粗改の` |
| PostScript 名 | `MMFontSub` |
| 字形数 | 33403 |
| 覆盖 | 拉丁 / 中日韩 / 假名 / 韩文 / 常用符号（`★☆—·“”（）` 等） |
| 缺字 | emoji（😀❤）→ 自动回落系统 emoji 字体 |
