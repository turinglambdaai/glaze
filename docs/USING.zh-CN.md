# Glaze 使用与支持

[English](USING.md) · **简体中文**

## 何时使用

需要 Racket 后端与共享 HTML/CSS/JS 界面，并运行于系统原生 WebView 时选择 Glaze。必须使用真实桌面窗口，不提供外部浏览器回退；产品数据、权限和服务政策归应用。

## 要求与成熟度

需要 Racket CS 9.0+。Windows 需要 WebView2 Runtime，macOS 需要交互式 WKWebView 会话，Linux 需要 GTK 3/WebKitGTK 和图形会话。桌面各端已有原生 GLZ1；0.x 的 run-app 默认仍是在原生 WebView 中使用 HTTP 适配器。

## 一次有效验证

按类型化路由教程操作，审阅 schema 变更，并在自己的打包窗口验证可观察操作。生成的标题、URL 和截图探测仅是起点，不能证明产品流程。每个支持的 WebView 都需检查焦点、输入法、缩放、无障碍、对话框和取消。

## 推荐阅读路径

1. [第一个应用](getting-started.zh-CN.md)
2. [文档地图](README.md)
3. [API 稳定性](api-stability.md)
4. [GUI-first 契约](gui-first.md)
5. [发布](RELEASING.md)

技术规范保持一个权威版本；链接目标为英文时，它仍是对应行为的定义，不是第二份中文协议。

## 升级、数据与支持

固定并记录应用实际测试的包版本和平台。升级前阅读 CHANGELOG 与兼容契约，在副本上测试用户数据迁移，并保留可恢复版本。框架或库不替产品提供数据库备份、发布证书、退款、账号恢复或隐私政策。不要把示例夹具中的客户、商品和金额当成真实 offer。

在 [Issues](https://github.com/turinglambdaai/glaze/issues) 反馈，中文或英文均可。包含包版本/提交、Racket 版本、系统架构、最小复现和已脱敏的首条错误。不要附带真实密钥、客户凭据、支付原始数据或私密文档。社区支持不承诺响应时限。

[现行许可证](../LICENSE) · [CHANGELOG](../CHANGELOG.md)
