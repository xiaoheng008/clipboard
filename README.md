# ClipVault

**一个纯本地、不限条数、能用中文“描述意思”来搜索的 macOS 剪贴板历史工具。**

复制过的文字、链接、文件和图片都会被记下来。按 `⌥ Space` 唤出面板，输入关键词或一句描述，比如「上周那个报错」「海边的日落」「代码截图」，毫秒级找回。所有数据和模型都在你的 Mac 上，不联网、不上传。

## 特性

- **不限历史条数**：存在本地 SQLite 数据库里，100 万条历史的关键词搜索仍在 10 毫秒以内。
- **中英文关键词搜索**：任意位置的子串都能命中，1–2 个字的中文短词也能查。
- **搜图片里的文字**：系统内置 OCR 自动识别截图、照片中的中英文。
- **按意思搜图片**：用中文或英文描述画面（「大海」「沙漠里的岩石」「抽象的彩色壁纸」）就能找到图片，不依赖标签。
- **按意思搜文本**：「后端挂了」能找到「服务器报错了，接口返回 500」，中英文互通。
- **相似图片**：在图片详情里列出相似图片，点击即可在列表中定位。
- **打开链接 / 定位文件**：在详情里按住 `⌘`，链接和文件路径变成蓝色，点击即用浏览器打开或在访达中定位。
- **可插拔的模型**：按机器性能选择模型，越好的电脑可用越好的模型；新模型只需写一份清单即可接入。
- **隐私友好**：跳过密码管理器标记为隐藏/临时的内容；可排除指定 App；删除或清空后内容会从数据库文件中抹除；日志不记录剪贴板内容。

## 快速开始

需要 macOS 15.4 或更高版本、Apple Silicon，以及 Xcode Command Line Tools（`xcode-select --install`）。

```sh
git clone https://github.com/xiaoheng008/clipboard.git
cd clipboard
scripts/build-app.sh          # 构建 dist/ClipVault.app
open dist/ClipVault.app       # 启动后出现在菜单栏
```

首次读取剪贴板时，macOS 可能会询问是否允许访问，请选择允许。

## 使用

| 操作 | 方式 |
|---|---|
| 唤出 / 关闭面板 | `⌥ Space`（可在设置中重新录制），或点击菜单栏图标 |
| 选择条目 | `↑` `↓` |
| 复制到剪贴板 | `↩` 或双击，然后在目标 App 里 `⌘V` |
| 删除 / 置顶 | `⌘⌫` / `⌘P`，或右键菜单 |
| 打开链接 / 在访达中定位文件 | 在右侧详情里按住 `⌘`，点击变蓝的链接或路径 |
| 查看相似图片 | 选中图片，详情下方显示相似图片；点击缩略图在列表中定位 |
| 开机自动启动 | 设置 › 通用 › 登录时启动（默认关闭） |
| 设置 | 面板右上角齿轮，或右键菜单栏图标 |

### 启用语义搜索

打开「设置 › 模型」，按推荐下载并启用：

| 用途 | 推荐模型 | 下载大小 | 说明 |
|---|---|---|---|
| 用文字搜图片、相似图片 | SigLIP2 Base | 约 750 MB | Google，Apache-2.0，中英文 |
| 按意思搜文本 | Qwen3 Embedding 0.6B（内存 ≥ 16 GB 推荐） | 约 1.2 GB | 阿里通义，Apache-2.0，中英互搜 |
| 按意思搜文本（轻量） | Granite Embedding 97M | 约 120 MB | IBM，Apache-2.0，中英互搜 |
| 轻量搜图（英文） | MobileCLIP S0 / S2 / B-LT | 100–290 MB | Apple，适合内存较小的机器 |

模型只在点击「下载」时联网获取（显示实时进度，可随时取消），校验 SHA-256 后完全离线运行。启用后，已有的历史会在后台自动建立索引；切换模型时，新模型加载完成前搜索继续使用旧模型。

语义结果的严格程度可以按模型调整：「设置 › 模型」里的「相似度下限」和「与最佳结果最大差距」。调低下限、调大差距，会返回更多「意思相近」的结果。

## 命令行

同一个程序也是命令行工具，便于自检和维护：

```sh
ClipVault=dist/ClipVault.app/Contents/MacOS/ClipVault
$ClipVault --diagnose               # 自检：权限、数据完整性、模型、索引覆盖率
$ClipVault --search "海边的日落"      # 在终端里搜索
$ClipVault --model list             # 查看 / 安装 / 启用模型
$ClipVault --login-item status      # 登录时启动的状态（on / off 开关）
$ClipVault --slow-ops               # 最慢的按钮操作（保留最慢 1000 次，用于性能优化）
$ClipVault --model threshold qwen3-embedding-0.6b@1 --floor 0.45 --margin 0.08   # 调整语义阈值
$ClipVault --help                   # 全部命令
```

数据目录：`~/Library/Application Support/ClipVault`（可用环境变量 `CLIPVAULT_HOME` 指定其他位置）。

## 工作原理

```
复制 ─▶ 剪贴板监听 ─▶ SQLite（条目 + 全文索引 + 后台任务，同一事务）
                         │
                         └─▶ 后台：OCR / 图片向量 / 文本向量
搜索 ─▶ 关键词（trigram + n-gram 索引） ┐
       └▶ 语义（模型实时编码查询 → 向量比对）┴─▶ 融合排序
```

- 图片在复制时提前生成「语义向量」；搜索时只把你的描述实时编码，再与所有图片向量比对（10 万张约 4 ms）。
- 模型、向量索引、OCR、翻译都是可替换的协议实现，详见 `docs/scv/2.1-architecture.md`。

## 更新说明

每个版本改了什么、升级时要注意什么，见 [CHANGELOG.md](CHANGELOG.md)。

## 开发

```sh
scripts/test.sh      # 运行全部测试（Swift Testing）
```

项目按 [scv-app](docs/scv/) 方法开发：需求、架构、数据契约、状态机、验收用例和验证证据分别在 `docs/scv/` 与 `evidence/`。已知限制见 `docs/scv/9.2-known-limitations.md`。

## 许可证

代码采用 [MIT](LICENSE)。模型不随仓库分发，由用户在应用内下载，各自遵循其许可证：SigLIP2（Apache-2.0）、Qwen3 Embedding（Apache-2.0）、Granite Embedding（Apache-2.0）、Multilingual E5（MIT）、MobileCLIP（Apple ASCL）、CLIP 分词器（OpenAI，MIT）。
