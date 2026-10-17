# FR27 迁移演练：真实库副本（2026-10-17）

对象：用户真实库的 `.backup` 副本（72 条：text 47 / image 13 / rich 7 / url 3 / file 2），放在会话临时目录；原库未改动。
本文件只记录数量与结论，不含剪贴板内容。

| 步骤 | 观测 |
|---|---|
| 新版打开 v1 副本 | 自动备份 `clipvault.sqlite.bak-v1`；`schema PASS v2`；`index.kind_markers WARN rebuilding: 72 items left` |
| `--reindex-markers` | 1 批，0.1 s；之后 `index.kind_markers PASS done`、`integrity PASS ok` |
| 旧版（v1）打开迁移后的库 | 拒绝：`Database schema v2 is newer than this app supports (v1)`（防止旧版写入无标记的索引行） |
| 分类搜索一致性 | 5 个标签（全部 / 文本 / 图片 / 文件 / 链接）× 8 个查询（的、the、搜索、http、图、a、了、com）= 40 个用例；比较命中 id 列表：**迁移前（旧版）= 重建中 = 重建后**，40/40 一致（27 个有命中） |
