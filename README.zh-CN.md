# Glaze

用 [Racket](https://racket-lang.org/) 做后端、Web 技术做前端，构建桌面应用。一个 Racket 版的 [Tauri](https://tauri.app/) —— 用 Racket 写业务逻辑，用 HTML/CSS/JS 构建界面，打包为桌面应用。

![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **中文**

## 为什么选择 Glaze？

Racket 自带的 `racket/gui` 可以用，但很难做出现代化的产品级 UI。Glaze 采用了不同的思路：从 Racket 启动一个本地 Web 服务，然后在系统浏览器（Phase 1）或嵌入式 WebView（Phase 3）中展示。

你将获得：

- **Racket 处理逻辑** —— 完整的宏系统、契约、模式匹配
- **Web 构建界面** —— Tailwind、Svelte、React 或任意 Web 框架
- **JSON API 桥接** —— Racket 宏自动生成 API 端点

## 快速开始

```bash
# 安装
raco pkg install glaze

# 创建新项目
raco glaze init myapp
cd myapp

# 运行
racket main.rkt
```

浏览器会自动打开 `http://127.0.0.1:8080`，显示一个可用的页面。

## CLI 命令

```bash
raco glaze init <name>   # 创建新的 Glaze 项目
raco glaze dev           # 启动开发服务器并自动打开浏览器
raco glaze help          # 显示帮助
```

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

## 路线图

- [x] **Phase 1** —— 本地 HTTP 服务器 + 系统浏览器
- [ ] **Phase 2** —— 前端资源打包、系统托盘、应用打包
- [ ] **Phase 3** —— 原生 WebView 嵌入（WebView2 / WKWebView / WebKitGTK）

## 许可证

基于 [MIT License](LICENSE) 开源。
