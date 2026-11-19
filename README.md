# moon-license-scan

`moon-license-scan` 用于发布前复查源码目录中的许可证。它会逐文件识别 SPDX 声明、已覆盖的许可证正文和特征片段，给出文件、原始行号和规则；即使第三方源码没有 SPDX 标签，也能从匹配到的正文找到许可依据。扫描在本机离线完成，使用 MoonBit native 实现，运行时无需安装 Python 或 Node.js。

## 核心功能

- **逐文件取证**：分别报告显式声明和文本命中。打开证据时重新核对文件内容，确保看到的是扫描时对应的原文。
- **比较两个发布版本**：读取两份 JSON 报告，列出新增、移除和变化的证据；如果有未扫描文件或比较范围不同，也会标出缺口。
- **生成发布声明候选**：从当前版本中提取经核对的许可证原文和版权署名，保留来源路径和行号，并单列待人工复核的条目。

## 安装

### 使用预编译包

从 [GitHub Actions「Native builds」](https://github.com/Delthin/moon-license-scan/actions/workflows/native.yml) 打开一次成功运行，下载对应平台的产物：`moon-license-scan-macos-arm64`、`moon-license-scan-linux-x64` 或 `moon-license-scan-windows-x64`。用附带的 `.sha256` 文件校验 `.tar.gz`，解压后将其中的 `bin/` 加入 `PATH`，或在解压目录直接运行。用 `--version` 确认安装的是 1.0.0：

```sh
# macOS / Linux
./bin/moon-license-scan scan examples/release-after
```

```powershell
# Windows PowerShell
.\bin\moon-license-scan.exe scan examples/release-after
```

### 从源码运行

源码构建需要 [MoonBit](https://www.moonbitlang.com/download/)（CI 使用 `0.10.20+65efd5b93`）和平台 C 工具链。在仓库根目录运行：

```sh
moon update
moon run src/cmd/moon-license-scan --target native --release -- scan examples/release-after
```

如需生成可执行文件，运行 `moon build --target native --release`，产物位于 `_build/native/release/build/cmd/moon-license-scan/moon-license-scan.exe`。

## 快速上手：复查两个发布版本

在源码或安装包根目录运行以下命令。如果没有将程序加入 `PATH`，请用可执行文件的实际路径替换命令名。两个示例都采用 MIT 许可；新版新增了一个含 BSD-3-Clause 正文、没有 SPDX 标签的[第三方源码文件](examples/release-after/vendor/example.c)。

```sh
moon-license-scan scan examples/release-before --json --output previous.json
moon-license-scan scan examples/release-after --json --output current.json
moon-license-scan compare previous.json current.json
moon-license-scan notice examples/release-after current.json
```

对比会列出新增文件中的 BSD-3-Clause 证据（第 4–28 行）。从当前报告复制该条证据的 `id`，替换下方的 `EVIDENCE_ID`，即可查看原文。如果源文件已修改，先重新扫描再回查。

```sh
moon-license-scan preview examples/release-after current.json EVIDENCE_ID
```

`scan` 支持单个文件，也可不加 `--json`，直接在终端查看结果。`--exclude vendor/unused` 排除相对扫描根的路径及其子项，可重复传入。扫描默认排除 `.git`，但仍读取未跟踪及被 Git 忽略的普通文件。用同一工具版本、排除项和限额扫描两个发布目录，有助于区分实际变化和覆盖范围差异。`--output` 只创建新文件；更多扫描选项见 `--help`。

## 浏览器工作台、HTTP 与 MCP

```sh
moon-license-scan serve examples/release-after
```

打开命令打印的本机地址。在 **Scan scope and limits** 中可以设置排除项和扫描上限，然后点击 **Scan authorized directory**。打开命中记录可核对原文，导入上一个版本的 JSON 报告可生成对比，也可下载发布声明候选。工作台只在本机监听；要换扫描目录，请用新的路径重新启动。

HTTP 客户端使用命令打印的地址，以 `application/json` 发送 POST 并接收 JSON。扫描设置可通过 `options` 传入，例如 `{"options":{"exclude":[".git","vendor/unused"],"max_total_bytes":1048576}}`。显式提供的 `exclude` 会替换默认列表。`/api/scan` 响应中的 `X-Scan-Revision` 标识当前快照；后续请求带上同名请求头，可防止另一个客户端重新扫描后误用其报告。快照已切换时，服务返回 `409 Conflict`，客户端可重新扫描后再操作。

| 路径 | 请求体 |
| --- | --- |
| `/api/scan` | `{}`，或传入 `options` |
| `/api/preview` | `{"id":"EVIDENCE_ID"}`，使用当前报告中的证据 ID |
| `/api/compare` | `{"previous":{...}}`，放入上一个版本的完整报告对象 |
| `/api/notice` | `{}`，基于当前报告生成候选 |

在 MCP 客户端中添加本地 stdio 服务：命令填写 `moon-license-scan`，参数填写 `["mcp", "/absolute/path/to/release"]`。所有工具都使用启动时指定的目录。`license_scan` 返回第一页；如有 `next_offset`，传给 `license_report` 继续读取。用 `license_preview` 回查当前证据，用 `license_compare` 导入旧报告对象，用 `license_notice` 生成声明候选。协议版本支持 `2025-11-25` 和 `2025-06-18`。

## MoonBit SDK

从同一个 [Actions 工作流](https://github.com/Delthin/moon-license-scan/actions/workflows/native.yml) 下载 `moon-license-scan-sdk`，将源码 ZIP 解压到调用项目旁边。按解包后的模块版本在项目的 `moon.mod` 中声明依赖（例如 `import { "Delthin/moon_license_scan@1.0.0" }`）。在共同的上一级目录运行 `moon work init my-app moon-license-sdk`，其中两个参数替换成实际目录名；然后在调用包的 `moon.pkg` 中导入 `"Delthin/moon_license_scan" @scan`，并用 `--target native` 构建。

```moonbit
fn scan_release(root : String) -> @scan.Report raise {
  let scanner = @scan.Scanner::new()
  scanner.scan(root)
}
```

`Scanner` 可复用，也提供 `preview` 和 `notice`。用 `parse_report` 校验保存的 JSON，再用 `compare` 对比两份报告。需要固定只读扫描根并在多次操作间保留最新报告时，使用 `Session`，用完后调用 `close`。完整接口见[公开 API](src/pkg.generated.mbti)。

## 扫描范围、来源与许可

- **扫描边界**：只读扫描普通文件，支持 UTF-8 和带 BOM 的 UTF-16，不跟随符号链接。超限、不可读、无法解码的文件会标明原因。比较旧版本时，请用同一版工具重扫两个目录，以免把规则更新误判为许可变化。
- **证据复核**：正文和片段覆盖范围见[规则说明](docs/rules.md)。缺少文本证据时，请查看源文件或上游许可文件；只有片段、声明冲突或缺少署名时，工具会提示待核对。
- **SPDX 声明**：使用 SPDX License List 3.29.0 检查许可证和例外标识。未知标识不会作为有效声明；已弃用标识和项目自定义的 `LicenseRef` 会保留在报告中，并标记待核对。
- **来源与许可**：本软件采用 [Apache-2.0](LICENSE)。正文和片段选自 [ScanCode Toolkit v32.5.0](https://github.com/aboutcode-org/scancode-toolkit/tree/v32.5.0)，按 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 授权。对应选段见[规则来源清单](rule-sources/selection.tsv)，标识数据见 [SPDX 数据来源](spdx-sources/README.md)，署名见[许可声明](NOTICE)。
