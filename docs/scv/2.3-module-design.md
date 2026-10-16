# Phase 2 — 模块设计

## SwiftPM targets 与依赖方向

```
ClipVault (executable)  ── App 入口 / CLI 分发 / AppKit+SwiftUI 界面
   │
   ├─▶ ClipPlatform      ── 平台适配：NSPasteboard、Vision、Core ML、Translation、Carbon 热键、硬件探测、下载
   │      │
   └──────┴─▶ ClipCore   ── 纯逻辑 + SQLite 存储 + 协议；不 import AppKit/Vision/CoreML
                              （import Foundation、SQLite3、Accelerate、CryptoKit）
ClipCoreTests ─▶ ClipCore（Swift Testing）
ClipPlatformTests ─▶ ClipPlatform（需真实系统框架的集成测试：OCR、分词器对拍、模型编码）
```

## ClipCore（运行时能力层 + 业务模块）

| 模块 | 职责 | 承担的独立约束 |
|---|---|---|
| `Storage/SQLite.swift` | 薄 C API 封装：prepare/bind/step、事务 | **所有 `sqlite3_` 调用只在此文件**（静态扫描测试钉住） |
| `Storage/Schema.swift` | DDL、迁移、版本检查 | 只前向；迁移前备份 |
| `Storage/Database.swift` | `actor Database`：单写连接；ingest、touch、delete、clear、jobs、embeddings、settings | 复合写事务；actor 内不 `await`（无重入，C39） |
| `Storage/ReadStore.swift` | 只读连接：分页列表、FTS/LIKE 查询、统计 | 分页上限 |
| `Storage/BlobStore.swift` | 内容寻址文件：put / url / delete / list | tmp→fsync→rename |
| `Capture/` | `PasteboardSnapshot`（值类型）、`CaptureDecision`（纯函数）、`ContentHasher` | 隐私跳过、自写识别、分类、去重键 |
| `Search/QueryPlanner.swift` | 纯函数：查询串 → FTS 表达式 + LIKE 条件 + 过滤 | trigram 3 字门槛、转义 |
| `Search/RankFusion.swift` | 纯函数：文本结果 + 语义结果 → 合并排序（RRF + 阈值） | 判据可空跑（铁律 25） |
| `Search/SearchService.swift` | 编排：planner → ReadStore → (translator → encoder → VectorIndex) → fusion；过期请求丢弃 | 只返回已提交数据 |
| `Index/IndexWorker.swift` | 任务循环：认领 → 调用 provider → 事务写结果 | 租约、退避、幂等 |
| `Index/Protocols.swift` | `EmbeddingProvider` / `TextEmbedder` / `ImageEmbedder` / `OCRProvider` / `QueryTranslator` / `VectorIndex` | 扩展边界 |
| `Index/FlatVectorIndex.swift` | fp16 存储 + Accelerate 分块点积 top-K | 内存有界（按激活模型） |
| `Index/VectorCodec.swift` | Float ↔ fp16 Data、L2 归一化 | 契约 |
| `Models/ModelManifest.swift` | 清单解析、合并、校验；`HardwareRecommendation`（纯函数） | 契约 |
| `Models/CLIPTokenizer.swift` | CLIP BPE 分词（纯 Swift） | 对拍已知 token id |
| `Diagnostics/Diagnostics.swift` | 检查项注册、执行、格式化、退出码 | 只读 |
| `Maintenance/` | reindex / gc / verify / purge-inactive 的「计划（纯）+ 执行」 | 三级阶梯 |
| `Support/Log.swift` | 滚动文件日志 | 脱敏：只记 id、kind、大小、耗时 |
| `ClipService.swift` | 业务门面：ingest(snapshot)、copyBack(id)、delete、clear、pin、activateModel… | UI 与 CLI 的唯一业务入口 |

## ClipPlatform（平台适配点）

| 适配器 | 平台 API | 被谁调用 |
|---|---|---|
| `PasteboardReader` / `PasteboardWriter` | NSPasteboard | `ClipboardWatcher`、`ClipService.copyBack` |
| `ClipboardWatcher` | Timer(main) + changeCount | App 启动 |
| `VisionOCR` / `VisionLabeler` | VNRecognizeTextRequest / VNClassifyImageRequest | IndexWorker |
| `CoreMLCLIPProvider` | MLModel | IndexWorker、SearchService |
| `VisionFeaturePrintProvider` | VNGenerateImageFeaturePrintRequest | IndexWorker |
| `AppleTranslator` | TranslationSession(installedSource:) | SearchService |
| `HotKeyCenter` | Carbon RegisterEventHotKey | App（设置了快捷键才注册） |
| `HardwareProbe` | sysctl hw.memsize / machdep.cpu.brand_string | 设置页、`--model recommend` |
| `ModelInstaller` | URLSession 下载 + CryptoKit + MLModel.compileModel | 设置页、CLI |
| `PermissionProbe` | NSPasteboard.accessBehavior | 诊断、启动断言 |

## ClipVault（入口）

| 组件 | 入口 / 触发者 |
|---|---|
| `main.swift` | 进程入口：有 `--` 参数 → `CLI.run`；否则 `NSApplication` |
| `AppDelegate` | `applicationDidFinishLaunching`：打开运行时、启动断言、watcher、worker、状态栏、热键 |
| `StatusBarController` | NSStatusItem 点击 / 菜单 |
| `PanelController` + `PanelView` | 热键、菜单「打开」 |
| `SettingsWindow` | 菜单「设置…」 |
| `CLI` | 命令行参数 |

## 事务边界

| 操作 | 事务内容 |
|---|---|
| ingest | upsert item + representations + FTS + 入队 jobs |
| vision 完成 | 更新 ocr_text/labels + 重写 FTS 行 + 删除 job |
| embed 完成 | upsert embedding + 删除 job |
| delete | 删 item（级联 representations/jobs/embeddings）+ 删 FTS 行 |
| clear | 删全部 items + FTS 全删（`DELETE FROM items_fts`）|
| activate model | 写 settings.active_model + 分批入队 embed（每批一个事务；中断后重跑幂等，UNIQUE 去重） |

## 自证设计

- 诊断项（`--diagnose` 与设置页共用）：版本 / schema 版本 / 库完整性（`PRAGMA quick_check`）/ 剪贴板访问策略 / 监听心跳 / 条目统计 / blob 缺失数（I2）/ FTS 行数 = 条目数（I3）/ 任务 pending·running·failed / 过期租约 / 激活模型状态与文件校验 / 向量覆盖率 / 内存索引向量数 = 库内数 / 翻译可用性 / 热键注册 / 磁盘占用 / 日志路径。
- 三级阶梯：`--reindex`、`--gc`、`--model purge-inactive` 都是 `--dry-run` / `--only <id>` / `--all`，必须且只能给其一。
- 日志导出：`--export-logs <dir>` 与设置页按钮。
