# 语义搜索真实数据判读（铁律 25，2026-10-17）

数据：14 张图（系统壁纸缩略图 10 张 + 渲染文字图 4 张）、14 条中英文文本。原始分数见同目录 `semantic-siglip2-raw.txt`、`semantic-e5-raw.txt`、`semantic-realdata.txt`（MobileCLIP B-LT）。

## SigLIP2 Base（图片槽）
| 查询 | top 结果 | 判定 |
|---|---|---|
| 大海 / the ocean | 海上日落、海上山岛、插画海滩 | ✓ 中英文一致 |
| 日落 | 海上日落 | ✓ |
| 沙漠里的岩石 | 3 张沙漠岩石 | ✓ |
| 抽象的彩色壁纸 | 3 张抽象图 | ✓ |
| 代码截图 / a screenshot of source code | 代码截图 | ✓ |
| 聊天记录 | 发票 0.116 ≈ 聊天截图 0.115 | △ 纯文字截图难分 |
| 猫（无） | 最高 0.067 | ✓ 低于所有相关结果 |

校准：floor 0.09，margin 0.03。

## multilingual-e5-small（文本槽）
| 查询 | 判定 |
|---|---|
| 同语言（会议 / 后端挂了 / 购物 / 护照 / 爬山 / 算法 / 生日 / invoice） | ✓ top-1 正确 |
| 英→中（when is the meeting / server is down / grocery） | ✓ 中英两条都在前 2 |
| 中→英（航班几点起飞 / 怎么做意面） | ✗ 英文目标不在前 3 |
| 量子物理（无） | △ 最高 0.823，与相关结果分差小 |

分数集中在 0.77–0.91，区分度弱。校准：floor 0.84，margin 0.012（偏严格：宁少不错）。
结论：e5-small 可用但中→英弱 → 下一步横向评测 bge-m3 / Qwen3-Embedding。

## 对比：MobileCLIP B-LT（仅英文）
英文查询 top-1 正确；中文查询无翻译时结果错误（见 semantic-realdata.txt）。
