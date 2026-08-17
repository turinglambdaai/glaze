# Glaze

用 [Racket](https://racket-lang.org/) 做后端、Web 技术做前端，构建桌面应用。一个 Racket 版的 [Tauri](https://tauri.app/) —— 用 Racket 写业务逻辑，用 HTML/CSS/JS 构建界面，打包为桌面应用。

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) · **中文**

## 为什么选择 Glaze？

Racket 自带的 `racket/gui` 可以用，但很难做出现代化的产品级 UI。Glaze 采用不同的思路：从 Racket 启动本地 Web 服务，用系统浏览器（Phase 1）或嵌入式 WebView（Phase 3）展示。

你将获得：

- **Racket 写逻辑** —— 完整的宏系统、contracts、模式匹配
- **Web 写界面** —— Tailwind、Svelte、React 或任何 Web 框架
- **JSON API 桥接** —— 页面用普通 `fetch("/api/...")` 调用 Racket

### 横向对比

| | Glaze | Tauri | Electron | wails |
|---|---|---|---|---|
| 后端语言 | Racket | Rust | JS/Node | Go |
| 原生工具链 | **无需**（纯 FFI） | Rust + cargo | 无 | Go + WebView2 依赖 |
| 二进制体积 | 极小 | 小 | 100 MB+ | 小 |
| 前后端桥接 | HTTP JSON 路由（`fetch`） | `invoke()` IPC | Node API | 绑定层 |
| 无 WebView 时浏览器兜底 | **支持** | 不支持 | 不支持 | 不支持 |
| Agent 友好的 UI 验证（title/url/截图） | **内置** | 需 WebDriver | 需 CDP | 有限 |
| WebView 后端 | WebView2 / WKWebView / WebKitGTK | 相同 | 自带 Chromium | WebView2/WKWebView |

三个平台的 WebView 后端均通过真窗口 CI e2e（open、加载、截图、导航、关闭、on-close）。剩余诚实差距：IPC 为纯 JSON 无类型层、Linux 需要桌面会话或 Xvfb。

## 平台支持状态

| 能力 | macOS | Windows | Linux |
|---|---|---|---|
| HTTP 服务器 + 浏览器 | ✅ | ✅ | ✅ |
| 系统托盘 | ✅ | ✅ | ✅（CI 验证） |
| JSON API 桥接 | ✅ | ✅ | ✅ |
| 原生 WebView 窗口 | ✅ 端到端验证 | ✅ CI e2e（WebView2） | ✅ CI e2e（Xvfb + WebKitGTK） |
| `webview-title` / `webview-url` | ✅ | ✅ | ✅ |
| `webview-capture!`（截图） | ✅ | ✅（PrintWindow + PowerShell 转 PNG） | ✅（gdk_pixbuf） |
| `#:devtools?` | ✅（inspectable，macOS 13+） | ✅（`OpenDevToolsWindow`） | 🔲 |

原生后端不可用时，`run-app` / `open-window` 自动回退系统浏览器 —— 应用在所有平台都能跑。

## 环境要求

| 依赖 | 用途 |
|------|------|
| [Racket](https://racket-lang.org/) | 7.0 或更高版本（包含 `raco`） |

## 快速开始

### 1. 克隆

```bash
git clone https://github.com/turinglambdaai/glaze.git
cd glaze
```

### 2. 安装

```bash
raco pkg install glaze
```

### 3. 创建新项目

```bash
raco glaze init myapp
cd myapp
```

### 4. 运行

```bash
racket main.rkt
```

浏览器会自动打开 `http://127.0.0.1:8080`，显示一个可用的页面。

## CLI 命令

```bash
raco glaze init <name>   # 创建新的 Glaze 项目
raco glaze dev           # 启动开发服务器并自动打开浏览器
raco glaze build         # 构建可分发包（exe + 内置资源）
raco glaze help          # 显示帮助
```

### `build`

把 Glaze 项目打包为平台分发产物（`raco exe` + `raco distribute`），前端资源随可执行文件一起分发。

```bash
raco glaze build --name myapp              # 产出 dist/myapp(.exe) + dist/lib + dist/public
raco glaze build --name myapp --installer  # 额外产出 msi / dmg / AppImage（缺失工具链时回落为 zip/tar.gz）
```

选项：`--name`、`--icon <.ico/.icns>`、`--entry <path>`（默认 `main.rkt`）、`--out <dir>`（默认 `dist`）、`--embed-dlls`（Windows：单文件 exe）、`--installer`。

> installer 步骤会探测本机的打包工具链（Windows 的 WiX / NSIS，macOS 的 `create-dmg` / `hdiutil`，Linux 的 `appimagetool` / `linuxdeploy`），**缺失时优雅降级**为 `.zip` / `.tar.gz` 并打印提示告知需要安装什么。

## 项目结构

一个新的 Glaze 项目结构如下：

```
myapp/
├── main.rkt          # Racket 入口
└── public/
    └── index.html    # 前端页面
```

`main.rkt` 启动本地 HTTP 服务器，从 `public/` 目录提供静态文件并打开浏览器：

```racket
#lang racket/base

(require glaze)

(define-values (port server)
  (start-dev-server #:public-dir "public"))

(printf "Glaze app running at http://127.0.0.1:~a\n" port)
(open-browser (format "http://127.0.0.1:~a" port))

(with-handlers ([exn:break?
                 (lambda (e)
                   (stop-server server)
                   (printf "Server stopped.\n"))])
  (sync never-evt))
```

## 仓库结构

```
glaze/
├── glaze/            # Umbrella 包（安装 `glaze` 即包含全部组件）
├── glaze-lib/        # 核心库（服务器、API、浏览器启动、资源管理）
├── glaze-cli/        # CLI 工具（raco glaze init / dev）
├── glaze-doc/        # 文档（Scribble）
└── glaze-test/       # 测试
```

## API

### `run-app`

一键入口：自动挑空闲端口、启动服务器（静态 + JSON API）、打开原生 WebView 窗口、阻塞到窗口关闭。

```racket
(run-app #:public-dir "public"
         #:api (list (GET "api/ping" ...)))
;; webview 路径：窗口关闭 -> 服务器停止 -> (values 'webview shutdown)
;; 浏览器回退（无原生后端）：打开浏览器 -> (values 'browser shutdown)
```

### `start-server` / `start-dev-server`

启动本地 HTTP 服务器：静态文件 + SPA 回退 + 可选 JSON API 路由。`start-dev-server` 为兼容别名。

```racket
(start-server #:port 8080
              #:public-dir "public"
              #:api (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))))
;; 返回 (values port shutdown-proc)；返回前会确认端口已在监听
```

### `stop-server`

停止服务器。

```racket
(stop-server shutdown-proc)
```

### `open-browser`

用系统默认浏览器打开 URL（跨平台：Windows、macOS、Linux）。

```racket
(open-browser "http://127.0.0.1:8080")
```

## JavaScript 桥接

前端用普通 `fetch("/api/...")` 调 Racket —— 这是 Glaze 对 Tauri `invoke()` 的回答。同一套代码在嵌入式 WebView、系统浏览器回退、dev 调试（可 curl）下都工作。路由是普通值：

```racket
(require glaze)

(GET  "api/ping"            (lambda (req) (hasheq 'pong #t)))
(POST "api/items/:id/bump"  (lambda (req id) (hasheq 'id id 'bumped #t)))
(POST "api/echo"            (lambda (req)
                              (define body (request-json-body req))
                              (hasheq 'echo body)))
```

- Handler 收到 request 加捕获的 `:param`；返回 jsexpr（自动包装为 JSON 200）或完整 response
- `request-json-body` 解析 JSON body —— 注意 Racket jsexpr 把 JSON 对象键解析为 **symbol**（`(hash-ref body 'delta)`）
- handler 抛异常会变成 500 JSON 错误，不会断掉连接
- 未匹配的请求回落到静态文件（SPA `index.html` 回退）

页面侧：

```js
const s = await fetch('/api/counter/bump',
  {method:'POST', headers:{'Content-Type':'application/json'},
   body: JSON.stringify({delta: 5})}).then(r => r.json());
```

### 一处声明，三重产物 —— `define-api-routes`

```racket
(define-api-routes api
  [(POST "api/counter/bump")
   (bump [delta exact-nonnegative-integer? 1])   ; 必填+校验，或缺省
   (hasheq 'count (add1 delta))])
```

一个子句同时定义：Racket 过程（`bump`）、路由（坏输入 → 报参数名的 400；过程异常 → 500）、
JS 客户端入口 —— `/glaze/api.js` 自动提供 `glaze.api.counterBump({delta: 5})`、
`glaze.call(method, path, body)` 和 `glaze.on(name, fn)`。

### 后端 → 前端推送（SSE）

```racket
(define bus (make-event-bus))
(start-server ... #:events bus)
(bus-broadcast! bus 'count-changed (hasheq 'count 42))   ; 任意线程
```

```js
glaze.on('count-changed', s => render(s.count));
```

页面也可以直接 `new EventSource('/glaze/events')`。浏览器回退同样可用 —— 同源、无额外端口。

### 安全

- 仅服务 Host 为 `127.0.0.1` / `localhost` / `[::1]` 的请求（DNS rebinding 防护，恶意源 403）。
- API handler 永不断连接 —— 参数问题 400 JSON，过程异常 500 JSON（并送达 `run-app` 的
  `#:on-error`，接崩溃上报钩子）。
- 可选 API token（`#:api-token`）：保护 API 路由与 SSE 流（否则 401）；生成的 api.js 通过
  `glaze_token` cookie 引导，页面无需改动，程序化客户端发 `X-Glaze-Token`。
  诚实边界：对随手本机调用者提高门槛 —— 纯 HTTP 无法实现完整的本机进程隔离。
- 更新检查：`run-app #:check-update <清单url> #:current-version "1.0.0"` 拉取
  `{"version","url","notes"}`，stderr 提示并广播 `update-available`。自我替换由应用决策。

完整可运行的应用见 [`examples/counter/`](examples/counter/)。

## 系统集成（`glaze/sys`）

```racket
(require glaze/sys)
(clipboard-set! "hello")            ; (clipboard-get)
(notify! "下载完成" "report.pdf 已就绪")
(open-path "/Users/me/report.pdf")  ; 默认处理器打开
(reveal-path "/Users/me/report.pdf"); Finder/资源管理器中定位
(unless (single-instance? "com.me.app") (exit 0))
```

窗口控制（`glaze/webview`）：`webview-set-title!`、`webview-set-size!`、
`webview-set-fullscreen!`。

## 系统托盘

Glaze 提供跨平台的系统托盘，让你的应用驻留在通知区 / 菜单栏，带右键（macOS 为左键）菜单。后端按平台选择——纯 Racket FFI，无需编译任何原生代码：

- **Windows** — 通过 `ffi/unsafe` 调 `Shell_NotifyIconW`
- **macOS** — 通过 `ffi/unsafe/objc` 调 `NSStatusItem` / `NSMenu`
- **Linux** — 通过 `ffi/unsafe` 调 `libayatana-appindicator` + `libgtk-3`

运行时若某平台的原生库不可用，托盘会静默降级为空操作，应用的其余部分照常运行。

```racket
(require glaze)

(define t
  (make-tray #:icon #f
             #:tooltip "我的 Glaze 应用"
             #:menu (list (make-menu-item "退出"
                                          #:action (lambda () (exit 0))))))
(tray-set-tooltip! t "运行中")
;; ...稍后
(tray-close t)
```

> **macOS 注意**：纯菜单栏应用（不显示 Dock 图标）需要构建为 `.app` bundle 并设置 `LSUIElement`——`raco glaze build` 会为你配置好。

## 示例

| 示例 | 展示内容 |
|---|---|
| [`examples/showcase/`](examples/showcase/) | **综合演示（推荐先看）** —— 全部能力一屏尽览 |
| [`examples/hello/`](examples/hello/) | 最小应用 —— 8 行 `run-app` |
| [`examples/counter/`](examples/counter/) | JS↔Racket 桥接 —— `fetch` 调用 Racket 状态 |
| [`examples/webview-demo.rkt`](examples/webview-demo.rkt) | WebView 生命周期：加载、导航、关闭、验证 API |
| [`examples/agent-verify.rkt`](examples/agent-verify.rkt) | Agent 工作流：无人值守断言页面状态 + 截图 |
| [`examples/tray-demo.rkt`](examples/tray-demo.rkt) | 跨平台系统托盘 + 可用菜单 |

## 路线图

- [x] **Phase 1** — 本地 HTTP 服务器 + 系统浏览器
- [x] **Phase 2** — 前端资源打包、系统托盘、应用打包
- [x] **Phase 3** — 原生 WebView 嵌入（WebView2 / WKWebView / WebKitGTK）— *完成，三平台 CI e2e 验证*

> **Phase 3 完成：** 三个后端（macOS WKWebView、Windows WebView2、Linux WebKitGTK）均通过
> 真窗口 CI e2e——open、页面加载、`webview-title`/`url` 验证、`webview-capture!` 截图、
> `webview-navigate`、关闭（编程与系统按钮）、`#:on-close` 回调；`#:devtools?` 支持 macOS/Windows。
> 全程纯 Racket FFI，无编译器。剩余打磨（非阻塞）：Linux `#:devtools?`、Windows 窗口缩放跟随
> （`put_Bounds` 仅在创建时设置，未接 WM_SIZE）、多窗口体验。

## 许可证

基于 [MIT 许可证](LICENSE) 授权。
