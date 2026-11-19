# Offline license rules

Moon License Scan ships with 46 patterns covering 30 SPDX license identifiers. The scanner uses the embedded corpus directly, so it does not fetch rules or run ScanCode during a scan.

## Covered license text and notices

| Family | SPDX identifiers with corpus rules |
| --- | --- |
| MIT, BSD and related permissive licenses | `MIT`, `0BSD`, `BSD-2-Clause`, `BSD-3-Clause`, `BSD-4-Clause`, `ISC`, `Zlib`, `BSL-1.0` |
| Apache | `Apache-1.1`, `Apache-2.0` |
| Mozilla and Eclipse | `MPL-1.1`, `MPL-2.0`, `EPL-1.0`, `EPL-2.0` |
| GNU GPL | `GPL-1.0-only`, `GPL-1.0-or-later`, `GPL-2.0-only`, `GPL-2.0-or-later`, `GPL-3.0-only`, `GPL-3.0-or-later` |
| GNU LGPL | `LGPL-2.0-only`, `LGPL-2.0-or-later`, `LGPL-2.1-only`, `LGPL-2.1-or-later`, `LGPL-3.0-only`, `LGPL-3.0-or-later` |
| GNU AGPL | `AGPL-3.0-only`, `AGPL-3.0-or-later` |
| Public domain dedications | `Unlicense`, `CC0-1.0` |

The scanner matches a rule when its normalized words occur together in the target file, in their original order. Matching ignores case, punctuation and line wrapping, but keeps digits, including the ones in numbered BSD clauses. Explicit SPDX declarations are reported separately from matching rules.

A `text` rule covers the operative license terms, such as the MIT permission grant and disclaimer. A `fragment` rule identifies a distinctive excerpt, such as the MPL 2.0 source header or a GNU clause that says which version applies. GNU rules use an explicit version and version policy; an unversioned header or a copy of the GNU license agreement alone cannot determine the author's `-only` or `-or-later` choice. The shared BSD redistribution clauses lead to manual review when the scanner cannot find the terms that distinguish a variant.

Reports identify the rule and the lines that matched. Review the original lines when wording, added terms or multiple indications matter. Notice export uses verified source text and keeps evidence without complete terms or the required attribution for review; the embedded patterns supply no substitute copyright or license notice.

## Provenance and rebuilding

[The selection manifest](../rule-sources/selection.tsv) records each local rule ID, SPDX label, upstream path, original line range, SHA-256 of the complete upstream file, and the reason for selecting those lines. The paths are relative to ScanCode's `src/licensedcode/data/` directory at [ScanCode Toolkit v32.5.0, commit `abd87fb81609ea4a29ab4cdda755c188b8be3601`](https://github.com/aboutcode-org/scancode-toolkit/tree/abd87fb81609ea4a29ab4cdda755c188b8be3601/src/licensedcode/data). The generator checks the hashes before embedding each excerpt. It strips trailing whitespace, preserves the text and line order, and records a low-frequency adjacent word pair to narrow the candidates during scanning.

To regenerate the corpus, use a Moon License Scan source checkout. From its root, point `SCANCODE_CHECKOUT` at a local ScanCode checkout or extracted source tree for that commit. Regenerate to a temporary file and compare it with the [embedded corpus](../src/rules/corpus.mbt):

```sh
generated=$(mktemp)
moon run --target native rule-sources/generate.mbtx -- "$SCANCODE_CHECKOUT" rule-sources/selection.tsv > "$generated" &&
  diff -u src/rules/corpus.mbt "$generated"
```

When updating the rule selection, replace the embedded corpus with the verified output and update the corpus version in [the rules package](../src/rules/rules.mbt) so reports identify the new selection.

Moon License Scan software is licensed under [Apache-2.0](../LICENSE). The adapted ScanCode rule data is licensed separately under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode); see [NOTICE](../NOTICE) for attribution and changes.
