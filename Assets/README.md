# 项目图标

Copyright (C) 2026 Kevin Zheng
SPDX-License-Identifier: GPL-3.0-only

本目录的项目图标是 `scripts/make-icon.swift` 绘制的原创矢量几何图案的输出，按项目 GPL-3.0-only 提供，不包含第三方图片或字体素材。

来源核验：运行生成器得到的 `icon-1024.png` 与当前文件逐字节一致（SHA-256 `aedb689cdf034b6980fbcb86133c9868812052305c4deb73daa5afa79eff440b`）；依当前 PNG 像素尺寸以系统 sips 缩放，10 个 iconset PNG 均逐字节一致。解析 `ColdArchive.icns`，其中全部 7 个 ICNS 图像块均逐字节匹配这些 PNG，没有额外图像数据。

系统 iconutil 的重打包在当前环境报 Invalid Iconset；该限制不影响上述逐块来源核验，本次未修改任何图像。
