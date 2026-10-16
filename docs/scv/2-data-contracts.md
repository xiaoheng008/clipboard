# Phase 2 — 数据契约

> 契约：本文件的 schema 与 `Sources/ClipCore/Storage/Schema.swift` 必须同步修改；`meta.schema_version` 只前向迁移。

## 存储 schema v1

```sql
meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)        -- schema_version, created_at
settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)    -- hotkey, active_model, excluded_apps(JSON), vector_index

items(
  id            INTEGER PRIMARY KEY,
  kind          TEXT NOT NULL CHECK (kind IN ('text','rich','url','file','image')),
  content_hash  TEXT NOT NULL UNIQUE,      -- sha256(kind || 0x00 || 规范化主内容)；去重键（Q1）
  text          TEXT,                       -- 纯文本 / URL / 文件路径（换行分隔）；image 为 NULL
  blob_hash     TEXT,                       -- image：blobs/ 下的 sha256；其它为 NULL
  byte_size     INTEGER NOT NULL,
  width INTEGER, height INTEGER,            -- image
  source_bundle TEXT, source_name TEXT,     -- 复制时前台 App
  created_at    INTEGER NOT NULL,           -- ms since epoch（首次复制）
  last_used_at  INTEGER NOT NULL,           -- ms（最近一次复制 / 从历史复制）
  use_count     INTEGER NOT NULL DEFAULT 1,
  pinned        INTEGER NOT NULL DEFAULT 0,
  ocr_text      TEXT,                       -- vision 任务写入
  labels        TEXT,                       -- vision 任务写入（空格分隔英文标签）
  fts_truncated INTEGER NOT NULL DEFAULT 0  -- 文本超过 H2 上限
)
INDEX items_recent ON items(pinned DESC, last_used_at DESC, id DESC)
INDEX items_kind_recent ON items(kind, last_used_at DESC)

representations(item_id INTEGER REFERENCES items(id) ON DELETE CASCADE,
                uti TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(item_id, uti))
                -- rich 的 RTF/HTML、file 的 file-url 列表，用于原样回写剪贴板

items_fts USING fts5(body, tokenize='trigram', content='', contentless_delete=1)
                -- rowid = items.id；body = text(截断) + ocr_text + labels + source_name

index_jobs(
  id INTEGER PRIMARY KEY,
  item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('vision','embed')),
  model_id TEXT NOT NULL DEFAULT '',        -- embed 用
  state TEXT NOT NULL CHECK (state IN ('pending','running','failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  not_before INTEGER NOT NULL DEFAULT 0,    -- 退避
  lease_until INTEGER NOT NULL DEFAULT 0,   -- running 的租约
  last_error TEXT,
  UNIQUE(item_id, kind, model_id))
                -- 成功 = 删除任务行（与结果同一事务）；不存在 'done' 状态

embeddings(item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
           model_id TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL,  -- fp16 小端，L2 归一化
           PRIMARY KEY(item_id, model_id))
```

`PRAGMA journal_mode=WAL; foreign_keys=ON; synchronous=NORMAL; busy_timeout=5000`。

## 实体契约

### ClipItem（本地权威）

| 维度 | 回答 |
|---|---|
| 身份与权威 | `id` 由 SQLite 分配；`content_hash` 是业务身份（去重）。只有本机用户通过复制、删除、清空修改。无外部裁决者。 |
| 存储与读取 | SQLite `items` + `representations`；图片字节在 `blobs/`。UI 只从 SQLite 分页读（上限 H6），缩略图从 `thumbs/` 懒加载、可重建。内存不持有唯一副本。 |
| 生命周期 | 创建：复制时 ingest。更新：同哈希再复制或从历史复制 → `last_used_at`/`use_count`。删除：单条删除 / 清空（Q4 全部）。无过期（不限历史）。迁移：只前向，迁移前复制库文件到 `clipvault.sqlite.bak-v<n>`。 |
| 「离线」与同步 | 无网络依赖，无同步。 |
| 并发与冲突 | 单写者 actor；跨进程（CLI）靠 SQLite 锁。去重通过 `INSERT … ON CONFLICT(content_hash) DO UPDATE`，原子。 |
| 一致性 | 不变量 I1–I5 见 `3-state-model.md`，由本地事务保证；`--verify` 检测。 |
| 安全 | 单个 macOS 用户的 Library 目录（无账号 → 账号隔离不适用，理由：无登录概念，OS 用户即隔离边界）。Concealed/Transient 不入库（Q2）。日志不写内容。 |
| 失败与证据 | 写库失败：记日志 + 诊断计数，下次变化继续。库损坏：启动诊断 FAIL，提示，不自动删除（本地权威不可重建）。 |

### Blob（本地权威，文件）

| 维度 | 回答 |
|---|---|
| 身份 | sha256(字节)，不可变。 |
| 写入协议 | `tmp/<uuid>` 写入 → `fsync` → `rename` 到 `blobs/ab/<hash>`（已存在则丢弃临时文件）→ **然后**提交 items 事务。 |
| 删除协议 | 提交删除事务 → 若无条目引用该 hash → 删文件与缩略图。死在中间 = 孤儿文件，`--gc` 回收。 |
| 不变量 | I2：每个 `items.blob_hash` 对应的文件存在。孤儿文件允许存在（无害）。 |

### IndexJob（本地权威的进度，等价于 scv-app 的 Outbox）

| 维度 | 回答 |
|---|---|
| 入队 | 与条目同一事务（vision + 当前激活模型的 embed）；激活新模型时为所有缺向量的图片批量入队（事务分批，每批 1000）。 |
| 认领 | 事务内 `pending 且 not_before<=now` 或 `running 且 lease_until<now` → `running, lease_until=now+H4`。 |
| 完成 | 结果写入 + 删除任务行在同一事务；`embeddings` 用 UPSERT（重复处理幂等）。 |
| 失败 | `attempts+1`；`< H3` → `pending, not_before=now+2^attempts s`；否则 `failed` + `last_error`。条目被删 → 级联删除任务（「谁来收尾」：外键）。 |
| 被杀 | `running` 租约过期后被任意执行器重新认领（启动时立即跑一轮）。 |
| 可见性 | 诊断：pending / running / failed 计数；设置页显示语义索引覆盖率。 |

### Embedding（派生）

| 维度 | 回答 |
|---|---|
| 身份 | `(item_id, model_id)`。`model_id` 包含版本（如 `mobileclip-s2@1`），模型文件变了必须换 id。 |
| 存储 | SQLite fp16；内存 `VectorIndex` 只装**激活模型**的向量，可从库重建。 |
| 一致性 | 内存索引与库的差异：启动全量加载；运行中 add/remove 跟随事务提交后调用。诊断比对「库内向量数 = 索引向量数」。 |
| 切换模型 | 旧向量保留（Q5），`--model purge-inactive` 三级阶梯清理。 |

### 模型清单（契约：`Resources/models.json` ↔ `ModelManifest.swift`）

```json
{ "id": "mobileclip-s2@1", "family": "coreml-clip", "displayName": "MobileCLIP S2",
  "tier": 2, "dim": 512, "imageSize": 256, "contextLength": 77,
  "minMemoryGB": 16, "imageInput": "image", "textInput": "text", "output": "final_emb_1",
  "tokenizer": "clip-bpe",
  "files": [ {"path": "image.mlpackage/Manifest.json", "url": "...", "sha256": "...", "size": 617}, ... ] }
```

安装校验：每个文件 sha256 必须匹配，否则删除整个临时目录并报错。安装原子性：下载到 `tmp/model-<uuid>/` → 校验 → 编译 → `rename` 到 `models/<id>/` → 写 `install.json`。目录存在但无 `install.json` = 未安装（启动时清理）。

## 包内的值（铁律 16）

| 值 | 为什么可以公开 |
|---|---|
| 模型下载 URL（huggingface.co/apple/coreml-mobileclip、openai/clip-vit-base-patch32） | 公开仓库 |
| 文件 sha256 | 用于完整性校验，公开 |
| 无 API key、无 token | — |

## 契约标注清单

| 契约 | 两端 | 同步要求 | 旧版本策略 |
|---|---|---|---|
| SQLite schema | `Schema.swift` ↔ 本文件 | 加版本号 + 迁移函数 | 新版本读旧库：前向迁移；旧版本读新库：`schema_version` 更高则拒绝启动并提示升级 |
| 模型清单 | `models.json` ↔ `ModelManifest` | 新字段可选 | 未知 family 忽略并在诊断 WARN |
| fp16 向量编码 | `VectorCodec` ↔ `embeddings.vec` | 小端 fp16 + `dim` 列 | dim 不匹配的行跳过并诊断计数 |
| 自写剪贴板标记 | `PasteboardWriter` ↔ `CaptureDecision` | 类型名 `local.clipvault.self` | — |
