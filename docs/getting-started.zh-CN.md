# 入门：第一个 Glaze 桌面应用

[English](getting-started.md) · **简体中文**

这是完整的新手路径：安装、脚手架、类型化 Racket API、JavaScript 调用、schema 审查、真实窗口验证与构建。英文技术定义位于 [Getting started](getting-started.md)；本译文解释同一流程，示例与命令保持一致。其他介绍链接这里，不另复制一套步骤。

## 1. 安装 Glaze，检查平台

安装 **Racket 9.0+ (CS)**，确保可以运行 `raco`：

```sh
racket --version
raco pkg install --auto glaze
raco glaze help
```

预期：`raco glaze help` 列出命令而不启动窗口。若使用源码 checkout 而非 catalog 包，在仓库根目录运行 `raco pkg install --auto --link "$PWD"`。

Glaze 在**原生桌面 WebView** 中渲染。Windows 需要 [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/consumer/)（附带的 loader DLL 不是 Runtime）；macOS 自带 WKWebView，但需要交互图形会话；Linux 需要 GTK 3、WebKitGTK 和图形会话（无屏 CI 使用 Xvfb）。启动失败时保留原生错误并给修复说明，不改开 Chrome/Edge/Safari。`doctor` 可诊断安装前置条件，**不能**保证图形会话存在。

## 2. 创建项目

```sh
raco glaze init myapp
cd myapp
raco glaze inspect --json
raco glaze doctor --json
raco glaze schema check --json
```

预期：`inspect` 列出可编辑和生成文件，`doctor` 报告前置条件，生成的空路由 schema 与基线一致。脚手架目录如下：

```text
myapp/
├── main.rkt           # exported api; module+ main runs the app
├── glaze.rktd         # schema module, exported binding and baseline location
├── glaze-schema.json  # deterministic application API contract
├── AGENTS.md          # project-local edit and validation boundaries
├── verify.rkt         # independent native title/URL/PNG check
└── public/
    └── index.html     # editable HTML/CSS/JS page
```

`glaze.rktd` 声明 `main.rkt` 模块和导出的 `api` 路由列表。启动留在 `module+ main`，使 schema 检查加载 API 时不会打开 GUI。

## 3. 增加类型化 Racket 路由

用以下内容替换 `main.rkt`：

```racket
#lang racket/base

(require racket/runtime-path glaze)
(define-runtime-path public "public")

(define-api-routes api
  [(POST "api/greet")
   (greet [name GString "World"])
   (hasheq 'message (string-append "Hello, " name "!"))])
(provide api)

(module+ main
  (run-app #:public-dir public
           #:api api
           #:title "myapp"))
```

`GString` 是 Glaze 类型描述符：运行时验证 `name` 是字符串，且在生成的 GLZ1 应用 schema 中记录字符串参数。与普通 `string?` 谓词不同，它产生类型化命令契约。同一声明生成 `glaze.api.greet` 客户端绑定，不需要手写 API 映射。

## 4. 从页面调用路由

用以下内容替换 `public/index.html`：

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Glaze App</title></head>
<body>
  <h1>My first Glaze app</h1>
  <button id="greet">Greet Ada</button>
  <output id="reply" aria-live="polite">Press the button.</output>
  <script src="/glaze/api.js"></script>
  <script>
    document.getElementById("greet").addEventListener("click", async () => {
      const reply = document.getElementById("reply");
      try {
        const result = await glaze.api.greet({name: "Ada"});
        reply.textContent = result.message;
      } catch (error) {
        reply.textContent = "Request failed: " + error.message;
      }
    });
  </script>
</body>
</html>
```

预期：点击 **Greet Ada** 显示 **Hello, Ada!**。

生成的 JavaScript 客户端同时支持原生 GLZ1 WebView 消息和 HTTP 开发适配器。0.x 期间，生成的 `run-app` 默认使用**原生 WebView 内部的** `http` transport。1.0 切换默认前，打包产品可在 Windows、macOS、Linux 显式使用 `#:transport 'native`。两种传输都不允许退化为仅浏览器应用。

## 5. 审查应用 schema

```sh
raco glaze schema check --json
```

增加 `greet` 后的预期结果：相对空脚手架基线为兼容新增，不静默改写文件。确定新路由是应用公开契约后，更新并检查基线：

```sh
raco glaze schema write
raco glaze schema check --json
```

审查并提交 `glaze-schema.json` 的差异。不能为掩盖不兼容变更而重写基线。加载失败时检查 `api` 导出及 `glaze.rktd` 设置。

## 6. 打开并验证真实窗口

```sh
raco glaze dev
# Close the application window before continuing.
raco glaze verify
```

预期：`dev` 运行真正的 `main.rkt` 并打开原生桌面窗口。生成的 `verify.rkt` 独立地在真实原生窗口加载标准 **Glaze App** 页面，检查标题/URL、捕获非空 PNG，失败时以非零退出码结束。它本身不验证问候按钮是否成功；产品特定验收需要扩展。

打不开窗口时，检查 `raco glaze doctor --json`、平台运行时安装和底层 WebView 错误。本机验证不能替代 Windows、macOS、Linux 的原生 CI e2e。

## 7. 构建

```sh
raco glaze build --name myapp
```

预期：`dist/` 下产生可分发产物。需要安装器时，使用 `--installer` 并审查版本、发布者和稳定的 `--identifier`。缺少安装器工具可能带警告回退为归档**打包格式**；应用仍需要真正原生 WebView。生产分发需要平台冒烟及适用的签名/公证。

## 继续探索

- [Counter 示例](../examples/counter/)：更多路由、状态和事件。
- [Agent 工作流（英文）](agent-native.md)：inspect、doctor、schema、verify。
- [当前架构（英文）](architecture.md)：原生传输及兼容适配器。
- [发布流程（英文）](RELEASING.md)：证据和来源。
- [贡献指南（英文）](../CONTRIBUTING.md)：框架开发。
