# AGENTS.md

本文件给维护 Glaze 的 AI agent 和开发者使用。目标是说明项目当前真正的架构契约、容易踩坑的地方，以及改动后必须怎么验证。

## 项目定位

Glaze 是一个 **Tauri-like framework for Racket**：

- Racket 写业务逻辑与本地 API；
- HTML/CSS/JS 写现代 UI；
- UI 运行在真正的原生桌面窗口内；
- Windows 使用 WebView2，macOS 使用 WKWebView，Linux 使用 WebKitGTK；
- 核心平台层尽量使用纯 Racket FFI，不要求用户安装 C/C++ 编译器。

### 最重要的产品契约：GUI-first

**Glaze 是桌面 GUI 框架，不是“本地 server + 浏览器”的框架。**

应用入口 `run-app`、`open-window`、`open-webview` 必须走 Native WebView：

```text
Racket local server
        ↓
HTML / CSS / JS
        ↓
Native OS window
        ↓
WebView2 / WKWebView / WebKitGTK
```

以下行为禁止重新引入：

- WebView 启动失败后自动打开 Chrome / Edge / Safari；
- `#:fallback-browser?`；
- `raco glaze dev` 退化成 browser-only server；
- 用“应用还能在浏览器里打开”掩盖缺失依赖或 native backend bug。

Native WebView 失败时的正确行为：

1. 保留底层真实异常；
2. 明确告诉用户缺少或可能损坏的运行时；
3. 给安装命令 / 官方下载入口；
4. GUI 打包程序尽量弹 OS 级错误框；
5. 终止启动；
6. 如果 `run-app` 已启动本地 server，必须先关闭 server 再抛错。

`open-browser` 仍可保留为显式工具函数，用于打开帮助文档、OAuth、支持页面等外部链接，但绝不能作为应用 UI fallback。

## WebView 缺失反馈

公开层在 `glaze/webview/main.rkt`：

- `webview-install-guidance`：平台依赖安装说明；
- `webview-diagnostic`：底层异常 + 安装说明；
- `webview-last-error`：最近一次 probe / startup 错误；
- `glaze/webview/startup-feedback.rkt`：在交互式桌面环境尝试显示系统错误对话框；
- CI / GitHub Actions 自动关闭错误对话框，避免无人值守任务阻塞；
- `GLAZE_NO_STARTUP_DIALOG=1` 可显式禁用错误对话框。

Windows 依赖：Microsoft Edge WebView2 Runtime (Evergreen)。Glaze 自己带 `WebView2Loader.dll`，不要把 Loader DLL 和 Runtime 混为一谈。

Linux 依赖：GTK 3 + WebKitGTK + 图形桌面会话（CI 使用 Xvfb）。

macOS 的 WKWebView 随系统提供；失败时重点保留初始化错误和运行环境信息。

## 平台 WebView 状态

| 平台 | 后端 | 状态 |
|---|---|---|
| Windows | Win32 + WebView2 COM FFI | CI 真窗口 e2e |
| macOS | NSWindow + WKWebView objc FFI | 本机 + CI 真窗口 e2e |
| Linux | GtkWindow + WebKitGTK FFI | CI Xvfb 真窗口 e2e |

三平台 e2e 应至少覆盖：open、页面加载、title/url、截图、navigate、close、on-close。

## Windows WebView2 关键历史坑

`glaze/webview/webview-windows.rkt` 的 COM vtable 索引必须以官方 WebView2 SDK header 为准，不能靠相邻接口猜。

曾经最难查的问题不是 COM apartment，而是把 `ICoreWebView2Controller::get_CoreWebView2` 的 vtable slot 写错。错误 slot 会写入 BOOL，再被当成接口指针使用，表现得像随机 COM 生命周期崩溃。

现有关键约定：

- COM vtable 函数指针用 `_fpointer` 读取；
- out 参数先检查 HRESULT；
- controller 与 CoreWebView2 接口在 callback 内 AddRef 并保存在 handle；
- 初始化链在同一个 STA / Racket OS thread 上由消息泵推进；
- 不要未经 SDK header 核对就新增 vtable index。

## macOS WebView 关键点

- AppKit 必须显式加载；纯 `racket` 进程默认不保证已加载 AppKit；
- UI 事件通过非阻塞 run-loop pump 服务，不能用会长期阻塞 Racket OS thread 的调用；
- 多窗口共享 run-loop pump，关闭一个窗口不能让其他窗口失去事件服务；
- 打包 `.app` 后和裸 `racket` 进程的生命周期/激活行为并不完全一致，改 backend 后两种路径都要验证。

## Linux WebView 关键点

- WebKitGTK + GTK 3；
- `ffi-lib` 在部分 Debian/Ubuntu multiarch 环境无法靠 soname 自动找到库，所以 backend 有常见绝对路径兜底；
- 不要调用阻塞式 `gtk_main`；用 `g_main_context_iteration(..., FALSE)` 做非阻塞 pump；
- CI 使用 Xvfb；“库存在”与“有图形会话”是两个不同条件。

## 后端契约

每个 WebView backend 导出同一组过程：

```text
open-webview
supported?
close
navigate
title
url
capture!
set-title!
set-size!
set-fullscreen!
focus!
set-menu!
closed?
```

公开层再包装成 `webview-*` API。

约定：

- backend 的 `supported?` 是非抛错能力 probe；
- backend 的 `open-webview` 无法启动时可以抛错；
- 公开 `open-window` / `open-webview` **成功返回 `webview?`，失败直接抛带指引的错误**；
- 验证 API 暂时拿不到值时返回 `#f`；
- `capture!` 返回 PNG path 或 `#f`；
- 不允许重新加入 browser fallback。

## `run-app` 契约

`glaze/app.rkt` 是默认应用入口：

1. 选择端口；
2. 启动本地 server；
3. 创建 Native WebView；
4. `#:on-ready` 得到 `webview?` + URL；
5. 阻塞直到窗口关闭；
6. 停 server；
7. 返回 `(values 'webview shutdown)`。

如果第 3 步失败，必须先 shutdown server，再把 WebView startup error 原样抛出去。

`#:api-token`、`#:events`、`#:on-error`、update check 等逻辑不能改变上述生命周期。

## CLI 契约

当前 CLI：

```text
raco glaze init <name>
raco glaze dev
raco glaze build
raco glaze keygen
raco glaze license
raco glaze help
```

`init` 生成的 `main.rkt` 必须直接使用 `run-app`。

`dev` 必须运行项目真实 `main.rkt`，这样 routes、events、window options、token 等与生产行为一致。

**不要新增 browser-only `serve` 作为标准应用工作流。** 如果开发者需要测 HTTP endpoint，可直接使用底层 `start-server` / curl；这不是另一套 UI runtime。

## 项目结构

```text
glaze/
├── info.rkt
├── glaze/
│   ├── app.rkt
│   ├── server.rkt
│   ├── api.rkt
│   ├── api-macros.rkt
│   ├── events.rkt
│   ├── browser.rkt
│   ├── build.rkt
│   ├── assets.rkt
│   ├── update.rkt
│   ├── license.rkt
│   ├── dialogs.rkt
│   ├── deeplink.rkt
│   ├── autolaunch.rkt
│   ├── sys/
│   ├── tray/
│   └── webview/
│       ├── main.rkt
│       ├── startup-feedback.rkt
│       ├── webview-windows.rkt
│       ├── webview-macos.rkt
│       ├── webview-linux.rkt
│       └── webview-stub.rkt
├── glaze-cli/
├── glaze-doc/
├── glaze-test/
├── examples/
└── scripts/
```

仓库根是一个 `collection 'multi` 的 Racket 包。集合级 `scribblings` / `raco-commands` 要放在相应 collection 的 `info.rkt`，不要只放根 `info.rkt`。

## 快速开发命令

```bash
raco pkg install --auto --no-docs --link "$PWD"
raco pkg update --link "$PWD"
raco make glaze/main.rkt glaze-cli/cli.rkt
raco test glaze-test/
racket examples/hello/main.rkt
racket examples/showcase/main.rkt
racket examples/webview-demo.rkt
```

改动 WebView / tray / platform FFI 后，只跑 unit test 不够，必须看三平台 CI e2e。

## GUI-first 回归测试

`glaze-test/gui-first-test.rkt` 应长期保留以下防回归检查：

- `run-app` 不接受 `#:fallback-browser?`；
- `open-window` 不接受 `#:fallback-browser?`；
- `open-webview` 不接受 `#:fallback-browser?`；
- platform install guidance 非空；
- Windows guidance 提到 WebView2 Runtime 与官方入口；
- Linux guidance 提到 WebKitGTK；
- macOS guidance 提到 WKWebView。

如果未来有人为了“容错”想恢复浏览器 fallback，先重新讨论产品定位，而不是直接改代码。

## JS ↔ Racket 桥接

前端 `fetch("/api/...")` 调本地 Racket API。`define-api-routes` 一处声明同时产生：

1. Racket procedure；
2. validated route；
3. `/glaze/api.js` 中的 JS client entry。

重要：Racket jsexpr 的 JSON object key 是 symbol，例如 `(hash-ref body 'delta)`。

SSE 事件流使用同一个 origin；这套 HTTP 机制服务的是**嵌入式 WebView 前端**。它也方便 curl/测试工具验证，但不要因此重新定义为浏览器应用模型。

## 安全加固

- server 只绑定 loopback；
- Host header 仅允许 `127.0.0.1` / `localhost` / `[::1]`；
- API handler 参数错误 -> 400 JSON；handler 异常 -> 500 JSON；
- `#:api-token` 保护 API + SSE；静态资源与 bootstrap 不直接泄露 token；
- `run-app` 的一次性 `?glaze-token=` URL 换 HttpOnly cookie；
- 程序化客户端用 `X-Glaze-Token`；
- 同用户本地进程仍可能读进程内存，因此这不是强隔离边界。

## 系统托盘

tray 是**可选能力**，语义与 WebView 不同：

- native tray backend 不可用时可以降级到 inert stub；
- 不能因为 tray 允许 stub，就推导出主 WebView 也应允许 fallback；
- Windows 用 Shell_NotifyIconW；macOS 用 NSStatusItem/NSMenu；Linux 用 AppIndicator/GTK。

菜单 spec 复用 `tray-protocol`。

已踩过的菜单坑：

- 不要在整个重建菜单过程中一直持有 menu semaphore，否则内部 tag 分配可能自锁；
- 注册和派发必须使用同一张 action 表；
- macOS accelerator 真正工作，Windows/Linux 当前主要是展示。

## 文件对话框

- macOS：NSOpenPanel / NSSavePanel；
- Windows：comdlg32 wide-char API；
- Linux：zenity / kdialog；
- `#f` 表示用户取消；backend 缺失与“用户取消”不能混为一谈。

## 开机自启 / Deep Link

- macOS autolaunch 使用 SMAppService（13+，打包 `.app`）；
- Windows autolaunch 使用 HKCU Run；
- Linux 使用 `~/.config/autostart`；
- macOS URL scheme 在构建时写 Info.plist；
- Windows 注册 HKCU protocol；
- Linux 写 desktop entry + xdg-mime。

## 打包与签名

`glaze/build.rkt` 包装 `raco exe` + `raco distribute`。

Windows GUI 构建使用 `raco exe --gui`，因此用户可能看不到 stderr；这是 startup error dialog 必须存在的重要原因。

### macOS

- build-app 自己组装标准 `.app`；
- nested framework/dylib 先签，bundle 后签；
- 不要用一把 `--deep` 代替正确签名顺序；
- ad-hoc 身份 `-` 下不要启用 hardened runtime 的 library validation；
- notarization 使用 `notarytool` + staple。

### Windows

- signtool 支持 SHA-1 thumbprint 或 subject；
- 时间戳默认 RFC-3161；
- WebView2Loader.dll 随 Glaze 分发，但 Edge WebView2 Runtime 是系统运行时依赖。

### Installer fallback

installer toolchain 缺失时降级 zip/tar.gz 并响亮告警是允许的，因为那只是**分发格式**降级；不要把这种语义复制到应用 UI runtime。

## License / Update

- license：RSA-2048/SHA-256，系统 `openssl` CLI；
- `machine-id` 返回稳定摘要，不直接暴露原始系统 ID；
- `validate-license` 的 reason tag 是稳定接口，修改前先改测试；
- update manifest 可带 `sha256`；
- `verify-file-sha256` 返回 `#f` 同时可能代表“不匹配”或“无法校验”，绝不能把 `#f` 当验证成功。

## 提交前检查

至少完成：

```bash
raco make glaze/main.rkt glaze-cli/cli.rkt
raco test glaze-test/
```

涉及 WebView / FFI：确认 GitHub Actions 的 Windows、macOS、Ubuntu WebView e2e 全绿。

涉及 CLI scaffold/build：确认三平台 package job 里 `raco glaze init sampleapp` + build 全绿。

涉及文档 API 签名：确认 Scribble 可以编译。

## 不要破坏的契约

- Glaze 主应用 = Native WebView GUI；
- Native WebView 失败 = 明确失败 + actionable guidance；
- 不存在浏览器 fallback；
- `run-app` 失败不能遗留 server；
- backend 公开命名与四平台导出一致；
- `webview-title/url/capture!` 的 agent 验证能力保留；
- tray / sys 的“可选能力降级”和主 WebView 的“必须成功”要明确区分；
- 打包、签名失败不能假装成功；
- 文档、示例、CLI scaffold 与真实运行行为必须保持一致。
