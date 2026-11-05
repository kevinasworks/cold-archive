# 第三方组件与许可证 / Third-Party Licenses

本声明适用于下表所列运行时版本的 Cold Archive Apple Silicon 构建。包内许可证位于
`Contents/Resources/Runtime/Licenses`，源码材料位于
`Contents/Resources/CorrespondingSource`。从源码目录阅读时，许可证位于
`vendor/runtime/Licenses`，原始归档和构建配方见
`vendor/compliance/release-materials.json`。包内 `Runtime/component-manifest.json`
记录了运行时版本和签名后的二进制 SHA-256。

下表的条款适用于各自组件。Cold Archive 已确认原创部分采用 GPL-3.0-only，详见 `LICENSE` 与 `OPEN_SOURCE.md`；引入代码和待确认权属的材料不因项目主许可证改变而被重新授权。
本地验证包可能缺少部分交付材料，其具体缺项见 `vendor/compliance/release-materials.json` 和构建诊断。

| 组件和用途 | 权利人及许可 | 原始许可或声明 |
| --- | --- | --- |
| 7-Zip 26.03，归档压缩、列表与恢复验证 | Igor Pavlov。LGPL 2.1 或后续版本，部分代码适用 BSD 2/3 条款及 unRAR 限制 | `7-Zip.txt`、`7-Zip-LGPL-2.1.txt` 均来自对应 26.03 源码归档 |
| FFprobe / FFmpeg 7.1.1，媒体元数据 | FFmpeg 开发者及文件中列明的权利人。当前 FFprobe 静态构建采用 LGPL 2.1 或后续版本 | `FFmpeg-LGPL-2.1`，对应源码内的 `LICENSE.md` 与各文件声明 |
| CPython 3.13.16，归档脚本解释器及标准库 | Python Software Foundation 及历史权利人。PSF License v2 等 | `Python.txt`、`Runtime/python/lib/python3.13/LICENSE.txt` 和 `CPython-3.13.16-Incorporated-Software.txt` |
| Astral python-build-standalone 20261003 运行时 | CPython 及 OpenSSL 3.5.9、Expat 2.8.5、bzip2 1.0.8、liblzma 5.8.4、SQLite 3.53.1、libffi 3.4.8、mpdecimal 4.0.0、Tcl/Tk 9.0.4、Thread 3.0.6、Itcl 4.3.8 等各自权利人 | `OpenSSL-3.5.9.txt`、`Expat-2.8.5.txt`、`libffi-3.4.8.txt`、`Tcl-9.0.4.txt`、`Tk-9.0.4.txt` 、`Thread-3.0.6.txt`、`Itcl-4.3.8.txt`、`PBS-liblzma.txt`、`PBS-mpdecimal.txt`、`PBS-sqlite.txt` 及 `bzip2.txt`。这些内含库保持各自许可证，不受 Cold Archive 主许可证限制 |
| defusedxml 0.7.1、olefile 0.47、pypdf 6.1.1、ijson 3.4.0.post0 | Christian Heimes（PSF）、Philippe Lagadec 及早期 PIL 权利人（BSD 等）、Mathieu Fenniak 及其他贡献者（BSD-3-Clause）、Ivan Sagalaev 与 Lloyd Hilaiel（BSD-3-Clause 与 ISC） | Python `site-packages` 内各包的 `dist-info` 许可证。ijson 文件含 YAJL 声明 |
| pip 26.2.1，Python 随附包管理工具 | pip 作者及其内含组件作者。MIT、Apache-2.0、BSD、PSF 等，certifi 内 Mozilla 证书数据适用 MPL-2.0 | `pip-26.2.1.dist-info/licenses`、`pip/_vendor` 与 `ensurepip` 内的 wheel。另附 `MPL-2.0.txt` 和 certifi 对应标签源码归档。该归档的 PEM 与安装的 pip 内含副本 SHA-256 一致。生成路径与准确的证书包提交见下文。Mozilla 上游快照的精确修订未确认，作为来源追溯记录，未将该信息单独作为发行阻塞条件 |
| Perl 5.42.0，ExifTool 解释器 | Larry Wall 和其他贡献者（© 1993–2025）。Perl Artistic 或 GPL，部分核心模块和内含代码有独立条款 | `Perl-Artistic`、`Perl-Copying`、`bzip2.txt`。对应材料目录含 CPAN 原始源码与本地构建脚本 |
| ExifTool 13.55、Archive::Zip 1.68，文件及 ZIP 元数据 | Phil Harvey，及 Adam Kennedy、Steve Peters、Ned Konz 等。与 Perl 相同 | `ExifTool-README`、`Archive-Zip-README.md` 和随包脚本及模块 |
| MediaInfo 26.05，媒体容器和流信息 | MediaArea.net SARL（BSD 风格许可）及内含库的各自权利人 | `MediaInfo-26.05.txt`、`MediaInfoLib-26.05.txt`、`MediaInfo.html`、`MediaInfoLib-TinyXML2.txt`、`MediaInfoLib-fmt.txt` 与 `ZenLib.txt`。其余构建内含组件待核 |
| Siegfried 1.11.9 / Go 1.27.1，文件格式识别 | Richard Lehane 及贡献者（Apache-2.0）。Go 运行时及内含 Go 模块分别适用其上游许可证 | `Siegfried.txt`、`go-*.txt` 和 `Siegfried-*.txt`。模块版本及适用材料见下文 |
| PRONOM V125、freedesktop.org、Tika 及其他签名和数据 | 英国国家档案馆、freedesktop.org、Apache Software Foundation 及各数据源权利人 | `freedesktop.org.xml` 许可头及 `GPL-2.0.txt`，`tika-mimetypes.xml` 许可头。派生签名和其余数据的归属及适用材料待核 |

## 对应源码和重建

- **FFprobe 7.1.1** 的目录随包携带完整的官方源码归档和本地构建配方。现有本地源码树中，上游归档的 8,540 个普通文件逐一比较相同。构建使用 Clang，静态纳入 FFmpeg 库，禁用 GPL 和非自由构建选项。将归档解压至项目的 `vendor/src/ffmpeg-7.1.1` 后，按 `build-native-tools.py` 中的 FFmpeg 配置、编译和安装步骤执行。用户可修改 FFmpeg 后重建和重链接 FFprobe，也可为调试这类修改对该工具进行逆向工程。
- **7-Zip 26.03** 的 Homebrew 公式使用官方 `7z2603-src.tar.xz`，从 `CPP/7zip/Bundles/Alone2` 以 `DISABLE_RAR_COMPRESS=1` 构建。包内一同提供该公式及经 Homebrew 公式哈希核验的官方源码，公式未声明补丁。在源码根目录运行 `make -C CPP/7zip/Bundles/Alone2 -f ../../cmpl_mac_arm64.mak DISABLE_RAR_COMPRESS=1`。预置 bottle 的 Mach-O 记录最低系统 15.0。源码 SHA-256 为 `9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4`。
- **Perl 5.42.0** 的目录随包携带 CPAN 原始源码归档与当前构建脚本。配方通过 `Configure -Duserelocatableinc` 构建可重定位解释器。按 Perl Artistic 第 4(b) 项随包交付原始源码及可重定位构建配方。当前配方从经校验的 Perl 5.42.0 归档解包，未施加源代码补丁。

## Siegfried 内含 Go 模块

- Go 1.27.1、golang.org/x/image v0.46.0、x/sys v0.48.0、x/text v0.42.0。The Go Authors，随附 BSD 许可证和 PATENTS 原文。
- match v1.0.5、mscfb v1.0.9、msoleps v1.0.6、webarchive v1.0.3。Richard Lehane 及贡献者，随附对应标签的 Apache-2.0 许可证。
- spargo v0.4.1、wikiprov v1.0.0。Ross Spencer 及贡献者，随附对应标签的 Apache-2.0 许可证。
- xmldetect v1.0.2。Richard Lehane，源码头明确适用 Apache-2.0，全文见 `Siegfried.txt`。
- characterize v1.0.0。实际随包的 `sf` 含 `characterize.ZipName` 和 `characterize.Detect`。上游作者 Richard Lehane 在 [50dd1c9](https://github.com/richardlehane/characterize/commit/50dd1c9bd02efb01cf88b6f5d3624d7e0d598f8c) 以仓库级 Apache-2.0 许可提供该代码。相比 v1.0.0，两个 ZIP 文件名实现的 Git blob 均一致，`characterize.go` 仅增加 Apache 许可头，实际代码一致。再分发依据是作者后来在 Apache-2.0 下提供的相同实现。保留原标签的 Ian F. Darwin BSD 声明及后续快照的 Apache 全文，见 `Siegfried-characterize-Ian-Darwin.txt` 和 `Siegfried-characterize-Apache-2.0.txt`。

## PRONOM V125

`DROID_SignatureFile_V125.xml` 由英国国家档案馆 The National Archives 提供。
随包副本与 [PRONOM 官方签名文件](https://pronom.nationalarchives.gov.uk/signatures/DROID_SignatureFile_V125.xml)
的 SHA-256 一致，值为 `c7c328dd0e131947667e9b94294c5d47e0b6ec8ec3040b7fd542ac605ecc6ec5`。

Contains public sector information licensed under the Open Government Licence v3.0.
[官方签名列表](https://pronom.nationalarchives.gov.uk/signature-list) · [OGL v3.0 原文](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/)

该署名同样适用于下文 PRONOM 报告快照及其在派生签名中的使用。OGL 完整官网原文随包保留为 `Open-Government-Licence-v3.0.html`；OGL 不授予官方背书或未获许可的第三方权利。

## Siegfried 1.11.9 签名数据和生成配方

以下七个 `.sig` 与 Siegfried v1.11.9 标签中的 `cmd/roy/data` 逐文件比较一致。
包内 `CorrespondingSource/Siegfried/siegfried-1.11.9-gen.go` 是该标签的原始生成配方，
以 Apache 2.0 授权。随包的数据目录含各签名使用的输入。

| 签名 | 输入与来源 |
| --- | --- |
| `default.sig` | PRONOM V125、容器签名 `container-signature-20260119.xml` 和 PRONOM 报告 |
| `freedesktop.sig` | `freedesktop.org.xml`（shared-mime-info 2.4，GPL-2.0-or-later） |
| `tika.sig` | `tika-mimetypes.xml`（Tika 3.2.3，Apache-2.0） |
| `loc.sig` | `fddXML.zip`（2025-12-09），配合 PRONOM 输入 |
| `wikidata.sig` | `wikidata/wikidata-definitions-4.0.0`（2026-09-27） |
| `archivematica.sig` | PRONOM 输入与 `custom/archivematica-fmt2.xml` 至 `archivematica-fmt5.xml` |
| `deluxe.sig` | PRONOM、Tika、freedesktop.org、LoC、Wikidata 混合签名 |

独立的 freedesktop.org 和 Tika 签名可以使用 Siegfried 1.11.9 的 `roy` 工具，
以随包 `Runtime/siegfried/data/siegfried` 作为 `-home`，分别执行
`roy build -home "$DATA" -mi freedesktop /tmp/freedesktop.sig` 与
`roy build -home "$DATA" -mi tika /tmp/tika.sig`。
两项命令均生成了可读取的签名。freedesktop.org 的检查输出与预生成文件一致。此前一次 Tika 重建产生 1,916 条字节签名，预生成文件有 1,888 条；后续重复实验确认重建计数本身不稳定，见下文。随包 Tika XML 来自 Siegfried v1.11.9，和 Apache Tika 3.2.3 标签相比，1,682 个 MIME 条目中只有 `application/x-subrip` 有内容变化，涉及两条 CRLF 魔数，另有排版差异。Cold Archive 保留 Siegfried 的文件原样，并随包提供该 Tika 标签的 `Tika-3.2.3-NOTICE.txt`，其中包括 Tika MIME 数据的 PRONOM 归属。
混合签名的输入许可及分发条件仍待核实。 [Siegfried 1.11.9 生成配方](https://github.com/richardlehane/siegfried/blob/v1.11.9/cmd/roy/gen.go)

Perl 随包的 `Compress::Raw::Zlib` 和 `Compress::Raw::Bzip2` 均为 2.213（Paul Marquess），其模块保留原有许可声明。已通过实际解释器确认它们分别内含 zlib 1.3.1（Jean-loup Gailly、Mark Adler）和 bzip2 1.0.8（Julian Seward）。对应原文为 `Perl-zlib-1.3.1.txt` 和 `bzip2.txt`。其他 Perl 核心模块保留安装文件中的原始声明，随包完整源码归档也保留各文件的独立条款。

### Python 包内原始声明

已将 CPython 许可证、pip 的作者与许可目录及 vendored 版本表逐文件与本地 PBS 上游归档核对，也将四个第三方 wheel 的发行元数据许可原文与安装副本核对。发行门禁按哈希检查这些现有文件。pip 的版本表位于 `Runtime/python/lib/python3.13/site-packages/pip/_vendor/vendor.txt`，对应版权与许可文本位于 `pip-26.2.1.dist-info/licenses`。这些校验确认了原始随附材料的保留情况；后续固定标签 NOTICE / 作者表核对及补齐结果见下文。

MediaInfo 26.05 的 arm64 与 x86_64 二进制都含 `fmt::v11` 类型标识；对应 MediaInfoLib 26.05 源码带入 fmt 11.2.1。已附 Victor Zverovich 的原始许可头及其中的可选嵌入例外。二进制也带有 ZenLib 和 TinyXML-2 类型标识。两种架构均通过 macOS 动态链接 zlib，未把它作为 MediaInfo 的静态组件列入。

包内 CPython 3.13.16 的 dylib 含 HACL* 哈希实现及 mimalloc 分配器符号。四个 HACL* 哈希 C 文件使用相同的 MIT 声明，见 `HACL-MIT.txt`。CPython 所带 mimalloc 头文件标记版本 2.1.2，现保留其版权头和上游完整 MIT 文本，见 `mimalloc-CPython-Copyright.txt` 与 `mimalloc-2.1.2-MIT.txt`。

### Wikidata 快照

Siegfried v1.11.9 的 `wikidata-definitions-4.0.0` 包含 Wikidata SPARQL 查询返回的 9,734 条绑定，以及单独的 8,474 项修订溯源记录。结构化数据来自 Wikidata，按其官方政策以 CC0 1.0 提供。此归属适用于结构化数据；溯源中的编辑摘要与另附的自定义 Wikibase 测试样本尚需单独核对。五个 Wikidata 目录文件已与固定标签逐字节比对并纳入哈希门禁。 [Wikidata 许可政策](https://www.wikidata.org/wiki/Wikidata:Licensing) · [CC0 1.0 全文](https://creativecommons.org/publicdomain/zero/1.0/legalcode)

### 美国国会图书馆 FDD 快照

`fddXML.zip` 内含 592 个编号格式描述 XML。内附的 `fddXMLreadme.txt` 将来源指向美国国会图书馆的 Sustainability of Digital Formats 项目。当前 ZIP 与 Siegfried v1.11.9 标签逐字节一致，已纳入发行哈希检查。保留原归档及其声明。 [美国国会图书馆格式项目](https://www.loc.gov/preservation/digital/formats/intro/intro.shtml) · [FDD 官方下载](https://www.loc.gov/preservation/digital/formats/fddXML.zip)

用当前 ZIP 和随包 PRONOM 输入运行 `roy build -home "$DATA" -loc /tmp/loc.sig`，重建文件的 `roy inspect` 输出与预生成签名一致。Siegfried 的解析映射读取格式名称、文件类型标识、关系、日期和参考链接。完整 ZIP 还含长篇说明。此前将 `fdd000504.xml` 等文件中的 “Used with permission” 当作内嵌材料授权限制的依据不充分：该短语实际处于 `usefulReferences` 下的外部链接说明，指向 fabbers.com 的 Marshall Burns 文献，不能由此认定 ZIP 内嵌该文献。美国国会图书馆的一般版权政策要求针对具体内容确定权利；官方 XML 下载页说明了公开取得方式，但未明确覆盖整个历史快照的再分发条款，因此授权范围仍待确认。 [Siegfried FDD 解析映射](https://github.com/richardlehane/siegfried/blob/v1.11.9/pkg/loc/internal/mappings/loc.go) · [美国国会图书馆版权说明](https://www.loc.gov/legal/#copyright)

### certifi 证书包来源

随包安装的 pip 和 `ensurepip` 内的 pip wheel 均带入同一份 `cacert.pem`。两份均与 certifi 更新提交 `d0ac52f3d93a514224197c7efb66c41b1beae5d1` 逐字节一致，包含 118 张证书，SHA-256 为 `bbc7e9c01d7551bb8a159b5dedd989b8ee3ce105aff522b68eb1b01bf854cab0`。

随包 `CorrespondingSource/certifi` 归档含该版本的 PEM、原始 MPL 声明、`Makefile` 和 `strip-non-ascii`。更新工作流执行 `make update`，从 mkcert.org 获取 PEM 后以该脚本转换非 ASCII 字符。mkcert.org 说明其定期从 Mozilla 信任库取得证书并按信任状态筛选。该生成端点会随时间变化，目前未确认本次历史构建对应的 Mozilla `certdata.txt` 精确修订，也未从原始 Mozilla 快照重建这份 PEM。 [certifi 更新提交](https://github.com/certifi/python-certifi/commit/d0ac52f3d93a514224197c7efb66c41b1beae5d1) · [mkcert.org 数据来源](https://mkcert.org/)

### DROID 容器签名 2026-01-19

`container-signature-20260119.xml` 来自英国国家档案馆的 DROID 仓库，容器签名版本为 40。与官方提交 `f5da343c6d309aa149861d49d1cba3c23005703e` 中的对应 XML 比对，唯一字节差异为 CRLF 转 LF。原始声明为 The National Archives © 2016，随附该提交的完整 BSD 三条款许可 `DROID-BSD-3-Clause.txt`。此归属对应容器签名 XML；PRONOM 收集报告和混合签名仍单独核对。 [DROID 原始 XML](https://github.com/digital-preservation/droid/blob/f5da343c6d309aa149861d49d1cba3c23005703e/droid-container/src/main/resources/container-signature-20260119.xml) · [同提交许可](https://github.com/digital-preservation/droid/blob/f5da343c6d309aa149861d49d1cba3c23005703e/LICENSE)

### Archivematica 扩展签名

四份 `custom/archivematica-fmt2.xml` 至 `archivematica-fmt5.xml` 均与 Siegfried v1.11.9 标签逐字节一致，已加入发行哈希清单。上游提交历史显示这些扩展由 Richard Lehane 纳入 Siegfried。XML 使用 DROID 格式和 Archivematica PUID，文件本身未附单独许可，原始素材的权利范围仍待核对。 [Siegfried 扩展签名目录](https://github.com/richardlehane/siegfried/tree/v1.11.9/cmd/roy/data/custom)

按上游配方运行 `roy build -home "$DATA" -name archivematica -extend archivematica-fmt2.xml,archivematica-fmt3.xml,archivematica-fmt4.xml,archivematica-fmt5.xml /tmp/archivematica.sig`，所得文件可读且各类签名计数与随包版本一致。预生成文件的 Details 字段提及 Wikidata，独立重建的同字段报告 PRONOM V125 和容器 XML。已记录差异，未将计数相同视为二进制等同。

### PRONOM 报告快照

随包 `pronom/` 的 2,571 个报告与 Siegfried v1.11.9 上游标签逐文件一致。发行检查在打包前后校验目录摘要，覆盖报告文件名及内容。使用随包数据执行 `roy build -home "$DATA" /tmp/default.sig` 后，重建签名的 `roy inspect` 输出与预生成文件一致。快照与原始服务的历史逐项对应关系未独立重建。授权判断依据 PRONOM 官方 About 页面将逐格式 XML 明列为公开数据获取方式，以及全站 OGL v3 声明；已保留默认署名、许可链接及完整原文。OGL 允许复制、改编及商业或非商业再分发，排除提供方无权授予的第三方权利。历史逐字节在线匹配属于来源追溯验证，未将其单独作为 OGL 合规条件。 [PRONOM 官方数据与许可范围](https://pronom.nationalarchives.gov.uk/about) [Siegfried 报告快照](https://github.com/richardlehane/siegfried/tree/v1.11.9/cmd/roy/data/pronom)

### MediaInfo 26.05 的 ZenLib 与动态依赖

MediaArea 发布的 26.05 CLI 同期完整源码包包含 ZenLib 0.4.41，`CLI_Compile.sh` 将其构建为静态库。源码包 SHA-256 为 `220e54edc92a559cf8c2b4e332eba0116f9f758b2588ea02d432d1894a569c6a`。其中的 ZenLib 许可与本项目已随包提供的 `ZenLib.txt` 逐字节一致。macOS 二进制两种架构都含 ZenLib 类型标识。0.4.41 来自同期官方源码包，Mac 安装包的独立构建记录仍待核。 [MediaArea 26.05 CLI 源码包](https://mediaarea.net/download/binary/mediainfo/26.05/MediaInfo_CLI_26.05_GNU_FromSource.tar.xz)

Mac CLI 含动态查找 `libcurl.4.dylib` 的路径，包内无 libcurl 副本；二进制含 libmms 被编译选项禁用的提示。其余可选静态组件仍须依据 Mac 安装包继续核实。

MediaInfo 26.05 的 arm64 和 x86_64 均含 `aes_modes.c`、`aes_cfb_decrypt` 和 `aes_ofb_crypt` 字符串，与同期源码包中的 Brian Gladman AES 实现对应。该实现要求二进制分发随附版权、条件及免责声明，已从源码保留完整声明，见 `MediaInfoLib-AES-Gladman.txt`。其他同源码包组件仍按实际链接证据核对。

MediaInfo 的 arm64 与 x86_64 二进制均含 SHA-256 轮常量和初始状态，结合同期官方源码所带的 Brian Gladman SHA-2 实现，随包保留 `MediaInfoLib-SHA2-Gladman.txt` 中的版权、条件与免责声明。常量是算法共有数据，二进制分析尚未独立确认 SHA-2 的精确实现，也未据此判定 HMAC、MD5 或其他组件的链接状态。

### 混合签名 deluxe.sig

上游 `makeDeluxe` 依次纳入 PRONOM、Tika、freedesktop.org、LoC 和 Wikidata。已用随包数据测试等价的 CLI 操作顺序：先以 `roy build` 生成 PRONOM 基础签名，再以 `roy add` 依次添加 `-mi tika`、`-mi freedesktop`、`-loc`、`-wikidata -nopronom`。每步均使用同一随包数据目录作为 `-home`，输出使用临时路径。

重建文件包含同样五个标识器。与上游预生成文件相比，`roy inspect` 报告 Tika 的字节签名数分别为 1,897（CLI 重建）和 1,912（预生成），Wikidata 的日期也随重建更新。其余检查字段一致。这验证了输入组合可重建，仍未验证与原预生成文件精确对应。混合文件及其各来源的再分发范围继续作为正式发行待核项，尤其是 freedesktop GPL 数据的对应输入与 LoC 完整快照的授权。

pip 26.2.1 内含 Requests 2.34.2。其现有 Apache 许可与上游固定标签一致，另补入该标签的 `pip-Requests-2.34.2-NOTICE.txt` 原文。CacheControl 0.14.4、distro 1.9.0、msgpack 1.1.2 的内含许可也与各自标签原文一致，所查标签源码归档未见独立 NOTICE。 [Requests 2.34.2 原始 NOTICE](https://github.com/psf/requests/blob/v2.34.2/NOTICE)

pip 内含 Pygments 2.20.0 的许可引用 AUTHORS，现附上固定标签的完整名单 `pip-Pygments-2.20.0-AUTHORS.txt`。Pygments、packaging 26.2、urllib3 2.7.0 和 setuptools 70.3.0 的已携带主许可证均与对应上游标签逐字节一致。`pkg_resources` 目录只含该模块与 LICENSE，其导入已经由 pip 调整到其他内含包；setuptools 源码中的整套开发依赖不据此视为随包内容。pip 带入的 `_internal/utils/_jaraco_text.py` 原样保留了 Jason R. Coombs 的 MIT 许可全文，已与 PBS 原归档比对并纳入运行时检查。

MediaInfo 26.05 同期官方源码中的 tfsxml 使用 MediaArea.net SARL 的 MIT 许可，MD5 实现由 Colin Plumb 于 1993 年编写并明确声明为公有领域。预防性保留两份原始声明，见 `MediaInfoLib-tfsxml-MIT.txt` 与 `MediaInfoLib-MD5-Public-Domain.txt`。目前二进制符号检查未独立确认这两项的链接状态；补齐材料不作为已确认链接或已完成全部静态组件核查的证明。

certifi 交付判断：当前保留上游原样 PEM，并随包提供同版本完整源码归档、生成脚本及 MPL 2.0 文本。依据 MPL 2.0 第 1.13、3.1、3.2 和 3.4 条，需提供适于修改的源码、告知获取方式并保留声明。条款未另行要求证明历史生成服务的逐步可重现性；缺少准确 Mozilla 上游修订在本项目中记录为来源追溯局限，不单独认定为违反 MPL 或发行阻塞。此判断以当前未修改的 certifi 发行文件和已核对的对应标签材料为限，不替代其他 Python/Perl 内含组件的核查。 [MPL 2.0 原文](https://www.mozilla.org/en-US/MPL/2.0/) · [Mozilla 官方 FAQ Q7–Q9](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)

### CPython 内含代码的附加声明

`CPython-3.13.16-Incorporated-Software.txt` 原样保留官方 CPython 3.13.16 源码 `Doc/license.rst`，包括 Mersenne Twister（Makoto Matsumoto、Takuji Nishimura）、SipHash（Marek Majkowski）、dtoa（David M. Gay / Lucent）、cfuhash（Don Owens）、asyncio 内含 uvloop（MagicStack）及 Unicode 数据等版权和许可全文。主 `Python.txt` 不包含这些附加条款，现一并交付。该上游文档也描述其他平台或可选构建代码，其收录不表示所有条目均在本 Mac 二进制中启用；实际使用的更新版 OpenSSL、Expat、libffi、mpdecimal 等仍以各自已附版本原文为准。Perl 随包 `Digest/MD5.pm` 已保留 RSA Data Security, Inc. MD5 Message-Digest Algorithm 的原始声明与派生归属，不用 MediaInfo 的 Colin Plumb MD5 公有领域声明替代。

### Perl 内含 Unicode 数据

Perl 5.42.0 的 `unicore` 派生表标明源自 Unicode Character Database 16.0.0（Unicode, Inc.，2024）；`Unicode/Collate/allkeys.txt` 保留 Unicode 13.0.0 DUCET 的 © 2020 Unicode, Inc. 原始声明。官方现行条款第 2(b)、3(c) 项将 Public 目录中的计算机数据文件列入 Unicode License v3，除文件另有明确许可外适用。现随包提供官网下载的完整 `Unicode-License-v3.txt`（© 1991–2026 Unicode, Inc.），供这些数据及其派生表使用。此许可独立于 Perl Artistic / GPL，Cold Archive 的主许可证不限制其原有权利。原文件中的版本、版权和条款链接原样保留。 [Unicode 条款](https://www.unicode.org/copyright.html) · [完整原文](https://www.unicode.org/license.txt) · [Unicode 16.0.0 原始版本声明](https://www.unicode.org/Public/16.0.0/ucd/ReadMe.txt)

### MediaInfo 内含 HMAC、SHA-1 与 Base64

同期官方源码 `ThirdParty/hmac-gladman` 的 HMAC 和 PBKDF2 文件提供三条件宽松授权，并允许另选 GPL；本交付选择前者，保留各文件不同的完整原始声明于 `MediaInfoLib-HMAC-Gladman.txt`。`ThirdParty/sha1-gladman` 的原文见 `MediaInfoLib-SHA1-Gladman.txt`。这些是对同期源码候选实现的预防性材料保留，精确 Mac 链接范围仍未独立确认，不因 HMAC 的可选 GPL 条款将整套应用标为 GPL。

`ThirdParty/base64/base64.h` 署名 Markus Ewald（2002-05-07），并提及 Bob Withers 的工作，但文件内没有明确许可授予。原署名头保留于 `MediaInfoLib-Base64-Attribution.txt`，该文件不构成授权证明。同期源码在 FLV、Matroska、MPEG-4、Vorbis、XMP、AVC 和通用输出路径中引用该实现；Mac 二进制的精确实现尚未独立证明。正式分发前仍需取得上游可核验的原始授权依据，或确认官方 Mac 二进制采用另一个已有明确授权的实现。不得单凭 MediaInfo 的仓库主许可就假定这份第三方代码已获得同样授权。 [MediaInfoLib 26.05 原始 Base64 头文件](https://github.com/MediaArea/MediaInfoLib/blob/v26.05/Source/ThirdParty/base64/base64.h)

### 签名生成工具源码交付

包内 `CorrespondingSource/Siegfried/siegfried-1.11.9.tar.gz` 现包含固定上游 v1.11.9 的完整源码、`cmd/roy` 工具、生成配方、`go.mod` / `go.sum` 和原始数据快照。归档的七个预生成签名及 `gen.go` 已与当前分发副本逐字节核对。归档哈希纳入打包前后检查，来源固定为上游标签。freedesktop 数据对应的 XML 原样保留于 `Runtime/siegfried/data/siegfried/freedesktop.org.xml` 及源码归档，适用 GPL 2 或后续版本，全文见 `GPL-2.0.txt`。用户可提取源码，使用其固定模块声明构建 `cmd/roy` 后按上文生成命令修改和重建数据。新增工具源码交付不表示 LoC 等其他数据源已获统一授权，也不消除已记录的 Tika 重建计数差异。 [Siegfried v1.11.9 上游发行](https://github.com/richardlehane/siegfried/releases/tag/v1.11.9)

### Tika 重建计数差异的复核

使用同一 `roy 1.11.9`、同一锁定 XML（SHA-256 `5ecf102f75d17f3b90184020f20ebffb2dc1807bf0a45fe2095ad6461531ce7d`）和相同 `roy build -home "$DATA" -mi tika` 参数，三个独立进程分别产生 1,939、1,890、1,927 条字节签名，文件名 / MIME / XML / 文本签名数均分别为 1,339 / 1,830 / 82 / 99。XML 有 1,693 个条目、1,682 个唯一 MIME 类型。上游 `pkg/mimeinfo/mimeinfo.go` 的 `newMIMEInfo` 在存在重复项时以 Go map 遍历结果重建条目切片，再顺序继承父类型的 Magic；合理推断这种顺序不稳定造成了计数差异。该推断尚未通过修改上游算法验证，本项目未进行此类修改。

因此，不把单次重建计数差异独立视为源码交付不完整的证据，也不承诺逐字节可重现。Tika 使用的实际 XML、原始许可头、对应 NOTICE 及完整生成工具源码已经保留。freedesktop 的 GPL 全文、原始 XML、生成工具及配方也已交付。这两项与尚未确定授权的 LoC 等材料分别判断；混合签名的整体分发仍受其余输入授权待办限制。

### Python 分发文件与修改范围复核

将本地 PBS 20261003 原始归档的全部普通文件与 `vendor/runtime/python` 对照：1,643 个文件逐字节相同，无缺失；只有 encodings 的三个 `.pyc` 缓存不同，打包脚本排除所有 `__pycache__` / `.pyc`。本次未修改 CPython 源码或标准库；运行时打包复制现有发行树并对 Mach-O 重新签名。四个额外包与原始 wheel 对照：defusedxml 15、pypdf 60、ijson 20、olefile 27 个文件一致，无代码差异或缺失。

pip 与 `ensurepip` 所带同版本 wheel 对照，469 个文件一致；6 个 distlib Windows PE 启动器不一致，文件长度相同，部分差异涉及填充字节及 PE 元数据。未将这些观察推断为完整二进制等价，也未确认差异由哪个上游处理步骤产生。当前原样保留这些启动器及 distlib 许可，不因 Mac 不执行它们而把它们排除出实际分发范围。Perl 构建配方仅按原始源码配置可重定位路径并编译，交付完整源码及原始许可；打包时移除生成的 `.packlist`，未修改模块代码。

### pip Windows 启动器来源确认

上文六个 distlib PE 启动器已逐一与 PBS 20261003 原始 `python.tar.gz` 内的相同路径比较，全部逐字节一致。它们是 PBS 随附运行时的原始分发内容，并非本项目改写后的副本；现将六项哈希加入打包前后检查。PBS 副本与 pip 官方 wheel / Git 标签中的相应文件存在差异，具体上游处理步骤未确认，保留该事实，不将其误写为本项目修改或来源不明。distlib 0.4.2 的完整原始许可已在 pip 许可目录中保留；不因这些文件在 macOS 上不执行而免除保留声明的义务。本项来源追溯已收敛，未据此证明其余未审查代码均合规。 [PBS 固定运行时发行](https://github.com/astral-sh/python-build-standalone/releases/tag/20261003) · [pip 26.2.1 官方元数据](https://pypi.org/pypi/pip/26.2.1/json)

LoC 许可核查范围说明：已复查 `fdd000504.xml`、`fdd000505.xml`、`fdd000506.xml` 中全部 “Used with permission” 上下文，均为外部文献链接说明。现不以该短语作为已发现第三方受限内容的证据。官方 XML 页面确认 FDD 是该项目的 XML 主文档，并公开整包及逐份下载；“可下载”本身未被当作完整再分发授权。后续需确认的是 FDD 快照本身的权利范围，不是取得该外部文献的转载许可。 [官方 XML 说明](https://www.loc.gov/preservation/digital/formats/fdd/fdd_xml_info.shtml)

### Wikidata 修订溯源的实际使用

固定源码 `pkg/wikidata/wikidata_process_records.go` 的 `getProvenance` 将完整溯源记录转为字符串，并由 `newRecord` 写入 `RevisionHistory`；签名记录处理再持久化这些字段。因而不能只删除原始 JSON 中的历史记录，就假定预生成 Wikidata / deluxe 签名也不再涉及这些文本。当前保持文件和功能原样。官方政策明确结构化数据适用 CC0、其他命名空间文本适用 CC BY-SA，但未在已核对页面中明确界定此类编辑摘要的范围。待核项为这些摘要的许可及必要署名方式，不是结构化识别数据本身的 CC0 授权。 [Wikidata 官方版权政策](https://www.wikidata.org/wiki/Wikidata:Copyright) · [固定版本溯源处理源码](https://github.com/richardlehane/siegfried/blob/v1.11.9/pkg/wikidata/wikidata_process_records.go)

### Python / Perl 已识别缺项的处理状态

CPython/PBS 的原始运行时文件、五个 Python 发行包的原始声明、pip 内含版本表、已识别的独立 NOTICE / 作者表、certifi 对应源码和 MPL 文本均已保留并受打包检查。已识别的原生内含库及 CPython 附加声明见组件表和原文目录。Perl 原始归档中的 6,802 个普通文件与本地源码树逐一比较一致，无变更或缺失；完整原始源码随包交付，包含核心模块和 C 实现各自的版权条款，并保留安装模块中的声明。当前未剩余一项已识别、尚未处理的 Python / Perl 许可材料缺项，故移除“继续复核其余内含代码”的笼统发行阻塞。

此状态仅对应本声明锁定版本、现有原始材料及已实施的文件核对，不表示已经独立重建 PBS 全部依赖或逐项验证上游内部构建日志。未把这些来源追溯局限本身当作许可证强制条件；若未来更新组件或发现具体新缺项，必须据该版本重新判断，不能沿用此结论。

## GPL 源码公开准备与第三方构建材料

项目原创代码的现行授权为 GPL-3.0-only，历史“主许可证待定”或 SUL 设想不作为现行条款。适用范围和权属来源见 `OPEN_SOURCE.md`。第三方源码、许可、数据和构建配方仍按各自条款使用；本文件不对它们重新授权。公开的 Homebrew 7-Zip 配方保留原文，并随附 Homebrew 仓库 BSD 二条款原文 `Homebrew-BSD-2-Clause.txt`；Siegfried `gen.go` 保留其 Apache-2.0 头。完整运行时的现存待核事项继续由应用发行门禁拦截，不自动扩展到未包含这些内容的源码集合。
