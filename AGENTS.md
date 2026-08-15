# AGENTS.md

指引给 AI agent（及开发者）：如何理解、构建、测试、验证、改动 Glaze。

## 这是什么

Glaze 是 "Tauri-like framework for Racket"——Racket 写后端，Web 技术做前端，桌面应用。
三层能力：

1. **本地 HTTP 服务器**（Phase 1，稳定）：`glaze/server`
2. **资源打包 / 系统托盘 / 应用打包**（Phase 2，稳定）：`glaze/assets` / `glaze/tray` / `glaze/build`
3. **原生 WebView 窗口**（Phase 3，进行中）：`glaze/webview`

纯 Racket FFI，**不需要 C 编译器**。核心卖点之一是 agent 友好：框架提供
`webview-title` / `webview-url` / `webview-capture!` 验证 API，让 agent 能以编程方式
确认 UI 状态（无需人眼看屏幕）。

## 各平台 WebView 状态

| 平台 | 状态 | 说明 |
|------|------|------|
| macOS | ✅ 本机 + CI e2e | NSWindow + WKWebView（objc FFI），验证 API + devtools |
| Windows | ✅ CI e2e | 历史上卡在"COM apartment"——真相是 `get_CoreWebView2` vtable 索引错（25 被写成 3）。vtable 顺序已对官方 SDK 头文件核对，详见 `webview-windows.rkt` 头注释 |
| Linux | ✅ CI e2e（Xvfb） | 泵 + destroy 回调 + title/url/capture（gdk_pixbuf）；注意 ffi-lib 需要 multiarch 绝对路径兜底 |

## 快速命令

```bash
# 安装（本地开发，链接方式）
raco pkg install --auto --no-docs --link ./glaze-lib ./glaze-cli ./glaze-test

# 编译
raco make glaze-lib/main.rkt glaze-cli/cli.rkt

# 测试（macOS 上含 WebView e2e；Linux/Windows 自动跳过 macOS 段）
raco test glaze-test/

# 跑 GUI 示例（会开真窗口）
racket -e '(require glaze/server glaze/webview/main)
  (define-values (p stop) (start-server #:port 18940 #:public-dir "public"))
  (define wv (open-window (format "http://127.0.0.1:~a/" p)))
  (sleep 30) (webview-close wv) (stop)'
```

## 项目结构

```
glaze-lib/
├── server.rkt        # start-server / stop-server（start-dev-server 是别名）
├── browser.rkt       # open-browser（跨平台系统浏览器）
├── api.rkt           # define-api 宏（JSON 端点）
├── assets.rkt        # public/ 目录解析、MIME
├── build.rkt         # raco exe + distribute 封装
├── app.rkt           # run-app：服务+窗口+生命周期一键入口
├── tray/             # 托盘：main.rkt 调度 + tray-{windows,macos,linux,stub}.rkt
└── webview/          # WebView：main.rkt 调度 + webview-{windows,macos,linux,stub}.rkt
glaze-cli/            # raco glaze init / dev / build
glaze-doc/            # scribble 文档
glaze-test/           # rackunit 套件（main.rkt 基础 + webview-test.rkt + api-test.rkt）
examples/             # hello / counter（JS↔Racket 桥接）/ agent-verify / tray-demo / webview-demo
```

## 系统集成（glaze/sys）

- 剪贴板（三平台 FFI）、通知（mac osascript / linux notify-send；windows 待接）、
  open/reveal、单实例锁（派生端口绑定）
- 窗口控制：`webview-set-title!/set-size!/set-fullscreen!`（四后端）
- **AppKit 必须显式加载**：Racket 只链接 Foundation；不加载 AppKit 的进程里
  NSStatusBar/NSPasteboard 等类为 NULL，objc 消息发给 nil 静默返回 nil（曾致 tray 空转）

## 加固层

- `#:api-token`（start-server/run-app）：只护 API+SSE；api.js 引导 cookie、程序化走 `X-Glaze-Token`；
  诚实边界写在 README（纯 HTTP 挡不住执意读本机端口的进程）
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

每个 webview 后端模块必须导出同名 7 个过程，调度层按 `(system-type 'os)` 动态加载：

`open-webview` / `supported?` / `close` / `navigate` / `title` / `url` / `capture!`

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

- `glaze-lib/webview/webview-windows.rkt`：COM vtable 调用形式、out 参数两箭头形式、回调内对象生命周期
- `glaze-lib/webview/webview-macos.rkt`：`_double` 拒绝精确整数、结构体传参必须 `#:type`、`runMode:beforeDate:` vs `nextEventMatchingMask:`（后者不服务 RunLoop 源）、泵线程必须让出调度器

## 不要破坏的契约

- 后端 7 导出 + 公开层 `webview-*` 名称（测试和下游依赖）
- `open-window` 返回 `webview?` 或 `#f`（配合 `#:fallback-browser?` 语义）
- `raco glaze` 子命令名与参数
- tray 公开 API（`make-tray` 等五个）

## 已知问题

- Windows `Navigate` 卡 COM apartment（头部注释有完整分析）
- macOS 多窗口共用主 RunLoop（每窗口一个泵线程，可运行但未优化）
- **后台会话白屏**：从无控制终端的分离会话启动（如 CI 后台任务、`nohup`、某些 agent 工具的后台执行）时，
  macOS 窗口可能停在白屏——WebKit 加载/IPC 全通（`webview-title` 正常），但绘制不上屏（窗口合成被冻结）。
  前台会话（用户终端）不受影响。诊断时优先怀疑启动会话，而不是 glaze 代码
