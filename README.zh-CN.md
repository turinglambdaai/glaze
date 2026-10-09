# Glaze

用 [Racket](https://racket-lang.org/) 做后端、Web 技术做前端，构建桌面应用。一个 Racket 版的 [Tauri](https://tauri.app/) —— 用 Racket 写业务逻辑，用 HTML/CSS/JS 构建界面，最终运行在真正的桌面窗口中。

**Human-first. Agent-native. Local by design. —— 为人而生，为 Agent 原生设计，本地优先。**

[![CI](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Release](https://img.shields.io/badge/release-0.10.0-C15F3C)](CHANGELOG.md)

[English](README.md) · **中文**

<p align="center"><img src="docs/showcase.png" alt="Glaze Showcase —— 全部能力一屏尽览" width="720"></p>

## 为什么选择 Glaze？

Racket 自带的 `racket/gui` 可以用，但很难做出现代化的产品级 UI。Glaze 采用不同的思路：Racket 在本机提供应用前端与 API，然后把 HTML/CSS/JS 渲染在**原生桌面窗口中的系统 WebView** 里：Windows 使用 WebView2，macOS 使用 WKWebView，Linux 使用 WebKitGTK。

你将获得：

- **Racket 写逻辑** —— 完整的宏系统、contracts、模式匹配
- **Web 写界面** —— Tailwind、Svelte、React 或任何 Web 框架
- **真正的桌面外壳** —— 系统原生窗口 + 嵌入式 WebView
- **JSON API 桥接** —— 页面用普通 `fetch("/api/...")` 调用 Racket
- **运行时权限能力** —— API 路由默认拒绝，并支持文件路径与命令参数范围
- **受限文件系统插件** —— 文本/二进制、目录、元数据、复制/移动/删除
- **受限 Shell 插件** —— 有界输出、超时、可管理的后台子进程
- **持久化 Store 插件** —— 原子 JSON、自动保存防抖与变更事件
- **系统插件** —— 受限剪贴板、通知、Opener 与操作系统信息
- **路径解析器** —— 应用目录、资源、便携覆盖与路径工具
- **受限 HTTP 客户端** —— 大小上限、超时与重定向逐跳鉴权
- **受限 SQLite 插件** —— 参数化 select/execute 与连接所有权隔离
- **全局快捷键** —— 系统级热键、加速键 scope 约束与 SSE 触发事件
- **结构化日志** —— 按 sink 分级、文件轮转、SSE 推送与有界历史
- **原生对话框** —— 受 capability 门禁的文件/目录选择、保存与消息框

Glaze 明确采用 **GUI-first** 设计。原生 WebView 运行时缺失或初始化失败时，应用会直接启动失败，并给出当前平台的安装/修复指引；**不会再偷偷退化成 Chrome、Edge 或 Safari 里的一个网页。**

### 横向对比

| | Glaze | Tauri | Electron | wails |
|---|---|---|---|---|
| 后端语言 | Racket | Rust | JS/Node | Go |
| 原生工具链 | **无需**（纯 FFI） | Rust + cargo | 无 | Go + WebView2 依赖 |
| 二进制体积 | 极小 | 小 | 100 MB+ | 小 |
| 前后端桥接 | HTTP JSON 路由（`fetch`） | `invoke()` IPC | Node API | 绑定层 |
| 运行时权限 | 路由权限 + 资源范围 | Capabilities + permissions | 应用自行实现 | 应用自行实现 |
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
| Capability 限制 API 路由 | ✅ | ✅ | ✅ |
| 路径 scope 文件系统插件 | ✅ | ✅ | ✅ |
| 命令 scope Shell/子进程插件 | ✅ | ✅ | ✅ |
| 持久化键值 Store 插件 | ✅ | ✅ | ✅ |
| Capability 限制系统插件 | ✅ | ✅ | ✅ |
| 应用/用户/资源路径解析 | ✅ | ✅ | ✅ |
| Capability 限制 HTTP 客户端 | ✅ | ✅ | ✅ |
| Capability 限制 SQLite 插件 | ✅ | ✅ | ✅ |
| Capability 限制全局快捷键 | ✅ | ✅ | ✅ X11/XWayland |
| Capability 限制结构化日志 | ✅ | ✅ | ✅ |
| Capability 限制原生对话框 | ✅ | ✅ | ✅ zenity/kdialog |
| 原生 WebView 窗口 | ✅ 端到端验证 | ✅ CI e2e（WebView2） | ✅ CI e2e（Xvfb + WebKitGTK） |
| `webview-title` / `webview-url` | ✅ | ✅ | ✅ |
| `webview-capture!`（截图） | ✅ | ✅（PrintWindow + PowerShell 转 PNG） | ✅（gdk_pixbuf） |
| `#:devtools?` | ✅（inspectable，macOS 13+） | ✅（`OpenDevToolsWindow`） | ✅（WebKitGTK inspector） |
| 窗口几何信息与状态持久化 | ✅ | ✅ | ✅ |

原生 WebView 是应用启动的必要条件。`run-app` / `open-window` **不会**在失败时打开系统浏览器。

## 环境要求

| 平台 | 运行时要求 |
|---|---|
| 全平台 | [Racket](https://racket-lang.org/) 9.0 或更高版本，CS 运行时（包含 `raco`） |
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
raco glaze inspect --json # 读取项目、编辑点与验证契约
raco glaze doctor --json  # 检查包与原生 WebView 就绪状态
raco glaze dev           # 运行当前项目的原生桌面应用
raco glaze verify        # 断言 title/URL 并捕获原生窗口截图
raco glaze build         # 构建可分发包（exe + 内置资源）
raco glaze keygen        # 生成用于许可证签名的 RSA 密钥对
raco glaze license       # 签发 / 校验离线许可证文件
raco glaze help          # 显示帮助
```

`init` 同时生成 `AGENTS.md` 与可直接运行的 `verify.rkt`：Agent 能先读取机器可读的项目地图与诊断结果，再以真实原生窗口的 title、URL、PNG 截图和退出码验收修改。详见 [Agent-native 工作流](docs/agent-native.md)。

Glaze **不提供浏览器模式的 `dev` / `serve` 命令**。开发和发布走同一条 Native WebView 路径，这样依赖缺失或原生后端故障会在开发阶段立即暴露，而不是被 browser fallback 隐藏。

### `build`

把 Glaze 项目打包为平台分发产物（`raco exe` + `raco distribute`），前端资源随可执行文件一起分发。Windows GUI 构建使用 `raco exe --gui`；macOS 产出标准 `.app` bundle。

```bash
raco glaze build --name myapp
raco glaze build --name myapp --version 1.2.0 \
  --publisher "Acme Inc" --identifier com.acme.myapp --installer
```

选项：`--name`、`--version`、`--publisher`、`--identifier`、`--icon <.ico/.icns>`、`--entry <path>`（默认 `main.rkt`）、`--out <dir>`（默认 `dist`）、`--embed-dlls`（Windows：单文件 exe）、`--installer`。不同版本必须保持 `--identifier` 不变；Glaze 会用它派生稳定的 WiX `UpgradeCode` 和 NSIS 卸载注册表标识。

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
         #:api (list (GET "api/ping" ...))
         #:capability main-capability)
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

### 运行时 capability 与资源范围

Capability 是显式启用、默认拒绝的安全边界。一旦向 `run-app` 传入
`#:capability`，每条 API 路由都必须声明 `#:permission`；未声明或未授权的
路由直接返回 403，handler 不会执行。`run-app` 会自动生成 API token 并通过
一次性 bootstrap URL 绑定到 WebView。

```racket
(define main-capability
  (make-capability
   "main"
   (list 'settings:read
         (path-permission 'files:read
                          #:allow (list app-data-dir)
                          #:deny (list secrets-dir))
         (command-permission 'tools:run
                             #:allow '("git")
                             #:arguments (lambda (args)
                                           (equal? args '("--version")))))))

(define routes
  (list (GET "api/settings" settings-handler
             #:permission 'settings:read)
        (POST "api/files/read" read-handler
              #:permission 'files:read
              #:resource (lambda (req)
                           (hash-ref (request-json-body req) 'path)))))

(run-app #:public-dir "public" #:api routes #:capability main-capability)
```

命令范围由路由的 `#:resource` 返回 `command-resource`；deny 路径或命令优先于
allow。应用需要 SSE 时，在 capability 中授予 `'glaze:events`。

### 受路径 scope 约束的文件系统插件

`make-filesystem-routes` 提供可直接从前端调用的 UTF-8 文本、base64 二进制、
目录读取/创建、元数据、存在性、文件复制、移动和删除 API。应用只需组合路由并
授予窗口确实需要的目录：

```racket
(define authority
  (make-capability
   "main"
   (list (path-permission 'fs:read #:allow (list documents-dir))
         (path-permission 'fs:write #:allow (list cache-dir)))))

(run-app #:public-dir "public"
         #:api (make-filesystem-routes)
         #:capability authority)
```

生成的客户端包含 `glaze.api.fsReadText(body)`、`fsWriteFile(body)`、
`fsReadDir(body)`、`fsMove(body)` 等函数。复制/移动会同时检查源和目标；写入
使用同目录临时文件后原子替换。

### 受命令 scope 约束的 Shell/子进程插件

`make-shell-routes` 向前端提供不经过系统 shell 的命令执行。进程创建前，程序名
和参数会先由 `command-permission` 检查；同步调用有超时，输出大小有上限，后台
进程句柄还会绑定到创建它的 capability：

```racket
(define authority
  (make-capability
   "main"
   (list (command-permission
          'shell:execute
          #:allow '("git")
          #:arguments (lambda (args) (member args '(("--version") ("status")))))
         'shell:manage)))

(run-app #:public-dir "public"
         #:api (make-shell-routes)
         #:capability authority)
```

生成的客户端包含 `glaze.api.shellOutput(body)`，以及 `shellSpawn`、
`shellStatus`、`shellWrite`、`shellCloseStdin`、`shellKill`。程序直接执行，
不会经由 `cmd.exe` 或 `/bin/sh`，因此没有 shell 插值或展开。前端传入的
`cwd` 根目录和环境变量名默认拒绝，必须通过 `#:cwd-roots` 和
`#:allow-environment` 显式开放；每个 stdout/stderr 默认最多保留 1 MiB，
句柄注册表也有数量上限。

### 持久化 Store 插件

`make-store-routes` 提供与 Tauri Store 对齐的生命周期：load/close、
get/set/has/delete、clear/reset、keys/values/entries/length、reload 和显式
save。Store 使用 JSON，写入采用原子替换，自动保存默认以 100 ms 防抖（传 `#f`
可禁用）：

```racket
(define bus (make-event-bus))
(define authority
  (make-capability
   "main"
   (list (path-permission 'store:read #:allow (list app-data-dir))
         (path-permission 'store:write #:allow (list app-data-dir))
         'glaze:events)))

(run-app #:public-dir "public"
         #:api (make-store-routes #:root app-data-dir #:events bus)
         #:events bus
         #:capability authority)
```

配置 `#:root` 后，前端路径必须是相对路径；即使 capability 允许，也不能穿越
该根目录。生成的函数包括 `storeLoad`、`storeGet`、`storeSet`、
`storeEntries`、`storeReset`、`storeSave`、`storeReload`、`storeClose`。
传入 `#:events` 后，变更会通过现有 SSE 总线发布为 `store:change`。

### 应用路径

`make-path-resolver` 提供 Tauri 风格的 config/data/local-data/cache/log
目录，并按应用标识符隔离；同时提供用户目录、临时目录、可执行文件目录和资源
目录，以及字体和模板目录；Linux 会读取 `user-dirs.dirs`。既支持单一便携
根目录，也支持逐目录覆盖：

```racket
(define paths
  (make-path-resolver
   "com.example.app"
   #:resource-root bundled-assets
   #:app-directories-override (hasheq 'data "$DOCUMENT/My App"
                                       'cache "$CACHE/my-app")))

(define settings-root (app-data-dir paths))
(define icon-path (resolve-resource paths "icons/app.png"))
```

`make-path-routes` 将目录查询和 `join`、`resolve`、`normalize`、
`basename`、`dirname`、`extname`、`is-absolute` 分别按权限开放给生成的前端
客户端。资源解析会拒绝绝对路径、`..` 穿越和已有符号链接逃逸。覆盖变量支持
`$AUDIO`、`$CACHE`、`$CONFIG`、`$DATA`、`$LOCALDATA`、`$DESKTOP`、
`$DOCUMENT`、`$DOWNLOAD`、`$HOME`、`$PICTURE`、`$PUBLIC`、`$TEMP`、
`$VIDEO`。

### 受限 HTTP 客户端

`http-request` 为 Racket 代码提供有界的 HTTP/HTTPS 访问；
`make-http-routes` 则向嵌入式前端加入 `glaze.api.httpRequest(body)`，并要求
URL scope 的 `http:request` 权限：

```racket
(define authority
  (make-capability
   "main"
   (list (url-permission
          'http:request
          #:allow (list #px"^https://api\\.example\\.com/v1/")))))

(run-app ...
         #:api (make-http-routes #:timeout 15
                                 #:max-response-bytes (* 2 1024 1024))
         #:capability authority)
```

请求正文可传文本或 base64，响应包含状态码、最终 URL、headers、`bodyText`
和 `bodyBase64`。请求/响应大小、总超时和重定向次数都有上限；每次重定向都会
在建立连接前重新鉴权，跨 origin 时会移除 `Authorization` 与 `Cookie`。
前端不能覆盖 `Host`、`Content-Length` 等连接管理 header。

### 受限 SQLite

`open-sqlite-database`、`sql-select`、`sql-execute!`、`sql-close!` 是直接
Racket API；`make-sql-routes` 则向生成的客户端加入 `sqlLoad`、`sqlSelect`、
`sqlExecute` 与 `sqlClose`：

```racket
(define database-root (app-data-dir paths))
(define authority
  (make-capability
   "main"
   (list (path-permission 'sql:load #:allow (list database-root))
         (path-permission 'sql:select #:allow (list database-root))
         (path-permission 'sql:execute #:allow (list database-root))
         (path-permission 'sql:close #:allow (list database-root)))))

(run-app ...
         #:api (make-sql-routes #:root database-root)
         #:capability authority)
```

前端只能使用配置根目录下的相对路径，`..` 和已有符号链接都不能越界。连接按
capability 与数据库路径隔离缓存，并限制总连接数。查询使用位置参数；
`sqlSelect` 只接受 `SELECT`/`WITH`，且限制返回行数。二进制值用
`{ "blobBase64": "..." }` 往返，SQL NULL 对应 JSON `null`。

### 全局快捷键

`hotkey-register!`/`hotkey-unregister!`/`hotkey-registered?` 直接驱动原生
后端（Win32 `RegisterHotKey`、Carbon `RegisterEventHotKey`、X11
`XGrabKey`）；`make-global-shortcut-routes` 提供 Tauri 风格的前端 API，
`accelerator-permission` 约束页面可以抢注哪些组合键：

```racket
(define authority
  (make-capability
   "main"
   (list (accelerator-permission 'global-shortcut:register
                                  #:allow '("CmdOrCtrl+Shift+D"))
         (accelerator-permission 'global-shortcut:unregister
                                  #:allow '("CmdOrCtrl+Shift+D")))))

(run-app ...
         #:api (make-global-shortcut-routes #:events bus)
         #:events bus
         #:capability authority)
```

加速键采用 Tauri 拼写（`CmdOrCtrl+Shift+D`、`KeyD`、`Digit7`、F1–F24、
小键盘）；scope 在声明与请求两侧都按规范化形式匹配，大小写与别名的变体
不会扩大授权。触发以 `global-shortcut` SSE 事件送达页面，携带规范化加速键：
`glaze.on('global-shortcut', ({accelerator}) => ...)`。Linux 后端经 X11 抓键，
XWayland 会话可用；没有 X 的 Wayland 会话注册会返回失败而不是抛异常。

### 结构化日志

一个 logger 把记录扇出到多个 sink，每个 sink 有自己的最低级别：

```racket
(define logger
  (make-glaze-logger #:min-level 'info
                     #:file-root (app-log-dir paths)
                     #:events bus))

(log-info logger "server started" #:data (hasheq 'port 8080))
(log-error logger "handler failed" #:data (hasheq 'message "..."))
```

默认 stderr sink 常驻；`#:file-root` 增加轮转文件 sink（轮转而非截断，
写入中途崩溃不会毁掉更早的日志）；`#:events` 把每条记录以 `log` SSE 事件
推给页面；自定义 sink（过程或 `log-sink` 值）经 `#:sinks` 接入。有界内存
历史支撑 `make-log-routes`，生成的 `logWrite` 与 `logHistory` 函数受
`log:write` 与 `log:read` 门禁。前端写入记录自带来源与 capability ID——
页面无法伪造后端日志行——并与后端记录一样遵守 logger 的最低级别。

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
- 可选 `#:capability` 启用默认拒绝的路由权限，并可限制文件根目录、命令与参数；
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

同一组桌面能力也可通过 `make-system-routes` 安全地开放给嵌入式前端。
所有操作仍然默认拒绝：剪贴板读写分别授权，通知需要
`notification:send`，打开/定位文件使用路径 scope，URL 使用精确字符串或
正则 scope，hostname 也与普通 OS 信息分开授权：

```racket
(define authority
  (make-capability
   "main"
   (list 'clipboard:write
         'notification:send
         'os:read
         (path-permission 'opener:open-path #:allow (list documents-dir))
         (url-permission 'opener:open-url
                         #:allow (list #px"^https://docs\\.example\\.com/")))))

(run-app ...
         #:api (make-system-routes)
         #:capability authority)
```

获得对应权限后，生成的客户端提供 `systemClipboardRead`、
`systemClipboardWrite`、`systemNotificationSend`、`systemOpenerOpenPath`、
`systemOpenerRevealPath`、`systemOpenerOpenUrl`、`systemOsInfo` 与
`systemOsHostname`。

窗口控制：`webview-set-title!`、`webview-set-size!`、`webview-set-fullscreen!`、`webview-focus!`。`webview-window-state` / `webview-set-window-state!` 可跨三平台读写窗口外框位置、尺寸与最大化状态。使用 `run-app #:app-id "com.example.app" #:window-state #t` 即可在关闭时保存、下次启动时恢复；恢复值会限制到当前虚拟桌面内，拔掉外接显示器后也不会把窗口留在屏幕外。

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
