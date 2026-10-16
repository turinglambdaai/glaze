# AGENTS.md

本文件给维护 Glaze 的 AI agent 和开发者使用。目标是说明项目当前真正的架构契约、容易踩坑的地方，以及改动后必须怎么验证。

## 开始任何架构或路线图工作之前

先读以下四个文件，不要只依赖聊天历史：

1. `docs/README.md`：文档所有权地图，避免创建平行真相源；
2. `docs/architecture.md`：当前已经成立的架构和依赖方向；
3. `docs/1.0-plan.md`：当前阶段、退出条件、证据和下一项实现 handoff。
4. `docs/agent-handoff.md`：单 slice 的文件所有权、验证阶梯与停止条件。

仓库状态是 agent-to-agent handoff。一次只实现 `docs/1.0-plan.md` 中一个有边界的 slice，完成后更新证据和 “Next implementation handoff”。公共 API 变更还必须同步 `glaze-test/public-api-test.rkt`、`docs/api-stability.md` 和 `CHANGELOG.md`；不能通过修改快照来掩盖意外扩张。

## 家族协作契约

五仓库依赖图、职责路由、发布顺序与信任边界的权威说明在 Keel 的
[`docs/family-architecture.md`](https://github.com/turinglambdaai/keel/blob/main/docs/family-architecture.md)。
Glaze 的当前实现队列仍只由 `docs/1.0-plan.md` 管理，不把具体 milestone
复制到家族文档。

Glaze 与 Rivet 共享传输中立的契约包 `keel`。家族包只经 catalog 发布包消费，禁止 vendor 或手抄源码；每个家族依赖声明 `#:version` 下限 = 本仓库测试套件实际覆盖的最低版本，抬下限与声明它的 CHANGELOG 条目在同一次改动落地。每周的 *Family compatibility* workflow（`.github/workflows/family-compat.yml`）把家族包升到最新并跑全量测试；红了就地适配或修上游，先把 `main` 修绿再做其他事。

## 项目定位

Glaze 是一个 **Tauri-like framework for Racket**：

- Racket 写业务逻辑与本地 API；
- HTML/CSS/JS 写现代 UI；
- UI 运行在真正的原生桌面窗口内；
- Windows 使用 WebView2，macOS 使用 WKWebView，Linux 使用 WebKitGTK；
- 核心平台层尽量使用纯 Racket FFI，不要求用户安装 C/C++ 编译器。

### 商业权益边界

Glaze 不拥有 entitlement、trial、activation、seat、subscription、payment、checkout 或 account。签名权益语义归 [Permit](https://github.com/turinglambdaai/permit)，可选在线商业编排归 [Commerce](https://github.com/turinglambdaai/commerce)；二者都由产品组合，永远不是 Glaze 的依赖（`Glaze -X-> Permit/Commerce`）。Glaze 更新制品签名、OS 代码签名、Permit 凭证签名与 Commerce secrets 属于不同信任域，必须分钥分轮换流程。权威本地权益契约在 Permit 的 [`docs/framework-integration.md`](https://github.com/turinglambdaai/permit/blob/main/docs/framework-integration.md)，此处只保留摘要，不要复述。产品可以用 Glaze 的通用 secure-storage 保存 Permit 凭证、本地 trial 状态或 `installation_id`，数据语义仍归产品与 Permit；也不要重新加入 `glaze/license`、授权 CLI、支付 route 或框架内置商业策略。

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

## 原生传输（native transport）

`run-app #:transport 'native`（macOS 先行，`glaze/native-transport.rkt`）：
页面从受控 `glaze://app/` scheme 加载（WKURLSchemeHandler），所有桥调用走
`glz1` message handler（WKScriptMessageHandler），页面不接触任何 TCP 端口。
HTTP/SSE 降级为开发适配器。关键契约：

- scheme 响应的 `NSURLResponse` **必须用裸媒体类型**（`text/html`）+ 独立的
  `textEncodingName`；`MIMEType:` 里带 `; charset=utf-8` 会让 WebKit 提交导航
  但静默丢弃响应字节（URL 提交、页面空白、无报错——最难查的一种失败）。
- 响应不在 `startURLSchemeTask:` 投递上下文里同步发出，而是排进
  `scheme-response-queue` 由共享 pump 线程在后续 runloop 迭代发出。
- native 模式没有 token（message handler 即信任边界）；capability 仍然生效。
- 事件总线以 `(seq, name, data)` 序号批次经 `window.__glz1Events` 投递。
- `native-transport-shutdown!` 幂等（宿主关闭路径与 run-app teardown 都会调；
  control channel 容量 1，重复 put 无消费者时会永久阻塞——别去掉幂等守卫）。

`glaze-test/native-transport-test.rkt` 覆盖传输核心（无窗口，全平台 CI）；
`glaze-test/webview-test.rkt` 的 macOS 段覆盖 scheme + 消息处理器 + run-app
native + per-window capability 真窗口 e2e；`scripts/webview-e2e.rkt` 的
native 段在三平台 CI 真窗口跑（Windows=WebView2 / Linux=WebKitGTK / mac=WKWebView）。

## 原生传输 Windows 端口（WebView2）

vtable 槽位全部对照官方 WebView2.h（Microsoft.Web.WebView2 nupkg）核实：
`PostWebMessageAsJson=32`、`add_WebMessageReceived=34`、
`add_WebResourceRequested=55`、`AddWebResourceRequestedFilter=57`、
`WebMessageReceivedEventArgs.TryGetWebMessageAsString=5`、
`WebResourceRequestedEventArgs.get_Request=3/put_Response=5`、
`WebResourceRequest.get_Uri=3`、`Environment.CreateWebResourceResponse=4`。
要点：事件回调是双指针 Invoke（self,sender,args）——init 回调构造器的
`_int32` 第二参会截断 64 位指针，必须用 `make-com-event-handler`；
资源响应体走 `SHCreateMemStream`（shcore.dll）+ `CreateWebResourceResponse`；
bootstrap 经 `AddScriptToExecuteOnDocumentCreated`(27) 注入；GLZ1 响应由
窗口泵线程 `PostWebMessageAsJson` 回灌（页面 message 事件里转
`__glz1Deliver`）。**改槽位前重新下载 nupkg 核对，勿凭相邻接口猜**（见上文
get_CoreWebView2 事故）。

## 原生传输 Linux 端口（WebKitGTK）

WebKitGTK 与 WKWebView 共享 `window.webkit.messageHandlers` JS API，bootstrap
的 webkit 分支原样可用。要点：`webkit_web_view_new_with_user_content_manager`
携带专用 UCM（`register_script_message_handler "glz1"` + 信号
`script-message-received::glz1`，js_result 经 jsc_value_is_string/to_string
取文本）；scheme 走默认 WebContext 的 `register_uri_scheme`（进程级共享，
回调用 `webkit_uri_scheme_request_get_web_view` 按请求方 webview 分发——
多窗口/多 app 各自的 public-dir 不串）；响应体 `g_memory_input_stream_
new_from_data` + `webkit_uri_scheme_request_finish`（回调内同步 finish 是
文档模式）；交付用 `webkit_web_view_evaluate_javascript`（WebKitGTK 2.40+，
pump 线程）；jsc 绑定在 libjavascriptcoregtk-4.1。

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
geometry
set-geometry!
screen-area
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
raco glaze schema write|check [--json]
raco glaze build
raco glaze help
```

`init` 生成的 `main.rkt` 必须在 `module+ main` 中直接使用 `run-app`，并导出
`glaze.rktd` 指定的 route list，使 schema 工具加载模块时不会启动应用。

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
- `#:capability` 启用后，路由必须显式声明 `#:permission`，未授权 handler 不得执行；
- path/command scope 必须 deny 优先，路径比较需抵抗 `..` 与已有 symlink 越界；
- 内置 filesystem routes 必须在 handler 前检查 `fs:read` / `fs:write`；复制和移动同时检查源与目标；
- 内置 shell routes 必须直接执行程序而不拼接系统 shell；创建前校验命令/参数 scope，前端 cwd/env 默认拒绝，限制输出/句柄数，并把后台句柄绑定到 capability；
- 内置 store routes 必须在 handler 前检查 `store:read` / `store:write`，root 不可穿越，写盘保持原子性，缓存按 capability 隔离；
- 内置 system routes 的 clipboard 读写、notification、opener 与 OS/hostname 必须分别授权；路径和 URL 都在 handler 前完成 scope 检查；
- path resolver 的 app-id 不得形成路径穿越；resource 路径必须同时拒绝绝对路径、`..` 和已有 symlink 逃逸；
- 内置 HTTP routes 必须限制请求/响应大小、总超时和重定向次数；每个重定向目标在连接前重新按 `http:request` 的 URL scope 鉴权，跨 origin 不转发凭据 header；
- 内置 SQL routes 必须限制数据库 root、连接数和查询结果；连接按 capability 所有权隔离，select 权限不得执行写语句，值通过参数绑定而不是字符串拼接；
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

- **运行时调度的后端模块必须显式嵌入**：webview/sys/tray 三个调度器用 `dynamic-require`
  按 `(system-type 'os)` 挑后端，`raco exe` 的静态分析看不到这些引用——不 `++lib` 显式嵌入，
  产物就是"能启动、headless 冒烟全过、原生窗口/托盘/通知一用就 collection not found"。
  `build-app` 已自动 `++lib` 当前平台三后端（`platform-backend-modules` 是唯一事实来源）；
  绕开 build-app 直接调 `raco exe` 的项目（如 gPTP Studio）用同一导出自行拼接。
  这类洞只有覆盖调度路径的冒烟能拦住：headless 即可——`dynamic-require` 后端并调
  `supported?`，不开窗（gPTP Studio v1.0.0 的 deb 就是这样漏出去的）

### 加载外部原生库（ffi-discovery）

- 一律走 `glaze/ffi-discovery` 的 `ffi-lib*`，不要手写裸 `ffi-lib`：多 soname 候选
  （libpcap 在 Fedora/Arch 是 `.so.1`、Debian/Ubuntu 因 ABI 历史是 `.so.0.8`——单后缀
  曾让 gPTP Studio v1.0.0 在 Ubuntu 装着依赖仍启动即崩）、multiarch 绝对路径兜底、
  永不 raise，失败原因经 `ffi-lib-reason` 单行可读
- 缺失的原生依赖是**可降级的能力**（`supported?` -> #f + 原因），不是启动崩溃：
  `--version`/`--doctor`/GUI 必须能在没有它的情况下起来并如实报告

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

## Update

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
