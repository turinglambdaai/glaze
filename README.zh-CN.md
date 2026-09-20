# Glaze

用 [Racket](https://racket-lang.org/) 做后端、Web 技术做前端，构建桌面应用。一个 Racket 版的 [Tauri](https://tauri.app/) —— 用 Racket 写业务逻辑，用 HTML/CSS/JS 构建界面，最终运行在真正的桌面窗口中。

[![CI](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Release](https://img.shields.io/badge/release-0.7.0-C15F3C)](CHANGELOG.md)

[English](README.md) · **中文**

<p align="center"><img src="docs/showcase.png" alt="Glaze Showcase —— 全部能力一屏尽览" width="720"></p>

## 为什么选择 Glaze？

Racket 自带的 `racket/gui` 可以用，但很难做出现代化的产品级 UI。Glaze 采用不同的思路：Racket 在本机提供应用前端与 API，然后把 HTML/CSS/JS 渲染在**原生桌面窗口中的系统 WebView** 里：Windows 使用 WebView2，macOS 使用 WKWebView，Linux 使用 WebKitGTK。

你将获得：

- **Racket 写逻辑** —— 完整的宏系统、contracts、模式匹配
- **Web 写界面** —— Tailwind、Svelte、React 或任何 Web 框架
- **真正的桌面外壳** —— 系统原生窗口 + 嵌入式 WebView
- **JSON API 桥接** —— 页面用普通 `fetch("/api/...")` 调用 Racket

Glaze 明确采用 **GUI-first** 设计。原生 WebView 运行时缺失或初始化失败时，应用会直接启动失败，并给出当前平台的安装/修复指引；**不会再偷偷退化成 Chrome、Edge 或 Safari 里的一个网页。**

### 横向对比

| | Glaze | Tauri | Electron | wails |
|---|---|---|---|---|
| 后端语言 | Racket | Rust | JS/Node | Go |
| 原生工具链 | **无需**（纯 FFI） | Rust + cargo | 无 | Go + WebView2 依赖 |
| 二进制体积 | 极小 | 小 | 100 MB+ | 小 |
| 前后端桥接 | HTTP JSON 路由（`fetch`） | `invoke()` IPC | Node API | 绑定层 |
| WebView 后端 | WebView2 / WKWebView / WebKitGTK | 系统 WebView | 自带 Chromium | WebView2/WKWebView |
| WebView 缺失时 | **明确失败 + 安装指引** | 前置依赖错误 | 不适用（自带） | 前置依赖错误 |
| Agent 友好的 UI 验证（title/url/截图） | **内置** | 需 WebDriver | 需 CDP | 有限 |

三个平台的 WebView 后端均通过真窗口 CI e2e（open、加载、截图、导航、关闭、on-close）。剩余诚实差距：IPC 仍是纯 JSON、没有类型层；Linux 需要桌面会话或 Xvfb。

## 平台支持状态

| 能力 | macOS | Windows | Linux |
|---|---|---|---|
| 本地应用 HTTP 服务 | ✅ | ✅ | ✅ |
| 系统托盘 | ✅ | ✅ | ✅（CI 验证） |
| JSON API 桥接 | ✅ | ✅ | ✅ |
| 原生 WebView 窗口 | ✅ 端到端验证 | ✅ CI e2e（WebView2） | ✅ CI e2e（Xvfb + WebKitGTK） |
| `webview-title` / `webview-url` | ✅ | ✅ | ✅ |
| `webview-capture!`（截图） | ✅ | ✅（PrintWindow + PowerShell 转 PNG） | ✅（gdk_pixbuf） |
| `#:devtools?` | ✅（inspectable，macOS 13+） | ✅（`OpenDevToolsWindow`） | ✅（WebKitGTK inspector） |

原生 WebView 是应用启动的必要条件。`run-app` / `open-window` **不会**在失败时打开系统浏览器。

## 环境要求

| 平台 | 运行时要求 |
|---|---|
| 全平台 | [Racket](https://racket-lang.org/) 7.0 或更高版本（包含 `raco`） |
| Windows | Microsoft Edge WebView2 Runtime（Evergreen）。Glaze 已自带 `WebView2Loader.dll`；若启动提示运行时不可用，请安装或修复 WebView2 Runtime。 |
| macOS | WKWebView 随 macOS 自带；需要在已登录的图形桌面会话中运行。 |
| Linux | GTK 3 + WebKitGTK（当前 Debian/Ubuntu 通常是 `libwebkit2gtk-4.1-0`）以及图形桌面会话/Xvfb。 |

如果原生后端初始化失败，Glaze 会保留底层错误，并紧接着给出对应平台的安装命令或官方下载地址。交互式桌面程序还会尝试弹出系统错误对话框显示同一份诊断信息——这对 Windows `raco exe --gui` 打包出的无控制台程序尤其重要。CI 会自动禁用错误弹框；也可以通过 `GLAZE_NO_STARTUP_DIALOG=1` 显式关闭。

Windows 示例：

```text
Windows requires Microsoft Edge WebView2 Runtime (Evergreen).
winget install --id Microsoft.EdgeWebView2Runtime -e
https://developer.microsoft.com/microsoft-edge/webview2/#download-section
```

Linux 示例：

```bash
# Debian / Ubuntu
sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0

# Fedora
sudo dnf install gtk3 webkit2gtk4.1

# Arch
sudo pacman -S gtk3 webkit2gtk-4.1
```

## 快速开始

### 1. 安装

```bash
raco pkg install --auto glaze
```

### 2. 创建新项目

```bash
raco glaze init myapp
cd myapp
```

### 3. 运行

```bash
racket main.rkt
# 或
raco glaze dev
```

会打开一个真正的原生桌面窗口，由本地 Racket 服务驱动。如果缺少 WebView2 / WebKitGTK 等依赖，启动会停止并告诉你需要安装什么，绝不会改成浏览器页面继续运行。

> 想直接从 GitHub 检出安装而不走包索引？
> ```bash
> git clone https://github.com/turinglambdaai/glaze.git
> cd glaze
> raco pkg install --auto --link "$PWD"
> ```

## CLI 命令

```bash
raco glaze init <name>   # 创建原生 Glaze 桌面项目
raco glaze dev           # 运行当前项目的原生桌面应用
raco glaze build         # 构建可分发包（exe + 内置资源）
raco glaze keygen        # 生成用于许可证签名的 RSA 密钥对
raco glaze license       # 签发 / 校验离线许可证文件
raco glaze help          # 显示帮助
```

Glaze **不提供浏览器模式的 `dev` / `serve` 命令**。开发和发布走同一条 Native WebView 路径，这样依赖缺失或原生后端故障会在开发阶段立即暴露，而不是被 browser fallback 隐藏。

### `build`

把 Glaze 项目打包为平台分发产物（`raco exe` + `raco distribute`），前端资源随可执行文件一起分发。Windows GUI 构建使用 `raco exe --gui`；macOS 产出标准 `.app` bundle。

```bash
raco glaze build --name myapp
raco glaze build --name myapp --version 1.2.0 --installer
```

选项：`--name`、`--version`、`--icon <.ico/.icns>`、`--entry <path>`（默认 `main.rkt`）、`--out <dir>`（默认 `dist`）、`--embed-dlls`（Windows：单文件 exe）、`--installer`。

> installer 步骤缺少 WiX / NSIS / create-dmg / appimagetool 等打包工具时，可以降级为 `.zip` / `.tar.gz` 并响亮告警。这里降级的是**分发格式**，不是应用 UI；应用启动本身没有浏览器 fallback。

### 代码签名与公证

```bash
# macOS
raco glaze build --name myapp \
  --sign "Developer ID Application: Acme Inc (TEAMID)" \
  --notarize acme-notary --installer

# Windows
raco glaze build --name myapp --sign 40HEXCHARS --installer
```

签名失败会中止构建；缺失签名工具链时会明确告警。

### 许可证（收费应用）

```bash
raco glaze keygen --out keys
raco glaze license sign --key keys/private.pem --product "MyApp" \
  --subject "customer@example.com" --expiry 2027-12-31 --out app.license
raco glaze license verify --pub keys/public.pem --product "MyApp" app.license
```

```racket
(require glaze/license)

(define r (validate-license "app.license" #:public-key "keys/public.pem" #:product "MyApp"))
(unless (hash-ref r 'valid)
  (error 'myapp "许可证无效：~a" (hash-ref r 'reason)))
```

## 项目结构

一个新的 Glaze 项目结构如下：

```
myapp/
├── main.rkt          # Racket 入口
└── public/
    └── index.html    # 前端页面
```

`raco glaze init` 现在生成的入口就是原生窗口应用。`run-app` 故意放在顶层，这样源码直接运行、`raco glaze dev` 和 `raco glaze build` 的打包 wrapper 都会启动同一套应用逻辑：

```racket
#lang racket/base

(require racket/runtime-path
         glaze)

(define-runtime-path public "public")

(run-app #:public-dir public
         #:title "myapp")
```

## API

### `run-app`

一键入口：自动挑空闲端口、启动服务器（静态 + JSON API）、打开原生 WebView 窗口、阻塞到窗口关闭。

```racket
(run-app #:public-dir "public"
         #:api (list (GET "api/ping" ...)))
;; 窗口关闭 -> server 停止 -> (values 'webview shutdown)
```

如果原生 WebView 启动失败，`run-app` 会先停止已经启动的本地 server，再把包含安装/修复指引的错误原样抛出。**不存在 `#:fallback-browser?` 参数。**

### `start-server` / `start-dev-server`

启动本地 HTTP 服务器：静态文件 + SPA 回退 + 可选 JSON API 路由。`start-dev-server` 只是底层 server API 的兼容别名，不代表另一套浏览器 UI 模式。

### `open-browser`

这是一个**低层外部链接工具函数**，例如打开产品文档或 OAuth 页面。`run-app` / `open-window` 不会把它当成 WebView 失败后的退路。

```racket
(open-browser "https://example.com/docs")
```

## JavaScript 桥接

嵌入式前端用普通 `fetch("/api/...")` 调 Racket。本地 HTTP 桥接也方便用 `curl` 等开发工具独立测试。

```racket
(require glaze)

(GET  "api/ping"            (lambda (req) (hasheq 'pong #t)))
(POST "api/items/:id/bump"  (lambda (req id) (hasheq 'id id 'bumped #t)))
```

`define-api-routes` 一处声明同时产生 Racket procedure、validated route 和 `/glaze/api.js` 中的 JS client entry。

### 后端 → 前端推送（SSE）

```racket
(define bus (make-event-bus))
(start-server ... #:events bus)
(bus-broadcast! bus 'count-changed (hasheq 'count 42))
```

SSE 与嵌入式 WebView 前端共享同一个本地 origin。

### 安全

- 仅服务 Host 为 `127.0.0.1` / `localhost` / `[::1]` 的请求；
- 参数问题返回 400 JSON，handler 异常返回 500 JSON；
- 可选 `#:api-token` 保护 API 路由与 SSE；
- 应用窗口通过一次性的 token bootstrap URL 获取 HttpOnly cookie。

## 系统集成

```racket
(require glaze/sys)
(clipboard-set! "hello")
(notify! "下载完成" "report.pdf 已就绪")
(open-path "/Users/me/report.pdf")
(reveal-path "/Users/me/report.pdf")
(unless (single-instance? "com.me.app") (exit 0))
```

窗口控制：`webview-set-title!`、`webview-set-size!`、`webview-set-fullscreen!`、`webview-focus!`。

## 系统托盘

系统托盘是**可选能力**。tray backend 缺失时可以退化为 inert stub；这和主 WebView 必须成功启动是两种不同的产品语义。

- Windows：`Shell_NotifyIconW`
- macOS：`NSStatusItem` / `NSMenu`
- Linux：`libayatana-appindicator` + GTK

## 示例

| 示例 | 内容 |
|---|---|
| [`examples/showcase/`](examples/showcase/) | 综合演示 —— 全部能力在一个原生窗口里 |
| [`examples/hello/`](examples/hello/) | 最小原生应用 |
| [`examples/counter/`](examples/counter/) | JS↔Racket 桥接 |
| [`examples/webview-demo.rkt`](examples/webview-demo.rkt) | 跨平台 Native WebView 生命周期 |
| [`examples/agent-verify.rkt`](examples/agent-verify.rkt) | 无人值守断言页面状态 + 截图 |
| [`examples/tray-demo.rkt`](examples/tray-demo.rkt) | 跨平台系统托盘 |

## Roadmap

- [x] **Phase 1** —— 本地 HTTP 服务 + 早期浏览器原型
- [x] **Phase 2** —— 前端资源打包、系统托盘、应用打包
- [x] **Phase 3** —— 原生 WebView（WebView2 / WKWebView / WebKitGTK），三平台 CI e2e
- [x] **GUI-first 契约** —— WebView 必须可用；失败给出可操作安装指引，不再 fallback 到浏览器

## License

MIT License。
