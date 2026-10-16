# ClipVault

macOS 原生、纯本地的剪贴板历史。按 scv-app 方法开发，设计与证据见 `docs/scv/`、`evidence/`。

## 构建与运行

```sh
scripts/test.sh                 # 全部测试（仅 Command Line Tools 也可运行）
scripts/build-app.sh            # 从干净目录打包 → dist/ClipVault.app
open dist/ClipVault.app         # 菜单栏图标：左键打开面板，右键菜单
dist/ClipVault.app/Contents/MacOS/ClipVault --help   # 命令行：诊断、搜索、模型、维护
```

数据在 `~/Library/Application Support/ClipVault`（环境变量 `CLIPVAULT_HOME` 可改）。

## 能做什么

- 记录文本 / 富文本 / 链接 / 文件 / 图片，同内容自动合并并顺到最前；跳过密码管理器的隐藏内容，可排除指定 App。
- 历史不限条数（SQLite）；全文搜索支持中英文子串，100 万条 p95 < 10 ms（`evidence/7B/`）。
- 图片：离线 OCR（中英）可搜图中文字；可选语义搜图（MobileCLIP S0 / S2 / B-LT，按内存推荐，设置 › 模型 下载后完全离线）。
- 扩展：同签名的 Core ML CLIP 模型写进 `models/custom.json` 即可用；新后端实现 `EmbeddingProvider` / `VectorIndex` 协议。
- 回车只复制到剪贴板（不需要辅助功能权限）；快捷键默认不设置，在设置页录制。

## 已知限制（本轮 A 方案未验证的部分）

- 只在 macOS 27 / M4 / 32 GB 上测过；未在 15.4–26 验证。
- 菜单栏、面板、设置页、快捷键尚无截图证据；.app 自身的剪贴板访问权限弹窗未验证。
- 语义搜图召回偏低：相似度门槛（0.18，可在 settings 表 `semantic_threshold` 调）对 B-LT 偏高，部分正确图片（如「sunset over the ocean」）未返回；已返回结果的第一名均正确。
- 中文语义搜图依赖系统「中文→英文」翻译语言包（系统设置 › 通用 › 语言与地区 › 翻译语言）；未安装时中文只走文字 / OCR 搜索可靠。
- 1–2 字查询只覆盖每条内容的前 2048 个字符。
- ad-hoc 签名，未公证；schema v1 在发布前已改过一次（加入 seq / n-gram 索引），旧测试库不兼容。
- Phase 8 五视角评审、Phase 9 证据整理未做。

## 许可证

代码采用 MIT（见 `LICENSE`）。模型不随仓库分发，由用户在应用内下载，各自遵循其许可：MobileCLIP（Apple ASCL）、CLIP 分词器（OpenAI，MIT）。测试夹具说明见 `Tests/ClipCoreTests/Fixtures/clip-bpe/NOTICE.md`。
