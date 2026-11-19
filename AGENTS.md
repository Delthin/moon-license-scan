# Product conventions

- Keep license matching, reporting and evidence review in the MoonBit library; commands and clients share that library.
- Protect local reads at the filesystem boundary. Never trust input paths, imported report contents, or text used in a browser.
- Preserve upstream notices and per-rule provenance when changing the rule corpus.
- Use native builds and tests for filesystem and transport behavior. Use MoonBit script mode for automation.
