# Glaze

用 [Racket](https://racket-lang.org/) 做后端、Web 技术做前端，构建桌面应用。一个 Racket 版的 [Tauri](https://tauri.app/) —— 用 Racket 写业务逻辑，用 HTML/CSS/JS 构建界面，打包为桌面应用。

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) · **中文**

## 为什么选择 Glaze？

Racket 自带的 `racket/gui` 可以用，但很难做出现代化的产品级 UI。Glaze 采用了不同的思路：从 Racket 启动一个本地 Web 服务，然后在系统浏览器（Phase 1）或嵌入式 WebView（Phase 3）中展示。

你将获得：

- **Racket 处理逻辑** — 完整的宏系统、契约、模式匹配
- **Web 构建界面** — Tailwind、Svelte、React 或任意 Web 框架
- **JSON API 桥接** — Racket 宏自动生成 API 端点

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
├── glaze-lib/        # 核心库（服务器、API、浏览器启动、资源管理）
├── glaze-cli/        # CLI 工具（raco glaze init / dev）
├── glaze-doc/        # 文档（Scribble）
├── glaze-test/       # 测试
└── info.rkt          # 多包根配置
```

## API

### `start-dev-server`

启动本地 HTTP 服务器，从指定目录提供静态文件。

```racket
(start-dev-server #:port 8080 #:public-dir "public")
;; 返回 (values port shutdown-proc)
```

### `stop-server`

停止开发服务器。

```racket
(stop-server shutdown-proc)
```

### `open-browser`

在系统默认浏览器中打开 URL（跨平台：Windows、macOS、Linux）。

```racket
(open-browser "http://127.0.0.1:8080")
```

### `define-api`

用于定义 JSON API 端点的宏。

```racket
(define-api (my-handler request)
  (json-response (hasheq 'status "ok")))
```

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

## 路线图

- [x] **Phase 1** — 本地 HTTP 服务器 + 系统浏览器
- [x] **Phase 2** — 前端资源打包、系统托盘、应用打包
- [ ] **Phase 3** — 原生 WebView 嵌入（WebView2 / WKWebView / WebKitGTK）— *进行中*

> **Phase 3 状态：** `glaze/webview` 模块（`open-window` / `open-webview`）正在开发中。Windows 上
> WebView2 的异步初始化链（environment → controller → CoreWebView2）已通过纯 Racket COM FFI 验证跑通，
> 但完成 `Navigate` 还卡在一个 COM apartment/对象生命周期问题上；在此之前 Windows 保持稳定的系统
> 浏览器体验。macOS（WKWebView）和 Linux（WebKitGTK）后端已搭建并由 CI 验证。原生后端不可用时，
> 调用方自动回退到 `open-browser`。

## 许可证

基于 [MIT 许可证](LICENSE) 授权。
