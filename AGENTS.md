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
| macOS | ✅ 端到端可用 | NSWindow + WKWebView（objc FFI），含验证 API |
| Windows | ⚠️ experimental | COM 初始化链已通，`Navigate` 卡在 STA 生命周期问题，见 `webview-windows.rkt` 头注释 |
| Linux | 🔲 骨架 | GtkWindow + WebKitGTK 绑定未接线，见 `webview-linux.rkt` |

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
├── tray/             # 托盘：main.rkt 调度 + tray-{windows,macos,linux,stub}.rkt
└── webview/          # WebView：main.rkt 调度 + webview-{windows,macos,linux,stub}.rkt
glaze-cli/            # raco glaze init / dev / build
glaze-doc/            # scribble 文档
glaze-test/           # rackunit 套件（main.rkt 基础 + webview-test.rkt）
```

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
- `raco test` 环境下 main.rkt 的 e2e HTTP 测试在本机 Racket 9.2 偶发 connection refused（CI 的 8.12 正常），与 webview 无关
- macOS 多窗口共用主 RunLoop（每窗口一个泵线程，可运行但未优化）
