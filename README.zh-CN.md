# Glaze

一个用 Racket 构建现代桌面应用的 Lisp-native 框架。

Glaze 让应用逻辑继续留在 Racket 中，界面使用普通 Web 技术，并通过统一 API 接入原生 WebView、系统托盘、剪贴板、通知、文件对话框和应用打包等桌面能力。

[![CI](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/glaze/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) · **中文**

## 为什么是 Glaze

Racket 已经提供 `racket/gui`，Glaze 面向的是另一类桌面应用：**Web UI + Racket Runtime + 原生桌面能力**。

Glaze 不是 Electron 的复制品。它不内置 Chromium，也不额外引入 Node Runtime。当前设计理念更接近 Tauri：

```text
Web UI
  |
  | HTTP / JSON / SSE
  v
Racket Runtime
  |
  +-- WebView
  +-- Tray
  +-- System capabilities
  +-- Packaging helpers
  |
Native OS APIs
```

当前通过 Racket FFI 使用系统 WebView：

- Windows：WebView2
- macOS：WKWebView
- Linux：WebKitGTK

Glaze 明确采用 GUI-first 模式，运行时必须具备可用的原生 WebView。后端缺失或损坏时，启动会失败并给出对应平台的安装/修复指引，而不会静默改成浏览器标签页。

当前前后端桥接有意保持简单：请求使用本地 HTTP JSON API，Racket 向前端推送事件使用 Server-Sent Events。完整 RPC 框架和插件系统还不是当前公共架构的一部分。

## 快速开始

安装：

```bash
raco pkg install --auto glaze
```

开发仓库可以直接 link：

```bash
git clone https://github.com/turinglambdaai/glaze.git
cd glaze
raco pkg install --auto --no-docs --link "$PWD"
```

最小应用只需要统一公共入口：

```racket
#lang racket/base

(require racket/runtime-path
         glaze)

(define-runtime-path public "public")

(run-app #:public-dir public
         #:title "Hello Glaze")
```

在 `public/` 中放置 `index.html` 后运行程序即可。完整最小示例见 [`examples/hello/`](examples/hello/)。

也可以使用 CLI 创建项目：

```bash
raco glaze init myapp
cd myapp
racket main.rkt
```

## 已实现能力

当前仓库已经包含：

- 原生 WebView 窗口：生命周期、导航、标题/URL 查询、截图、窗口控制和菜单
- 本地静态文件服务器与 SPA fallback
- JSON API 路由和自动生成的浏览器客户端
- Racket → 前端的 SSE 事件推送
- 系统托盘和菜单
- 剪贴板、通知、打开/定位文件、单实例能力
- 文件/目录对话框、Deep Link、开机自启动辅助能力
- `raco glaze build` 应用打包
- 更新检查和离线许可证工具
- 原生 WebView 不可用时的可操作诊断信息

Glaze 本身使用 Racket 实现，原生集成主要通过 FFI；核心框架不要求用户安装 C 编译器。

## 平台支持

仓库 CI 使用 Racket 8.12 在 Windows、macOS、Linux 上运行测试，并在三个平台执行真实 WebView 端到端验证。Linux CI 使用 Xvfb + WebKitGTK。

| 能力 | Windows | macOS | Linux |
|---|---|---|---|
| 本地 Server / JSON API / SSE | 支持 | 支持 | 支持 |
| 原生 WebView | WebView2 | WKWebView | WebKitGTK |
| 系统托盘 | 支持 | 支持 | 支持 |
| 系统能力封装 | 支持 | 支持 | 支持 |
| 打包流程 | 支持 | 支持 | 支持 |

部分原生能力依赖操作系统组件或桌面会话。WebView 启动失败属于致命错误，并会提供对应平台的处理指引；应用层不应该直接 require 某个平台 backend。运行要求和诊断说明见 [`docs/gui-first.md`](docs/gui-first.md)。

## 架构

应用推荐只依赖 `(require glaze)`。WebView、Tray、Sys 模块在内部完成平台 backend 分发：

```text
Application
    |
    v
(require glaze)
Public facade: glaze/main.rkt
    |
    +-------------------------------+
    |               |               |
    v               v               v
Runtime          Capabilities     Tooling
app/server       webview/main     build/update
api/events       tray/main        CLI
                 sys/main
    |               |
    +-------+-------+
            v
Platform backends
Windows / macOS / Linux / stub
```

当前目标不是为了“架构漂亮”而一次性移动全部文件，而是先稳定依赖方向、生命周期和公共 API 合约。

详细设计见 [`docs/architecture.md`](docs/architecture.md)。

## 包与 Collection

仓库根目录是一个 `collection 'multi` 的可安装 Racket package：

- `glaze/` —— 框架核心和公共 facade
- `glaze-cli/` —— `raco glaze` 命令
- `glaze-doc/` —— Scribble API 文档
- `glaze-test/` —— 测试套件
- `examples/` —— 可运行示例
- `scripts/` —— CI 和验证脚本

`glaze/webview/`、`glaze/tray/`、`glaze/sys/` 内部包含公共 dispatcher 和平台实现。普通应用应优先 `(require glaze)`，而不是依赖 `webview-windows.rkt`、`tray-macos.rkt`、`sys-linux.rkt` 等实现文件。

## 示例

建议按以下顺序阅读：

- [`examples/hello/`](examples/hello/) —— 最小 `run-app` 应用
- [`examples/tray/`](examples/tray/) —— 系统托盘与菜单
- [`examples/events/`](examples/events/) —— JSON 请求 + SSE 推送
- [`examples/counter/`](examples/counter/) —— 更完整的 JS/Racket bridge
- [`examples/showcase/`](examples/showcase/) —— 综合能力展示
- [`examples/agent-verify.rkt`](examples/agent-verify.rkt) —— 程序化 WebView 验证
- [`examples/webview-demo.rkt`](examples/webview-demo.rkt) —— 直接 WebView 生命周期示例

## 项目状态

Glaze 当前仍是 pre-1.0 项目（package metadata 为 `0.7`）。跨平台实现、CI、打包链路已经存在，但公共 API 和生命周期仍处于稳定化阶段。

0.x 阶段优先保持兼容：不会仅仅为了未来目录更漂亮而大规模移动 backend，也不会随意删除已有 API。对于新应用，建议只使用文档化的公共入口。

## 安全边界

Glaze 的本地 HTTP bridge、静态文件服务、打包/签名、更新与原生 FFI 都属于安全敏感边界。安全问题请参考 [`SECURITY.md`](SECURITY.md)，不要在公开 issue 中直接发布利用细节或私钥等敏感信息。

## Roadmap

见 [`ROADMAP.md`](ROADMAP.md)。近期重点是：

- 稳定 application lifecycle
- 明确 public API
- 完善跨平台测试与打包验证
- 文档和示例
- 收紧安全与错误处理边界

IPC/event 模型的进一步演进、更多系统 capability 会放在后续阶段；插件 SDK、完整 hot reload 不属于当前稳定化工作的范围。

## 文档

- [`docs/architecture.md`](docs/architecture.md) —— 架构与依赖规则
- [`ROADMAP.md`](ROADMAP.md) —— 分阶段路线图
- [`CONTRIBUTING.md`](CONTRIBUTING.md) —— 贡献流程
- [`SECURITY.md`](SECURITY.md) —— 安全报告流程
- `raco docs glaze` / `glaze-doc` —— API 文档

## 开发

```bash
raco pkg install --auto --no-docs --link "$PWD"
raco make glaze/main.rkt glaze-cli/cli.rkt
raco test glaze-test/
```

CI 还会在 Windows、macOS 和 Linux 上运行原生 WebView e2e、最终打包产物执行验证和安装器构建，并验证过滤后的 Racket source package 可以独立安装。

## 贡献

欢迎贡献。请优先提交范围清晰、能够单独审查的修改；在可行的情况下保持现有 API 兼容，并为行为修复增加 regression test。平台实现应继续位于公共 dispatcher 后面。

详细流程见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## License

MIT —— 见 [`LICENSE`](LICENSE)。
