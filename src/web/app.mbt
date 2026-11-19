///|
let script : String =
  #|"use strict";
  #|const $ = (id) => document.getElementById(id);
  #|const node = (tag, text) => {
  #|  const element = document.createElement(tag);
  #|  if (text !== undefined) element.textContent = text;
  #|  return element;
  #|};
  #|const list = (values) => {
  #|  const ul = node("ul");
  #|  for (const value of values) ul.append(node("li", value));
  #|  return ul;
  #|};
  #|const disclosure = (label, ...contents) => {
  #|  const details = node("details");
  #|  details.append(node("summary", label), ...contents);
  #|  return details;
  #|};
  #|const readable = (reason) => reason.replaceAll("_", " ");
  #|const reasons = (values) => values.map(readable).join("; ");
  #|let report = null;
  #|let pageIndex = 0;
  #|let busy = false;
  #|const fileInput = $("previous-report");
  #|const PAGE_SIZE = 50;
  #|
  #|async function post(operation, body = "{}") {
  #|  const response = await fetch("/api/" + operation, {
  #|    method: "POST", headers: { "Content-Type": "application/json" }, body,
  #|    mode: "same-origin", redirect: "error", cache: "no-store",
  #|  });
  #|  const raw = await response.text();
  #|  const data = JSON.parse(raw);
  #|  if (!response.ok) throw new Error(data.error);
  #|  return { raw, data };
  #|}
  #|
  #|function download(id, filename, raw) {
  #|  const button = $(id);
  #|  button.disabled = raw === undefined;
  #|  button.onclick = raw === undefined ? null : () => {
  #|    const url = URL.createObjectURL(new Blob([raw], { type: "application/json" }));
  #|    const link = node("a");
  #|    link.href = url;
  #|    link.download = filename;
  #|    document.body.append(link);
  #|    link.click();
  #|    link.remove();
  #|    setTimeout(() => URL.revokeObjectURL(url), 1000);
  #|  };
  #|}
  #|
  #|function syncActions() {
  #|  $("scan").disabled = busy;
  #|  $("notice").disabled = busy;
  #|  fileInput.disabled = busy;
  #|  $("compare").disabled = busy || !fileInput.files.length;
  #|}
  #|
  #|async function run(progress, action) {
  #|  if (busy) return;
  #|  busy = true;
  #|  syncActions();
  #|  $("status").textContent = progress;
  #|  try {
  #|    $("status").textContent = await action();
  #|  } catch (error) {
  #|    $("status").textContent = error.message || "The local server did not respond.";
  #|  } finally {
  #|    busy = false;
  #|    syncActions();
  #|  }
  #|}
  #|
  #|const states = {
  #|  matched: "Evidence found", unmatched: "No match", review: "Needs review",
  #|  partial: "Partially scanned", skipped: "Not scanned",
  #|};
  #|const fileState = (file) => file.status === "scanned"
  #|  ? (file.findings.length ? "matched" : "unmatched") : file.status;
  #|const lines = (finding) => finding.start_line === finding.end_line
  #|  ? "line " + finding.start_line : "lines " + finding.start_line + "–" + finding.end_line;
  #|const evidenceLabel = (finding) => finding.expression + " · " + lines(finding);
  #|
  #|function evidence(finding) {
  #|  const message = node("p");
  #|  message.setAttribute("role", "status");
  #|  const details = disclosure(evidenceLabel(finding) + " · Open evidence", message);
  #|  let pending = false;
  #|  let loaded = false;
  #|  details.addEventListener("toggle", async () => {
  #|    if (!details.open || pending || loaded) return;
  #|    pending = true;
  #|    message.textContent = "Verifying source evidence…";
  #|    try {
  #|      const { data } = await post("preview", JSON.stringify({ id: finding.id }));
  #|      message.textContent = "Verified source, " + lines(data) + ".";
  #|      details.append(node("pre", data.text));
  #|      loaded = true;
  #|    } catch (error) {
  #|      message.textContent = error.message;
  #|    } finally {
  #|      pending = false;
  #|    }
  #|  });
  #|  return details;
  #|}
  #|
  #|function renderFiles() {
  #|  const filter = $("file-filter").value;
  #|  const files = filter === "all" ? report.files : report.files.filter((file) => fileState(file) === filter);
  #|  const start = pageIndex * PAGE_SIZE;
  #|  const shown = files.slice(start, start + PAGE_SIZE);
  #|  const items = shown.map((file) => {
  #|    const path = node("bdi", file.path);
  #|    path.className = "file-name";
  #|    const header = node("div");
  #|    const label = states[fileState(file)] || file.status;
  #|    const reason = reasons(file.reason ? [file.reason, ...file.review] : file.review);
  #|    header.append(path, node("span", " — " + label + (reason ? ": " + reason : "")));
  #|    const item = node("li");
  #|    item.append(header);
  #|    if (file.findings.length) {
  #|      const findings = disclosure(file.findings.length + " findings");
  #|      findings.addEventListener("toggle", () => {
  #|        if (findings.open && findings.childElementCount === 1) findings.append(...file.findings.map(evidence));
  #|      });
  #|      item.append(findings);
  #|    }
  #|    return item;
  #|  });
  #|  $("files").replaceChildren(...items);
  #|  $("file-range").textContent = shown.length
  #|    ? (start + 1) + "–" + (start + shown.length) + " of " + files.length : "No files in this view.";
  #|  $("previous-page").disabled = pageIndex === 0;
  #|  $("next-page").disabled = start + shown.length >= files.length;
  #|}
  #|
  #|function resetComparison() {
  #|  $("comparison").replaceChildren();
  #|  download("download-comparison");
  #|}
  #|
  #|$("scan").onclick = () => run("Scanning the authorized directory…", async () => {
  #|  const options = { exclude: $("exclude").value.split("\n").filter((line) => line !== "") };
  #|  for (const input of document.querySelectorAll("#scan-options input")) {
  #|    if (!input.reportValidity()) throw new Error("Use positive whole numbers for scan limits.");
  #|    if (input.value !== "") options[input.name] = input.valueAsNumber;
  #|  }
  #|  const result = await post("scan", JSON.stringify({ options }));
  #|  report = result.data;
  #|  resetComparison();
  #|  $("notice-results").replaceChildren();
  #|  download("download-notice");
  #|  download("download-report", "license-scan-report.json", result.raw);
  #|  const scope = report.options;
  #|  const excluded = scope.exclude.map((prefix) => JSON.stringify(prefix)).join(", ") || "none";
  #|  $("scope").textContent = "Excluded prefixes: " + excluded + ". Scan limits: " + scope.max_file_bytes
  #|    + " bytes per file, " + scope.max_total_bytes + " total bytes, " + scope.max_entries
  #|    + " entries, and " + scope.max_findings + " findings.";
  #|  const coverage = report.enumeration_complete ? "Directory enumeration completed." : "Directory enumeration is incomplete.";
  #|  $("coverage").textContent = coverage + (report.diagnostics.length ? " " + reasons(report.diagnostics) + "." : "");
  #|  for (const id of ["results", "comparison-section", "notice-section"]) $(id).hidden = false;
  #|  $("file-filter").value = "all";
  #|  pageIndex = 0;
  #|  renderFiles();
  #|  return "Scan returned " + report.files.length + " file records. " + coverage;
  #|});
  #|$("file-filter").onchange = () => { pageIndex = 0; renderFiles(); };
  #|$("previous-page").onclick = () => { pageIndex--; renderFiles(); };
  #|$("next-page").onclick = () => { pageIndex++; renderFiles(); };
  #|fileInput.onchange = () => { resetComparison(); syncActions(); };
  #|
  #|$("compare").onclick = () => run("Comparing the selected report…", async () => {
  #|  resetComparison();
  #|  const file = fileInput.files[0];
  #|  if (!file || file.size > 16 * 1024 * 1024) throw new Error("Choose a JSON report no larger than 16 MiB.");
  #|  const source = new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer());
  #|  // Keep the report's original JSON tokens so the server can reject duplicate keys and invalid numbers.
  #|  const { data, raw } = await post("compare", '{"previous":' + source + '}');
  #|  const status = { comparable: "Comparable", partial: "Partially comparable", incomparable: "Not comparable" };
  #|  const label = status[data.status] || readable(data.status);
  #|  const comparison = $("comparison");
  #|  comparison.append(node("p", label + (data.reasons.length ? " — " + reasons(data.reasons) : "")));
  #|  const groups = [
  #|    ["Added", data.added, (row) => row.path + " — " + evidenceLabel(row.finding)],
  #|    ["Removed", data.removed, (row) => row.path + " — " + evidenceLabel(row.finding)],
  #|    ["Changed", data.changed, (row) => row.path + " — " + row.previous.map(evidenceLabel).join("; ") + " → " + row.current.map(evidenceLabel).join("; ")],
  #|    ["Unchanged", data.unchanged, (row) => row.path + " — " + evidenceLabel(row.current)],
  #|    ["Not comparable", data.not_comparable, (row) => row.path + " — " + reasons([row.previous_reason, row.current_reason].filter(Boolean))],
  #|  ];
  #|  for (const [name, rows, describe] of groups) {
  #|    const heading = name + " (" + rows.length + ")";
  #|    comparison.append(rows.length ? disclosure(heading, list(rows.map(describe))) : node("p", heading));
  #|  }
  #|  download("download-comparison", "license-scan-comparison.json", raw);
  #|  return "Comparison ready: " + label + ".";
  #|});
  #|
  #|$("notice").onclick = () => run("Checking the notice sources…", async () => {
  #|  const { data, raw } = await post("notice");
  #|  const result = $("notice-results");
  #|  result.replaceChildren(node("p", data.entries.length + " candidates; " + data.review.length + " files to review."));
  #|  if (!data.enumeration_complete) result.append(node("p", "The scan did not enumerate the entire directory."));
  #|  if (data.diagnostics.length) result.append(node("p", reasons(data.diagnostics)));
  #|  for (const [index, entry] of data.entries.entries()) {
  #|    const sources = entry.sources.map((source) => source.path + " — " + evidenceLabel(source) + " (" + source.origin + ")");
  #|    result.append(disclosure("Candidate " + (index + 1) + " — " + entry.sources[0].expression, node("pre", entry.text), list(sources)));
  #|  }
  #|  if (data.review.length) result.append(disclosure("Files to review (" + data.review.length + ")",
  #|    list(data.review.map((row) => row.path + " — " + reasons(row.reasons)))));
  #|  download("download-notice", "license-notice-candidates.json", raw);
  #|  return "Notice candidates ready for review.";
  #|});
