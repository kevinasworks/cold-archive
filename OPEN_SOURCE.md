# 开源授权与公开范围

Cold Archive 已确认的原创代码采用 **GNU GPL version 3 only**（`GPL-3.0-only`），版权声明为 **Copyright (C) 2026 Kevin Zheng**。许可证完整原文见 `LICENSE`，正文未经修改。原文取得自 GNU gnulib 项目官方镜像的 `doc/COPYINGv3`：
https://github.com/coreutils/gnulib/blob/master/doc/COPYINGv3

原文 SHA-256：`3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`。GNU 主站和 Savannah 在本次获取时连接超时，未以摘要代替全文。

## 适用范围与权属

- `Sources` 中已确认的项目原创 Swift / C 代码、`Tests`、`scripts`、`Package.swift` 使用文件内 `GPL-3.0-only` 标识。
- 原创项目文档、构建配置按 GPL-3.0-only 提供；第三方引文及许可正文保持原有权利。
- `Sources/ColdArchive/Resources/Engine`：用户于 2026-11-06 确认，原技能由其委托 Codex 开发，当前软件在该技能基础上继续开发。按用户指定的 Kevin Zheng 署名及 GPL-3.0-only 授权，已为代码和规格添加标识。
- `Assets` 图标已通过生成器重现、全部缩放 PNG 对比及 ICNS 全部图像块对照确认来源，适用 GPL-3.0-only；详细证据见 `Assets/README.md`。
- `vendor` 的第三方材料保持原有许可证，见 `THIRD_PARTY_NOTICES.md`。GPL 主许可证不替代、撤销或扩大这些授权。

本次授权范围依据用户对自用技能开发来源的确认及其明确指定的原创署名；图标另经逐字节复现核验。未根据第三方文件“没有署名”推定其为公有领域。源码中的第三方引文、原始许可证及构建配方保留各自归属。

## 使用和再分发

个人、企业、学校、科研机构及其他组织均可免费使用和内部修改，无需登记。允许 GPLv3 许可的商业使用和收费再分发；不再适用此前考虑的 SUL 或禁止商业销售方案。

对外再分发时，保留版权、许可和无担保声明；修改版本须按 GPLv3 标明修改及日期。受 GPLv3 约束的作品按其规定提供对应源码。仅内部使用或修改不自动要求向全世界公开源码；提供源码的义务和方式以 GPLv3 第 4–6 条为准。

软件不提供担保，详见 `LICENSE`。使用案例反馈完全自愿，展示组织名称或案例前须取得明确许可。

## 两类检查

`python3 -B scripts/public-source.py` 只检查拟公开文件，检查许可原文、SPDX、明显凭据、预编译程序及源文件权属待办。`--list` 输出拟公开清单；`--output /绝对路径/新目录` 在检查通过后导出源码，不进行网络上传。公开目录不包含 `dist`、构建缓存、预编译运行时、原始数据快照、第三方源码压缩包、历史 QA 日志、本地签名配置或 Research 草稿。检测是有限的自动检查，发布前仍需审阅导出清单和文件内容。

`python3 -B scripts/release-materials.py --mode release` 继续检查完整应用实际分发的许可和对应源码。Siegfried 数据与 MediaInfo 的现存待核事项不因改用 GPL 而消失。它们不无条件阻止未包含这些文件的原创源码公开；反过来，源码检查通过也不代表 `.app` 发行通过。

## 结合方式

Swift 链接 Apple 系统框架及本地 NativeMonitor；NativeMonitor 链接系统 netsnmp。项目通过进程启动 Python，Python 再通过独立进程启动 7zz、FFprobe、MediaInfo、ExifTool/Perl 和 Siegfried。未因进程分离豁免任何随包组件的分发义务。7zz/FFprobe 自身的 LGPL 及其他条款继续适用；其对应源码仍按现有门禁交付。Python 包由解释器导入，各自许可证仍独立保留。当前未确认因本次主许可证变更而新增的链接兼容冲突；原先的数据和 Base64 授权疑点保持待核。

正式接收贡献时，贡献者须有权按项目 GPL-3.0-only 条款提交代码，并保留引入材料的原始声明。无需搭建 CLA 平台。

## 完整应用的项目源码交付

正式应用打包在源码检查通过后，将相同公开清单中的文件放入 `Contents/Resources/CorrespondingSource/ColdArchive`，并逐文件验证集合和内容；第三方对应源码仍按原机制独立交付。若未来出现源码权属待核项，不允许进入正式路径；本地验证包保留明确标记。依赖准备仅在本地获取固定版本输入，不会自动把运行时或发行物加入公开集合。
