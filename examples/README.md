# Glaze Examples — 功能索引

| 示例 | 一句话 | 展示的能力 |
|---|---|---|
| [`showcase/`](showcase/) | **一屏看尽全部能力（推荐先看）** | 宏路由全形态（类型校验/400/:path/500）、SSE 事件流 + 后端错误回流（on-error）、系统功能（剪贴板/通知/Finder/窗口控制）、Agent 验证（title/url/capture + 截图回传）、API token（401 演示）、更新检查、托盘、单实例 |
| [`hello/`](hello/) | 8 行最小应用 | run-app 一键入口、静态页面 |
| [`counter/`](counter/) | JS↔Racket 桥接主打 | define-api-routes、SSE 广播驱动 UI、api.js 生成客户端、模块可组合（provide api/bus） |
| [`webview-demo.rkt`](webview-demo.rkt) | WebView 生命周期 | 加载/导航/关闭/on-close/验证 API 实时打印、看门狗 |
| [`agent-verify.rkt`](agent-verify.rkt) | 无人值守验证 | agent 工作流：轮询断言 + 截图 + 退出码 |
| [`tray-demo.rkt`](tray-demo.rkt) | 跨平台托盘 | make-tray/菜单/tooltip 动态更新 |

## 快速开始

```bash
racket examples/showcase/main.rkt     # 综合演示（单实例锁定）
racket examples/counter/main.rkt      # 桥接 + 事件
racket examples/hello/main.rkt        # 最小应用
```

所有示例均可 `raco glaze build` 打包为独立应用。
