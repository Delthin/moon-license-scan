# Moon License Scan

[English](https://github.com/Delthin/moon-license-scan/blob/main/README.en.md)

Moon License Scan 用于在发布前复查源码和随包分发的第三方文件。它逐文件找出 SPDX 声明与许可证正文，给出可回查的原文行号，再比较新旧版本，生成带来源的版权与许可声明候选。工具基于 MoonBit `native` 构建，扫描在本机离线完成，无需安装 Python、Node.js 或 ScanCode。可通过 CLI、MoonBit SDK、MCP（Model Context Protocol）或本地 Web 工作台使用。

## 核心功能

- **逐文件识别。** 内置 127 条文本检测规则，覆盖 81 个 SPDX 许可证标识和两个自定义引用：`LicenseRef-scancode-rsa-md4` 与 `LicenseRef-scancode-unicode-mappings`。报告区分正文和片段；无法区分许可证的共有条款会进入待复核项。显式 SPDX 声明按 SPDX License List 3.29.0 的 740 个许可证标识和 86 个例外标识校验，支持 `AND`、`OR`、`WITH` 和括号。未知或无效声明不产生有效证据；弃用标识与未解析的自定义引用会标记复核。
- **原文回查。** 扫描报告记录根目录相对路径、文件 SHA-256、行号和证据元数据，不保存绝对路径或原文。执行 `preview` 时，工具重新核验文件摘要和证据，再返回相应行；源文件改变后须重新扫描。
- **版本比较。** `compare` 比对两份 JSON 快照，列出新增、移除和变化的证据。无法确认扫描覆盖的相关路径单列到 `not_comparable`，避免把因排除、限额或不可读而缺失的证据当成许可证消失。请用同一版本和相同设置扫描两个目录。
- **发布声明候选。** `notice` 提取经核验的许可证正文和版权署名，对相同文本去重，并保留各自的文件和行号。只有片段、找不到完整署名或存在冲突的文件进入 `review`，由发布人员核对。
- **本地扫描边界。** 工具以只读方式在指定目录中扫描普通文件，不跟随符号链接或 Windows 目录联接点。支持 UTF-8 和带 BOM 的 UTF-16 LE/BE，跳过二进制文件，记录无法读取、解码或完整扫描的文件。

## 安装与构建

从 [GitHub Releases](https://github.com/Delthin/moon-license-scan/releases/tag/v1.0.0) 选择 macOS ARM64、Linux x64 或 Windows x64 的 `.tar.gz`，按同页的 `SHA256SUMS` 校验后解压。将解压后的 `bin/` 加入 `PATH`，或直接运行其中的可执行文件。

```sh
# macOS / Linux
./bin/moon-license-scan --version
```

```powershell
# Windows PowerShell
.\bin\moon-license-scan.exe --version
```

从源码构建需要 [MoonBit](https://www.moonbitlang.com/download/) 和平台 C 工具链。CI 使用 `0.10.21+06da1ed44`；在仓库根目录运行：

```sh
moon update
moon check --target native
moon test --target native
moon build --target native --release
```

可执行文件位于 `_build/native/release/build/cmd/moon-license-scan/moon-license-scan.exe`。

## CLI 快速上手

在源码或预编译包根目录运行以下命令；如果没有设置 `PATH`，请改用可执行文件的路径。新版示例新增了一个[未标注 SPDX 的第三方文件](examples/release-after/vendor/example.c)。

```sh
moon-license-scan scan examples/release-after
moon-license-scan scan examples/release-before --json --output before.json
moon-license-scan scan examples/release-after --json --output after.json
moon-license-scan compare before.json after.json
moon-license-scan notice examples/release-after after.json
```

比较结果会列出新增的 BSD-3-Clause 证据（第 4–28 行）。将 `after.json` 中这条记录的 `id` 替换到下方的 `EVIDENCE_ID`，即可回读原文。

```sh
moon-license-scan preview examples/release-after after.json EVIDENCE_ID
```

| 扫描参数 | 用途 | 默认值 |
| --- | --- | --- |
| `--json` | 输出 JSON 报告，供比较、预览和生成声明候选 | 文本摘要 |
| `--output FILE` | 写入新文件，拒绝覆盖 | 标准输出 |
| `--exclude PATH` | 追加相对根目录的排除前缀，可重复指定 | 排除 `.git` |
| `--max-file-bytes N` | 单个文件读取上限 | 2 MiB |
| `--max-total-bytes N` | 一次扫描累计读取上限 | 64 MiB |
| `--max-entries N` | 文件系统条目上限 | 12,000 |
| `--max-findings N` | 证据条数上限 | 4,000 |

`scan` 接受目录或单个文件。它扫描发布目录里的实际内容，因此也会读取未跟踪或被 Git 忽略的普通文件。

## MoonBit SDK

在项目的 `moon.mod` 中添加 [Mooncakes SDK 0.1.0](https://mooncakes.io/docs/Delthin/moon_license_scan@0.1.0) 依赖，在调用包的 `moon.pkg` 中导入扫描器，再在项目根目录运行 `moon update`。将 `path/to/release` 换成要扫描的目录。示例入口位于项目根目录时，用 `moon run --target native .` 运行；若入口位于 `src/`，把 `.` 换成 `src`。CLI 发行版 `v1.0.0` 和 Mooncakes SDK `0.1.0` 是各自发布渠道的版本。

```moonbit
// moon.mod
import { "Delthin/moon_license_scan@0.1.0" }
```

```moonbit
// moon.pkg
import { "Delthin/moon_license_scan" @scan }
pkgtype(kind: "executable")
```

```moonbit
fn main {
  let report = @scan.Scanner::new().scan("path/to/release") catch {
    err => abort("scan failed: \{err}")
  }
  for file in report.files {
    for hit in file.findings {
      println("\{file.path}:\{hit.start_line}-\{hit.end_line} \{hit.expression}")
    }
  }
}
```

可以复用 `Scanner`，或用 `Session::open` 固定扫描目录、保留当前报告，完成预览、比较和声明导出后调用 `close`。完整接口见[公开 API](src/pkg.generated.mbti)。如需从本地源码包导入，请下载 GitHub Release 中的 `Delthin-moon_license_scan-1.0.0.zip`，依赖版本改用 `1.0.0`，在调用项目和解压目录的共同父目录运行 `moon work init my-app moon-license-sdk`，将两个参数替换为实际目录名。

## MCP 服务端

在支持 MCP 的客户端中登记下列本地标准输入输出命令，目录参数替换为要扫描的绝对路径。服务支持 `2025-11-25` 和 `2025-06-18` 两个协议版本，所有操作都以启动目录为边界。

```sh
moon-license-scan mcp /path/to/release
```

| 工具 | 用途 |
| --- | --- |
| `license_scan` | 扫描启动目录，返回第一页，可传 `options` |
| `license_report` | 用 `next_offset` 作为 `offset` 读取下一页，`limit` 为 1–50 |
| `license_preview` | 用 64 个十六进制字符组成的证据 `id` 回读原文 |
| `license_compare` | 用 `previous` 传入上一个版本的完整报告对象 |
| `license_notice` | 导出当前快照的声明候选与待复核项 |

## 本地 Web 复核工作台

```sh
moon-license-scan serve examples/release-after --port 0
```

打开终端打印的 `127.0.0.1` 地址。通过 **Scan scope and limits** 设置排除前缀和限额，再点击 **Scan authorized directory**；可以筛选文件、展开证据、导入旧报告比较并下载 JSON。端口 `0` 会自动选择可用端口；更换扫描目录时重启服务。

HTTP 客户端向同一地址以 `application/json` 发送 POST。扫描响应带有 `X-Scan-Revision`，将它作为后续请求的同名请求头，可避免另一客户端重扫后误用新快照；收到 `409 Conflict` 时先重扫。

| 路径 | 请求体 |
| --- | --- |
| `/api/scan` | `{}` 或 `{"options":{"exclude":[".git","vendor/unused"]}}`；显式 `exclude` 替换默认列表 |
| `/api/preview` | `{"id":"EVIDENCE_ID"}` |
| `/api/compare` | `{"previous":{...}}`，传入旧版完整报告对象 |
| `/api/notice` | `{}` |

## 规则来源与许可证

本项目代码使用 [Apache-2.0](LICENSE)。文本规则选自 [ScanCode Toolkit v32.5.0](https://github.com/aboutcode-org/scancode-toolkit/tree/v32.5.0) 的 CC BY 4.0 规则数据；SPDX 标识和弃用标记来自采用 Apache-2.0 许可的 [EmbarkStudios/spdx 0.13.6](https://github.com/EmbarkStudios/spdx/blob/0ca398c29698ee46c9d2497569817aebde53feaf/src/identifiers.rs)。规则覆盖、生成方式和归因见[规则说明](docs/rules.md)、[规则来源清单](rule-sources/selection.tsv)、[SPDX 数据来源](spdx-sources/README.md)及 [NOTICE](NOTICE)。
