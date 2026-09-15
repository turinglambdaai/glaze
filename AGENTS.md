# AGENTS.md

指引给 AI agent（及开发者）：如何理解、构建、测试、验证、改动 Glaze。

## 这是什么

Glaze 是 "Tauri-like framework for Racket"——Racket 写后端，Web 技术做前端，桌面应用。
三层能力：

1. **本地 HTTP 服务器**（Phase 1，稳定）：`glaze/server`
2. **资源打包 / 系统托盘 / 应用打包**（Phase 2，稳定）：`glaze/assets` / `glaze/tray` / `glaze/build`
3. **原生 WebView 窗口**（Phase 3，已完成，三平台 CI e2e 验证）：`glaze/webview`

纯 Racket FFI，**不需要 C 编译器**。核心卖点之一是 agent 友好：框架提供
`webview-title` / `webview-url` / `webview-capture!` 验证 API，让 agent 能以编程方式
确认 UI 状态（无需人眼看屏幕）。

## 各平台 WebView 状态

| 平台 | 状态 | 说明 |
|------|------|------|
| macOS | ✅ 本机 + CI e2e | NSWindow + WKWebView（objc FFI），验证 API + devtools |
| Windows | ✅ CI e2e | 历史上卡在"COM apartment"——真相是 `get_CoreWebView2` vtable 索引错（25 被写成 3）。vtable 顺序已对官方 SDK 头文件核对，详见 `webview-windows.rkt` 头注释 |
| Linux | ✅ CI e2e（Xvfb） | 泵 + destroy 回调 + title/url/capture（gdk_pixbuf）；注意 ffi-lib 需要 multiarch 绝对路径兜底 |

## 商业化层（签名 / 许可证 / 更新校验）

- **菜单派发（`webview-set-menu!`）**：声明式 spec 复用 tray-protocol（`make-menu` +
  `make-menu-item`，`#:accel`）。macOS 是 NSApp 主菜单上追加自定义段（标准 Edit/Window
  只装一次——`ensure-app!` 重装会冲掉自定义菜单）；macOS 用 target+tag 派发（`GlazeMenuTarget`
  单例），Windows 用 WM_COMMAND 的 LOWORD(wParam)，Linux 用 "activate" 信号。
  **两个已踩坑**：① menu-sema 不能在重建菜单的整个过程中持有（build 内部还要申请 tag → 自锁）；
  注册和派发必须查同一张表（id-allocator 的表，别另开 hash）。② 加速键在 macOS 真实生效，
  Win/Linux 仅展示（v1 限制，写进文档）
- **测试菜单派发**：`performActionForItemAtIndex:` 对 objc-target 菜单项是静默 no-op；
  用 `NSApp sendAction: (item action) to: (item target) from: item` 才是真点击路径
- **文件对话框**：macos NSSavePanel（AppKit 显式 ffi-lib 加载）；Windows comdlg32（UTF-16
  编解码用 bytes-open-converter "UTF-8"/"UTF-16LE"，platform-* 名字在 macOS 不存在）；
  Linux zenity/kdialog 子进程。#f=取消，后端缺失 RAISE
- **开机自启**：macOS SMAppService（13+、需打包 .app、无 TCC 弹窗）；Windows HKCU Run 键
  （reg.exe 子进程）；Linux ~/.config/autostart 桌面条目（测试用 XDG_CONFIG_HOME 覆盖）

- `glaze/license`：RSA-2048/SHA-256 离线许可证，签名走**系统 openssl CLI 子进程**（三平台
  开箱即有），不引入 crypto 包。`machine-id` = IOPlatformUUID(macOS)/
  /etc/machine-id(Linux)/MachineGuid(Win) 的 SHA-256 摘要。`validate-license` 的失败
  reason 是稳定标签（signature/expired/machine/product/...），改语义先改测试
- **macOS 打包布局**：`raco distribute` 产出的是扁平 bin/+lib/（各版本形状不一），build-app
  自己组装 `.app`（Contents/MacOS + lib + Info.plist + PkgInfo）。launcher 的
  `@executable_path/../lib` 在 MacOS/ 下深度不变，搬移安全；homebrew CS 版的 framework
  引用是绝对路径（不可重定位），官方发行版才是可分发的——发布用官方 Racket 构建
- **codesign 顺序陷阱**：嵌套代码（framework dylib）先签、bundle 后签；一把 `--deep` 在
  Apple Silicon 会产出 Team-ID 不匹配的签名（dyld 拒绝映射）。adhoc 身份（`-`）下必须跳过
  `--options runtime`——hardened runtime 的 library validation 会拒绝 adhoc 的自身 framework
- `raco exe` 产出的 launcher 是只读的，`raco distribute` 写段会 EACCES（9.3 实测），build-app
  里已 chmod u+w；codesign 前同样要保证主 exe 可写
- 签名失败**中止构建**（假装签好的产物比失败更糟）；工具链缺失降级响亮告警——与 installer
  的降级语义不同，别搞混
- 更新 manifest 的可选 `"sha256"` 由 `verify-file-sha256` 校验；`#f` 返回值 = "无法校验"，
  永远不当成"校验通过"

## 快速命令

```bash
# 安装（本地开发，链接方式；仓库根即单一包）
# 注意：--link 的路径末元素必须是包名，"." 不合法，用 "$PWD"
raco pkg install --auto --no-docs --link "$PWD"

# 拉取更新后刷新链接包
raco pkg update --link "$PWD"

# 编译
raco make glaze/main.rkt glaze-cli/cli.rkt

# 测试（macOS 上含 WebView e2e；Linux/Windows 自动跳过 macOS 段）
raco test glaze-test/

# 跑 GUI 示例（会开真窗口）
racket -e '(require glaze/server glaze/webview/main)
  (define-values (p stop) (start-server #:port 18940 #:public-dir "public"))
  (define wv (open-window (format "http://127.0.0.1:~a/" p)))
  (sleep 30) (webview-close wv) (stop)'
```

## 打包规则（单包多集合）

仓库根 = 一个包（`info.rkt`，`collection 'multi`）。包级字段（name/deps/version/raco-commands…）
在根 `info.rkt`；但 **`scribblings` 和 `raco-commands` 是集合级字段**，必须放对应集合目录的
`info.rkt`（`glaze-doc/info.rkt`、`glaze-cli/info.rkt`），raco 和 raco setup 只扫集合信息，
放包根不生效（`raco glaze` 命令会消失）。examples/ 与 scripts/ 带集合级 `compile-omit-paths`，
setup 不编译示例正文。

- **版本号格式**：Racket `valid-version?` 拒绝尾部 `.0` 分量——写 `"0.5"` 不写 `"0.5.0"`
- **安装路径**：`raco pkg install --link` 的路径末元素必须是包名，`.`/`./` 不合法，用 `"$PWD"`

## 项目结构

仓库根目录即**一个**可安装的 Racket 包（根 `info.rkt`，`collection 'multi`），
每个顶层目录是一个集合（collection）：

```
glaze/                # 仓库根 = `glaze` 包：一次安装装齐下列全部
├── info.rkt          # 包元数据（deps / version / raco-commands）
├── glaze/            # 核心库（collection "glaze"）
│   ├── server.rkt    # start-server / stop-server（start-dev-server 是别名）
│   ├── browser.rkt   # open-browser（跨平台系统浏览器）
│   ├── api.rkt       # API 路由值（GET/POST/PUT/DELETE + :param 捕获）
│   ├── api-macros.rkt # define-api-routes（一处声明 = 过程+路由+JS 客户端）
│   ├── events.rkt    # 事件总线 → 内置 SSE 端点 /glaze/events
│   ├── assets.rkt    # public/ 目录解析、MIME
│   ├── build.rkt     # raco exe + distribute 封装
│   ├── update.rkt    # 更新检查（check-update / newer-version?）
│   ├── app.rkt       # run-app：服务+窗口+生命周期一键入口
│   ├── sys/          # 系统集成：剪贴板/通知/open/reveal/单实例（main 调度 + 平台后端）
│   ├── tray/         # 托盘：main.rkt 调度 + tray-{windows,macos,linux,stub}.rkt
│   └── webview/      # WebView：main.rkt 调度 + webview-{windows,macos,linux,stub}.rkt
├── glaze-cli/        # raco glaze init / dev / build
├── glaze-doc/        # scribble 文档（scribblings 声明在其集合级 info.rkt）
├── glaze-test/       # rackunit 套件（main + webview + api + events + hardening + sys）
├── examples/         # showcase / hello / counter / agent-verify / tray-demo / webview-demo（不参与 setup 编译）
└── scripts/          # webview-e2e.rkt（CI 用）
```

## 系统集成（glaze/sys）

- 剪贴板（三平台 FFI）、通知（三平台：mac osascript / linux notify-send /
  windows WinRT toast 经 PowerShell 子进程，脚本走临时 .ps1 避开命令行转义）、
  open/reveal、单实例锁（派生端口绑定）
- 窗口控制：`webview-set-title!/set-size!/set-fullscreen!`、`webview-focus!`（四后端）
- **AppKit 必须显式加载**：Racket 只链接 Foundation；不加载 AppKit 的进程里
  NSStatusBar/NSPasteboard 等类为 NULL，objc 消息发给 nil 静默返回 nil（曾致 tray 空转）

## 加固层

- `#:api-token`（start-server/run-app）：只护 API+SSE；run-app 打开一次性 `?glaze-token=` 引导 URL，
  服务器把 token 换成 HttpOnly cookie 后 302 回净路径；api.js 有意不发凭据（曾经发过 = 任何本地进程
  curl 一下就绕过 token）；程序化走 `X-Glaze-Token`；诚实边界写在 README（同用户进程仍可读内存）
- `current-glaze-error-reporter`（parameter）：500 路径的异常上报，run-app `#:on-error` 装配；
  **必须先 parameterize 再 start-server**（连接线程继承 accept 循环的 parameterization）
- `glaze/update`：`check-update` + `newer-version?`（数值点分比较，"1.10">"1.9"）；run-app
  `#:check-update`/`#:current-version` 通知 + 广播；注意 `#rx` 不支持 `{n}` 量词（用 `#px`）

## 事件推送 / 宏路由 / 内置端点

- `glaze/events`：`make-event-bus` + `bus-broadcast!` → 内置 SSE 端点 `GET /glaze/events`
  （15s keepalive；慢订阅者溢出丢事件不阻塞广播方）
- `glaze/api-macros`：`define-api-routes` 一处声明 = Racket 过程 + 类型化路由 + JS 客户端入口；
  path 里的 `:id` 参数自动从 URL 取，其余从 JSON body 取（**symbol 键**）
- 内置端点：`/glaze/api.js`（生成客户端，`#:serve-api-client? #f` 关闭）
- Host 头校验默认开启（只认 127.0.0.1/localhost/[::1]）

## JS↔Racket 桥接（define-api 已废除）

前端 `fetch("/api/...")` → Racket JSON。路由是普通值（`glaze/api` 的 GET/POST/PUT/DELETE +
`:param` 捕获），由 `start-server #:api` 或 `run-app #:api` 挂载。**陷阱**：Racket jsexpr 把
JSON 对象键解析为 symbol（`hash-ref body 'delta`，不是 `"delta"`）——写成字符串键会静默取默认值。

## 后端契约（webview 与 tray 同构）

每个 webview 后端模块必须导出同名 13 个过程，调度层按 `(system-type 'os)` 动态加载：

`open-webview` / `supported?` / `close` / `navigate` / `title` / `url` / `capture!` /
`set-title!` / `set-size!` / `set-fullscreen!` / `focus!` / `set-menu!` / `closed?`

约定：

- 后端不可用 → `supported?` 返回 `#f`，`open-webview` 抛错（公开层捕获后返回 `#f`）
- 验证 API 拿不到值就返回 `#f`（不许抛错）
- `capture!` 接受 `(or/c #f string? path?)`，返回 PNG 路径或 `#f`
- 公开层（`webview/main.rkt`）再做 `webview-*` 前缀包装；新增能力先扩后端契约，四个后端都要补导出

## Agent 验证工作流（改 webview/tray 后必做）

改了 FFI 代码后，别只跑单测——真机验证才是权威（macOS 本机即可）：

```racket
#lang racket/base
(require glaze/server glaze/webview/main)
;; 1. 起服务 + 开窗口
;; 2. 轮询 webview-title / webview-url 直到预期值（说明页面真的加载了）
;; 3. webview-capture! 截图 → 用视觉能力看图确认渲染正确
;; 4. webview-close → 确认 #:on-close 触发
```

要点（都是踩过的坑）：

- **不要用固定 sleep 等加载**——轮询 + deadline（首次导航含 WebContent 冷启动约 2s）
- `webview-capture!` 在窗口首次合成上屏前会返回 `#f`，重试几秒
- 截图能拿到 = 窗口在活跃 Space 上；被全屏应用挡住时 title/url 仍可验证

## FFI 发现（改代码前先读）

两个后端文件的头部注释沉淀了全部平台级 FFI 结论，改 FFI 前必读：

- `glaze/webview/webview-windows.rkt`：COM vtable 调用形式、out 参数两箭头形式、回调内对象生命周期
- `glaze/webview/webview-macos.rkt`：`_double` 拒绝精确整数、结构体传参必须 `#:type`、`runMode:beforeDate:` vs `nextEventMatchingMask:`（后者不服务 RunLoop 源）、泵线程必须让出调度器

## 不要破坏的契约

- 后端导出契约 + 公开层 `webview-*` 名称（测试和下游依赖）
- `open-window` 返回 `webview?` 或 `#f`（配合 `#:fallback-browser?` 语义）
- `raco glaze` 子命令名与参数
- tray 公开 API（`make-tray` 等五个）

## 已知问题

- macOS 多窗口：单一共享泵线程服务所有窗口（0.3.x 是每窗口一个泵线程）；0→1 转变触发启动，
  最后一个窗口关闭时退出。多窗口 e2e 在 `webview-test.rkt`
- **后台会话白屏**：从无控制终端的分离会话启动（如 CI 后台任务、`nohup`、某些 agent 工具的后台执行）时，
  macOS 窗口可能停在白屏——WebKit 加载/IPC 全通（`webview-title` 正常），但绘制不上屏（窗口合成被冻结）。
  窗口现已 `orderFrontRegardless` 无条件置前（缓解）；本机 `nohup` 探针已验证正常合成+截图。
  若再现：`webview-title`/`url` 正常而 `webview-capture!` 返回 `#f` 即此症状，优先换前台终端启动，
  而不是排查 glaze 代码
