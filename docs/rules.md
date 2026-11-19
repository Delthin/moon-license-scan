# 离线许可证规则

Moon License Scan 内置 127 条文本检测规则，覆盖 81 个 SPDX 许可证标识符和两个自定义许可证引用。扫描时直接使用内置规则，无须联网，也不需要安装 ScanCode。文件中显式声明的 SPDX 表达式由独立的 SPDX 目录和语法校验处理，其识别范围不受文本规则限制。

## 规则覆盖范围

| 许可证族 | 有文本规则的 SPDX 标识符 |
| --- | --- |
| MIT、BSD 与常见宽松许可证 | `MIT`、`MIT-0`、`0BSD`、`BSD-1-Clause`、`BSD-2-Clause`、`BSD-2-Clause-Patent`、`BSD-3-Clause`、`BSD-4-Clause`、`ISC`、`Zlib`、`BSL-1.0`、`Apache-1.1`、`Apache-2.0`、`UPL-1.0`、`BlueOak-1.0.0`、`MS-PL` |
| GNU | `GPL-1.0-only`、`GPL-1.0-or-later`、`GPL-2.0-only`、`GPL-2.0-or-later`、`GPL-3.0-only`、`GPL-3.0-or-later`、`LGPL-2.0-only`、`LGPL-2.0-or-later`、`LGPL-2.1-only`、`LGPL-2.1-or-later`、`LGPL-3.0-only`、`LGPL-3.0-or-later`、`AGPL-3.0-only`、`AGPL-3.0-or-later` |
| Mozilla、Eclipse 等软件许可证 | `MPL-1.1`、`MPL-2.0`、`EPL-1.0`、`EPL-2.0`、`CDDL-1.0`、`CDDL-1.1`、`EUPL-1.1`、`EUPL-1.2`、`AFL-3.0`、`OSL-3.0`、`MS-RL`、`Artistic-2.0`、`MulanPSL-2.0`、`Sleepycat`、`ZPL-2.1` |
| 公共领域专用声明与 Creative Commons | `Unlicense`、`CC0-1.0`、`CC-BY-4.0`、`CC-BY-NC-4.0`、`CC-BY-NC-ND-4.0`、`CC-BY-NC-SA-4.0`、`CC-BY-ND-4.0`、`CC-BY-SA-4.0` |
| 字体、文档与开放硬件 | `OFL-1.1`、`FTL`、`W3C`、`W3C-20150513`、`CERN-OHL-P-2.0`、`CERN-OHL-S-2.0`、`CERN-OHL-W-2.0` |
| 软件库与其他许可证 | `curl`、`PostgreSQL`、`X11`、`ICU`、`Unicode-3.0`、`Unicode-DFS-2015`、`Unicode-DFS-2016`、`Libpng`、`libpng-2.0`、`libtiff`、`IJG`、`NCSA`、`OpenSSL-standalone`、`SSLeay-standalone`、`OLDAP-2.8`、`PSF-2.0`、`JSON`、`SGI-B-2.0`、`WTFPL`、`Fair`、`Beerware` |

RSA MD4 和 Unicode 映射条款分别使用上游定义的 `LicenseRef-scancode-rsa-md4` 和 `LicenseRef-scancode-unicode-mappings`。语料还识别一类明确将二者交由接收者任选的通知，输出 `Apache-2.0 OR MIT`。三条 PCRE 规则分别匹配 Cambridge 源码文件头、同时列出 Cambridge 和 Google 的许可证正文，以及 CMake 脚本使用的作者版本，均输出 `BSD-3-Clause`。

## 匹配与复核

扫描器提取连续的 ASCII 字母和数字词元并按原顺序比较，忽略大小写、标点与词与词之间的换行。`text` 表示匹配主要授权条款，`fragment` 表示匹配有区分度的片段或文件头。以 CC0 为例，扫描器利用权利放弃和备用授权条款识别正文，通用免责声明不构成许可证证据。明确写出适用 MIT 或 Boost 1.0 的许可通知作为片段报告；其中的文件名或网址不会引入目标的授权文本。完整的 CC BY 4.0 正文不包含 Creative Commons 对许可证文本自身的公共领域声明。

GNU 条款正文与项目采用声明分别记录。例如，标准 GPL v2 正文按文本版本记录为 `GPL-2.0-only`；要判断项目是否允许后续版本，需查看明确写出版本选择的项目声明，协议附录中带占位符的示例不算声明。如果只找到 BSD 的共同分发条款、没有匹配到可区分版本的内容，扫描器会标记复核。同一文件的 SPDX 声明和实际条款指向不同许可证时，报告保留两份证据供复核。

报告会给出命中的规则 ID 和文件行范围。通过规则 ID 可在[规则清单](../rule-sources/selection.tsv)查到来源；导出通知时使用扫描对象中的文本和归属信息，内置规则片段不会替代项目的版权或许可声明。

## 来源与复现

[规则清单](../rule-sources/selection.tsv)逐条记录规则 ID、SPDX 表达式、上游文件、原文行范围、完整上游文件的 SHA-256 和选段理由。上游路径以 [ScanCode Toolkit v32.5.0 的许可证与规则目录](https://github.com/aboutcode-org/scancode-toolkit/tree/abd87fb81609ea4a29ab4cdda755c188b8be3601/src/licensedcode/data)为基准。[生成器](https://github.com/Delthin/moon-license-scan/blob/v1.0.0/rule-sources/generate.mbtx)核对摘要和行范围，并拒绝规整后词序完全相同的规则。

将 `SCANCODE_CHECKOUT` 指向该提交的本地源码目录，然后在 Moon License Scan 源码根目录运行：

```sh
generated=$(mktemp)
moon run --target native rule-sources/generate.mbtx -- "$SCANCODE_CHECKOUT" rule-sources/selection.tsv > "$generated" &&
  diff -u src/rules/corpus.mbt "$generated"
```

更新选段时，应核对差异，再更新[内置语料](https://github.com/Delthin/moon-license-scan/blob/v1.0.0/src/rules/corpus.mbt)和[语料版本](https://github.com/Delthin/moon-license-scan/blob/v1.0.0/src/rules/rules.mbt)。软件代码使用 [Apache-2.0](../LICENSE)，改编的 ScanCode 规则数据使用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode)，归属及改动说明见 [NOTICE](../NOTICE)。
