# Phase 0 — 范围与现状

方法：scv-app（`~/.claude/skills/scv-app`）。本文件把信息分成三类：**已验证事实 / 待验证假设 / 产品决策**（铁律 2）。

## 范围

- 类型：**新增设计**（空目录起步，无已有代码）。
- 产品：ClipVault —— macOS 原生、**纯本地**的剪贴板历史应用。
- 核心诉求（来自用户原话）：
  1. 常规剪贴板功能（记录、浏览、搜索、回贴）。
  2. 「不限制剪切板的历史数据」——历史存数据库，支持非常多的历史。
  3. 「搜索可以非常快」。
  4. 「甚至可以搜图片」——OCR + 向量语义搜索（以文搜图）。
  5. 「做成可拓展的，这样我可以切换底层的基建，性能越好的电脑用越好的模型」。
- 不在范围：云同步、多设备、账号、团队共享、iOS 端、Windows/Linux。

## 已验证事实（2026-10-16 在本机实测）

| # | 事实 | 证据 |
|---|---|---|
| F1 | 机器：Apple M4，macOS 27.0.1，Swift 6.4，**仅 Command Line Tools，无 Xcode** | `sw_vers`、`swift --version`、`xcodebuild` 报错 |
| F2 | SwiftPM 可构建；**XCTest 不可用，Swift Testing 可用** | scratchpad 最小包 `swift test`：XCTest `unable to resolve module`；`@Test` 通过 |
| F3 | 系统 SQLite 3.54.0，**FTS5 trigram 分词器可用**，中文子串命中 | `sqlite3 :memory:` 建 `fts5(tokenize='trigram')`，`MATCH '板历史'` 命中 |
| F4 | SDK 有 `NSPasteboard.accessBehavior`（macOS 15.4+，取值 default/ask/alwaysAllow/alwaysDeny）——**读剪贴板是受系统隐私控制的权限** | `NSPasteboard.h:55-170`；终端进程实测 `accessBehavior=2(alwaysAllow)` |
| F5 | Apple MobileCLIP Core ML 模型可从 HuggingFace 下载（经本机系统代理） | `apple/coreml-mobileclip` 返回 200；S2 image 80 MB + text 128 MB |
| F6 | **无 Xcode 也能运行时编译 .mlpackage**：`MLModel.compileModel(at:)` 0.11 s，加载 1.2 s | scratchpad `mi` 实测 |
| F7 | MobileCLIP-S2 签名：image 输入 `Image(Color 256×256)`；text 输入 `Int32 [1×77]`；两者输出 `final_emb_1 Float32 [1×512]` | 同上 |
| F8 | CLIP 分词器 `vocab.json` + `merges.txt`（openai/clip-vit-base-patch32）可下载 | 892 KB + 516 KB |
| F9 | Translation 框架有 `TranslationSession(installedSource:target:)`，可程序化翻译（用于中文查询 → 英文喂 CLIP） | SDK swiftinterface 第 188 行 |

## 待验证假设

| # | 假设 | 怎么验证 | 影响 |
|---|---|---|---|
| A1 | 新 .app 首次读剪贴板时 `accessBehavior` 为 `.ask`，系统弹授权；拒绝后读返回空 | 7B 真机 + 诊断项 | 启动断言（铁律 14） |
| A2 | 模拟 ⌘V 回贴需要「辅助功能」授权；ad-hoc 签名每次重建会让授权失效 | 7B 真机 | 回贴路径、已知限制 |
| A3 | FTS5 trigram 在 100 万条文本上 p95 < 50 ms | `--bench` | 性能预算 |
| A4 | 1–2 字查询（trigram 不支持）用 LIKE 扫描在 100 万条上可接受 | `--bench` | 可能需要第二套索引 |
| A5 | 暴力向量检索（Accelerate，fp16 512 维）在 10 万图上 < 30 ms | `--bench` | 是否需要 HNSW |
| A6 | MobileCLIP 英文查询效果可用；中文查询经系统翻译后效果可用 | 真数据跑（铁律 25） | 是否需要多语言模型 |
| A7 | Vision OCR（`VNRecognizeTextRequest`，zh-Hans+en）离线可用、单张 < 1 s | 7B | OCR 索引吞吐 |
| A8 | 系统翻译需要用户已安装中→英语言包；未安装时 `installedSource` 初始化失败 | 7B + 诊断项 | 降级路径 |

## 产品决策（需用户裁决，见 `1-questions.md`）

见 `1-questions.md` Q1–Q6。

## 兼容矩阵（铁律 29）

| 维度 | 支持 | 实际验证 |
|---|---|---|
| macOS | 15.4 – 27（因 F4 的隐私 API 起点 15.4） | **仅 27.0.1 真机**；15.4–26 标「声明支持、未验证」 |
| CPU | Apple Silicon（arm64） | M4；Intel 不支持 |
| 外观 | 浅色 / 深色 | 两者截图 |
| 语言 | 界面中文；内容任意 Unicode；OCR zh-Hans / zh-Hant / en | 中英混合样本 |
| 分辨率 | 单屏 / 多屏（面板出现在鼠标所在屏） | 单屏真机 |

## 性能预算（铁律 30；数值为**可调假设**，7A 测量比对）

| 指标 | 预算 |
|---|---|
| 打包产物 .app（不含模型） | ≤ 15 MB |
| 冷启动到菜单栏图标可用 | ≤ 1 s |
| 快捷键 → 面板可见 | ≤ 150 ms |
| 复制 → 历史中可见（文本） | ≤ 1 s（轮询 250 ms） |
| 文本搜索（≥3 字）p95，100 万条 | ≤ 50 ms |
| 文本搜索（1–2 字）p95，100 万条 | ≤ 150 ms |
| 语义搜图 p95，10 万图（含文本编码） | ≤ 100 ms |
| 空闲 CPU | < 1 % |
| 常驻内存（未加载模型 / 已加载 S2） | ≤ 150 MB / ≤ 600 MB |
| 后台索引吞吐（M4）：OCR / 向量 | ≥ 2 张/s / ≥ 20 张/s |
