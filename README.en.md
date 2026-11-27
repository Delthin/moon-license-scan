# Moon License Scan

[简体中文](README.md)

Moon License Scan helps release teams review licenses in source trees and bundled third-party files. It locates SPDX declarations and license text with verifiable source line ranges, compares snapshots, and assembles attribution candidates with their sources. It runs offline on the MoonBit `native` target; Python, Node.js, and ScanCode are not required at runtime. Use it through the CLI, MoonBit SDK, MCP (Model Context Protocol), or local web workbench.

## Key features

- **Per-file detection.** The 127 curated text rules cover 81 SPDX license identifiers and two custom references: `LicenseRef-scancode-rsa-md4` and `LicenseRef-scancode-unicode-mappings`. Reports distinguish license text from distinctive fragments and flag shared clauses that need review. Explicit declarations support `AND`, `OR`, `WITH`, and parentheses, and are checked against SPDX License List 3.29.0 (740 license and 86 exception identifiers). Unknown or malformed declarations do not produce valid evidence; deprecated IDs and unresolved custom references are flagged for review.
- **Verified source previews.** Scan reports store root-relative paths, file SHA-256 digests, line ranges, and evidence metadata without retaining absolute host paths or raw source. `preview` checks the file digest and evidence before returning the relevant lines. Rescan when a source file changes.
- **Coverage-aware comparison.** `compare` lists added, removed, and changed evidence. Relevant paths without confirmed coverage appear under `not_comparable`, so exclusions, limits, and unreadable files are not mistaken for removed licenses. Scan both trees with the same tool version and settings.
- **Attribution candidates.** `notice` pairs verified license text with copyright lines, merges identical texts, and retains their source paths and line ranges. Files with incomplete text, missing attribution, or conflicting indications go to `review` for a release reviewer.
- **Read-only local scope.** The scanner reads regular files within the selected root without following symlinks or Windows junctions. It handles UTF-8 and BOM-marked UTF-16 LE/BE, skips binary files, and reports unreadable, undecodable, or incompletely scanned files.

## Installation and build

Download the macOS ARM64, Linux x64, or Windows x64 `.tar.gz` from [GitHub Releases](https://github.com/Delthin/moon-license-scan/releases/tag/v1.0.1). Verify it against `SHA256SUMS` on the same page, extract it, then add `bin/` to `PATH` or invoke the executable directly.

```sh
# macOS / Linux
./bin/moon-license-scan --version
```

```powershell
# Windows PowerShell
.\bin\moon-license-scan.exe --version
```

To build from source, install [MoonBit](https://www.moonbitlang.com/download/) and a platform C toolchain. CI uses MoonBit `1.0.0-rc1+3c0520448`. From the repository root, run:

```sh
moon update
moon check --target native
moon test --target native
moon build --target native --release
```

The executable is written to `_build/native/release/build/cmd/moon-license-scan/moon-license-scan.exe`.

## CLI quick start

Run these commands from the source or extracted release root. If the executable is not on `PATH`, use its path instead. The newer example adds a [third-party file without an SPDX tag](examples/release-after/vendor/example.c).

```sh
moon-license-scan scan examples/release-after
moon-license-scan scan examples/release-before --json --output before.json
moon-license-scan scan examples/release-after --json --output after.json
moon-license-scan compare before.json after.json
moon-license-scan notice examples/release-after after.json
```

The comparison shows an added BSD-3-Clause finding at lines 4–28. Replace `EVIDENCE_ID` with the finding’s `id` from `after.json` to read those lines:

```sh
moon-license-scan preview examples/release-after after.json EVIDENCE_ID
```

| Scan flag | Purpose | Default |
| --- | --- | --- |
| `--json` | Write a JSON report for comparison, preview, or notices | Text summary |
| `--output FILE` | Create a new output file without overwriting an existing one | Standard output |
| `--exclude PATH` | Add a repeatable root-relative exclusion prefix | `.git` excluded |
| `--max-file-bytes N` | Limit bytes read per file | 2 MiB |
| `--max-total-bytes N` | Limit total bytes read per scan | 64 MiB |
| `--max-entries N` | Limit filesystem entries | 12,000 |
| `--max-findings N` | Limit evidence findings | 4,000 |

`scan` accepts a directory or one file. It examines what is present in the release tree, including untracked or Git-ignored regular files.

## MoonBit SDK

Add the [Mooncakes SDK 0.1.1](https://mooncakes.io/docs/Delthin/moon_license_scan@0.1.1) dependency to `moon.mod`, import the scanner in your package’s `moon.pkg`, then run `moon update` from the project root. Replace `path/to/release` with the directory you want to scan. If the entry package is at the root, use `moon run --target native .`; replace `.` with `src` if the entry package is there. The CLI release (`v1.0.1`) and the Mooncakes SDK (`0.1.1`) have separate release versions.

```moonbit
// moon.mod
import { "Delthin/moon_license_scan@0.1.1" }
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

Reuse a `Scanner` across scans, or use `Session::open` to hold the authorized directory and current report for previews, comparisons, and notice exports. Call `close` when done. See the [public API](src/pkg.generated.mbti). To use the local source archive, extract `Delthin-moon_license_scan-1.0.1.zip` from the GitHub Release and declare dependency version `1.0.1`. From the common parent, run `moon work init my-app moon-license-sdk`, substituting the consumer and extracted directory names.

## MCP server

Configure the following local stdio command in an MCP client, replacing the directory with an absolute path. The server supports revisions `2025-11-25` and `2025-06-18` and keeps all operations scoped to that directory.

```sh
moon-license-scan mcp /path/to/release
```

| Tool | Purpose |
| --- | --- |
| `license_scan` | Scan the startup directory and return the first page, with optional `options` |
| `license_report` | Pass `next_offset` as `offset` to read the next page; `limit` is 1–50 |
| `license_preview` | Verify and read source lines for a 64-character hexadecimal evidence `id` |
| `license_compare` | Compare the full `previous` report object against the current snapshot |
| `license_notice` | Export attribution candidates and review items for the current snapshot |

## Local web review workbench

```sh
moon-license-scan serve examples/release-after --port 0
```

Open the `127.0.0.1` address printed in the terminal. Set exclusions and limits under **Scan scope and limits**, then select **Scan authorized directory**. Filter files, open verified evidence, import a prior snapshot, or download JSON results. Port `0` picks an available port; restart the service to change directories.

HTTP clients send JSON with `Content-Type: application/json` as a POST to the same address. Send the scan response’s `X-Scan-Revision` value as a header on follow-up requests to avoid using a snapshot another client just replaced. Rescan if the server returns `409 Conflict`.

| Path | Request body |
| --- | --- |
| `/api/scan` | `{}` or `{"options":{"exclude":[".git","vendor/unused"]}}`; an explicit `exclude` replaces the default list |
| `/api/preview` | `{"id":"EVIDENCE_ID"}` |
| `/api/compare` | `{"previous":{...}}`, with the complete earlier report |
| `/api/notice` | `{}` |

## License and third-party attributions

The source is licensed under [Apache-2.0](LICENSE). Text rules are adapted from the CC BY 4.0 rule data in [ScanCode Toolkit v32.5.0](https://github.com/aboutcode-org/scancode-toolkit/tree/v32.5.0). SPDX identifiers and deprecation flags come from the Apache-2.0-licensed [EmbarkStudios/spdx 0.13.6](https://github.com/EmbarkStudios/spdx/blob/0ca398c29698ee46c9d2497569817aebde53feaf/src/identifiers.rs). See the [rule guide](docs/rules.md), [rule source manifest](rule-sources/selection.tsv), [SPDX data sources](spdx-sources/README.md), and [NOTICE](NOTICE) for coverage, reproduction, and attributions.
