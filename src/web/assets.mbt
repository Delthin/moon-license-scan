///|
let page : String =
  #|<!doctype html>
  #|<html lang="en">
  #|<head>
  #|  <meta charset="utf-8">
  #|  <meta name="viewport" content="width=device-width, initial-scale=1">
  #|  <title>License review</title>
  #|  <link rel="stylesheet" href="/app.css">
  #|  <script src="/app.js" defer></script>
  #|</head>
  #|<body>
  #|<main>
  #|  <h1>License review</h1>
  #|  <p>Scan the directory authorized when this server started. Open findings to read the source evidence, then compare against an earlier scan or generate notice candidates for review.</p>
  #|  <details id="scan-options">
  #|    <summary>Scan scope and limits</summary>
  #|    <p><label for="exclude">Excluded path prefixes, one per line. Use paths relative to the authorized directory. Clear the list to exclude nothing.</label></p>
  #|    <textarea id="exclude" rows="3">.git</textarea>
  #|    <p>Leave a limit blank to use the default.</p>
  #|    <div class="actions">
  #|      <label>Bytes per file <input type="number" name="max_file_bytes" min="1" step="1"></label>
  #|      <label>Total bytes <input type="number" name="max_total_bytes" min="1" step="1"></label>
  #|      <label>Entries <input type="number" name="max_entries" min="1" step="1"></label>
  #|      <label>Findings <input type="number" name="max_findings" min="1" step="1"></label>
  #|    </div>
  #|  </details>
  #|  <div class="actions">
  #|    <button id="scan" type="button">Scan authorized directory</button>
  #|    <button id="download-report" type="button" disabled>Download scan report</button>
  #|  </div>
  #|  <p id="status" role="status">No directory scan yet.</p>
  #|  <noscript><p>Enable JavaScript to use the local review workbench.</p></noscript>
  #|  <section id="results" aria-labelledby="files-heading" hidden>
  #|    <h2 id="files-heading">File results</h2>
  #|    <p id="scope"></p>
  #|    <p id="coverage"></p>
  #|    <div class="actions">
  #|      <label for="file-filter">File status</label>
  #|      <select id="file-filter">
  #|        <option value="all">All files</option>
  #|        <option value="matched">Evidence found</option>
  #|        <option value="unmatched">No match</option>
  #|        <option value="review">Needs review</option>
  #|        <option value="partial">Partially scanned</option>
  #|        <option value="skipped">Not scanned</option>
  #|      </select>
  #|    </div>
  #|    <ul id="files" class="files"></ul>
  #|    <div class="actions">
  #|      <button id="previous-page" type="button">Previous page</button>
  #|      <span id="file-range" role="status"></span>
  #|      <button id="next-page" type="button">Next page</button>
  #|    </div>
  #|  </section>
  #|  <section id="comparison-section" aria-labelledby="comparison-heading" hidden>
  #|    <h2 id="comparison-heading">Compare with an earlier scan</h2>
  #|    <label for="previous-report">Previous JSON scan report</label>
  #|    <div class="actions">
  #|      <input id="previous-report" type="file" accept=".json,application/json">
  #|      <button id="compare" type="button" disabled>Compare scans</button>
  #|      <button id="download-comparison" type="button" disabled>Download comparison</button>
  #|    </div>
  #|    <div id="comparison"></div>
  #|  </section>
  #|  <section id="notice-section" aria-labelledby="notice-heading" hidden>
  #|    <h2 id="notice-heading">Release notice candidates</h2>
  #|    <p>Use these candidates as a starting point for release review. Check each source and resolve the files flagged for review before publishing.</p>
  #|    <div class="actions">
  #|      <button id="notice" type="button">Generate candidates</button>
  #|      <button id="download-notice" type="button" disabled>Download candidates</button>
  #|    </div>
  #|    <div id="notice-results"></div>
  #|  </section>
  #|</main>
  #|</body>
  #|</html>

///|
let style : String =
  #|:root { color-scheme: light; color: #182624; background: #fff; font: 100%/1.55 system-ui, sans-serif; }
  #|body { margin: 0; }
  #|main { margin: 0 auto; max-width: 68rem; padding: clamp(1rem, 4vw, 3rem); }
  #|h1 { font-size: clamp(2rem, 1.3rem + 3vw, 3.3rem); line-height: 1.15; margin: 0 0 .75rem; }
  #|h2 { font-size: 1.4rem; margin: 0 0 .6rem; }
  #|section { margin: 2rem 0; padding-top: 1.2rem; border-top: 1px solid #bfcac7; }
  #|button, input, select, textarea { font: inherit; }
  #|#exclude { box-sizing: border-box; width: min(100%, 30rem); }
  #|#scan-options input { width: 8rem; }
  #|#scope { overflow-wrap: anywhere; }
  #|button, select { padding: .28rem .65rem; color: inherit; background: #fff; border: 1px solid #627873; border-radius: .25rem; }
  #|#scan:not(:disabled) { background: #164e44; color: #fff; border-color: #164e44; }
  #|button:not(:disabled), summary { cursor: pointer; }
  #|button:disabled { color: #586561; border-color: #bcc6c3; background: #f5f7f6; }
  #|:focus-visible { outline: 3px solid #17695c; outline-offset: 3px; }
  #|.actions { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem .9rem; margin: .65rem 0; }
  #|.files { padding: 0; list-style: none; }
  #|.files > li { border-top: 1px solid #dbe4e2; padding: .6rem 0; }
  #|.file-name { font: 1rem ui-monospace, monospace; }
  #|summary { margin: .3rem 0; }
  #|li, summary, pre { overflow-wrap: anywhere; }
  #|pre { white-space: pre-wrap; padding: .8rem; background: #eff4f2; }
  #|#status { color: #164e44; }
