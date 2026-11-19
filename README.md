# moon-license-scan

Scan a local release directory for license evidence. The scanner detects explicit SPDX identifiers, selected full license texts, and distinctive notices in ordinary text files. Each result gives the file, matching lines, rule, and a stable evidence ID. Use a scan to inspect the source, compare two release trees, or prepare declaration candidates for review.

## Installation

From [Native builds](https://github.com/Delthin/moon-license-scan/actions/workflows/native.yml), open a successful run and download the artifact for your operating system. The download contains a `.tar.gz` and its SHA-256 checksum. Extract the archive, then run the executable in its `bin` directory or add that directory to your `PATH`. On Windows the executable is `moon-license-scan.exe`. Scanning does not require Python, Node.js, or a network connection.

To build from source with [MoonBit](https://www.moonbitlang.com/download/), run `moon build --target native --release`. The compiler places the executable at `_build/native/release/build/cmd/moon-license-scan/moon-license-scan.exe`.

## Scan two release trees

The [example directories](examples/) contain an MIT project; the second directory adds [a vendor source file](examples/release-after/vendor/example.c) whose BSD-3-Clause notice has no SPDX tag. From the directory containing the extracted archive's `examples` directory (or the source checkout), run:

```sh
moon-license-scan scan examples/release-before --json --output previous.json
moon-license-scan scan examples/release-after --json --output current.json
moon-license-scan compare previous.json current.json
moon-license-scan notice examples/release-after current.json
```

Run `moon-license-scan scan examples/release-after` for a text report. To read the original lines, copy an evidence ID from the text or JSON report and pass it to `moon-license-scan preview examples/release-after current.json EVIDENCE_ID`. If the source changes since the scan, scan it again before opening the evidence.

`scan` also accepts a single file. Use `--exclude vendor/unused` to exclude a root-relative path and its descendants. The scanner reads untracked and ignored files; it excludes `.git` by default. Use `--help` for scan limits. A report records skipped and incomplete cases, and `compare` reports gaps where a change cannot be established. Scan both release trees with the same scanner version and exclusions to get comparable reports. `--output` creates a new file without overwriting an existing path.

## Review in a browser

Start `moon-license-scan serve examples/release-after` and open the loopback address printed by the command. Set exclusions and budgets under **Scan scope and limits**, or scan with the defaults. Open a finding to review its original lines, import the previous JSON report, and download the comparison or declaration candidates. The server is read-only and tied to the root selected at startup; restart it to select another root. Keep it on the local machine.

For HTTP automation, send `application/json` POST requests to `/api/scan` with `{}`, `/api/preview` with `{"id":"EVIDENCE_ID"}`, `/api/compare` with `{"previous":{...}}` containing the earlier report, and `/api/notice` with `{}`. To narrow a scan, send `{"options":{"exclude":[".git","vendor/unused"],"max_total_bytes":1048576}}` to `/api/scan`. An explicit `exclude` list replaces the default. Use the exact host and port printed at startup. These endpoints return JSON.

## Use from an MCP client or MoonBit program

Configure a local stdio MCP server with command `moon-license-scan` and arguments `["mcp", "/absolute/path/to/release"]`. `license_scan` returns the first page; use `license_report` with the returned `next_offset` to continue. `license_preview` reads a current evidence ID, `license_compare` accepts a previous report object, and `license_notice` returns candidates. The server uses the startup directory for all tools and supports protocol versions 2025-11-25 and 2025-06-18.

To use the SDK locally, download `moon-license-scan-sdk` from a successful build and extract its source ZIP into a directory beside your project. Declare `Delthin/moon_license_scan` with the extracted module's version in your project's module imports, then run `moon work init my-app moon-license-sdk` from the shared parent (using the actual directory names). Import the package as `@scan` in your `moon.pkg` and build with `--target native`. A reusable `@scan.Scanner::new()` provides `scan`, `preview`, and `notice`. Use `@scan.parse_report` to validate saved reports before calling `@scan.compare`. The `@scan.Session` API pins a read boundary and keeps the latest scan for tools that run repeatedly.

## Scope and licenses

The [rule reference](docs/rules.md) lists supported rule text variants and SPDX handling. The scanner emits evidence for review: unsupported wording, partial notices, conflicting indications, and incompletely scanned files may require a manual check. Declaration candidates preserve source paths and lines; review the text and attribution before including them in a release.

The [software license](LICENSE) is Apache-2.0. The [notice](NOTICE) attributes the detection rules adapted from ScanCode Toolkit and describes their separate CC BY 4.0 terms.
