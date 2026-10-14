const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { execFileSync } = require("child_process");

const root = path.resolve(__dirname, "..");
const tracked = execFileSync("git", ["ls-files", "--cached", "-z"], {
  cwd: root,
  encoding: "utf8",
}).split("\0").filter(Boolean);
if (!tracked.length) throw new Error("Stage the public source files before validating the publication set.");

const forbiddenPaths = [
  /^\.azure\//,
  /^demo\.config\.json$/,
  /^reports\/(?:private-network-proof|private-path-capability)\.html$/,
  /(?:^|\/)(?:\.env(?:\..*)?|msal_.*|azureProfile\.json|accessTokens\.json)$/,
  /\.(?:pem|key|pfx|p12)$/i,
];
const privateValues = [];
const configPath = path.join(root, "demo.config.json");
if (fs.existsSync(configPath)) {
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  for (const field of ["subscriptionId", "tenantId", "account", "principalId", "privatePathStorageName"]) {
    if (config[field] && !/^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(config[field])) privateValues.push(config[field]);
  }
}
const secretPatterns = [
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\bgh[pousr]_[A-Za-z0-9]{30,}\b/,
  /\bgithub_pat_[A-Za-z0-9_]{30,}\b/,
  /\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b/,
  /AccountKey\s*=\s*[A-Za-z0-9+/]{30,}={0,2}/i,
  /SharedAccessSignature\s*=\s*[^;\s]*sig=/i,
];
const presenterOnlyCopy = /客户会议|客户演示|会议演示|会前准备|讲解词|演示步骤|现场流程与|Re-run during the meeting|Three-minute meeting walkthrough|Share the local HTML report/i;
for (const file of tracked) {
  if (forbiddenPaths.some((pattern) => pattern.test(file))) throw new Error(`Private artifact is staged: ${file}`);
  const body = fs.readFileSync(path.join(root, file), "utf8");
  if (secretPatterns.some((pattern) => pattern.test(body))) throw new Error(`Possible secret found in staged file: ${file}`);
  if (privateValues.some((value) => body.includes(value))) throw new Error(`Private local identity or target found in staged file: ${file}`);
  if (/\.(?:md|html)$/i.test(file) && presenterOnlyCopy.test(body)) {
    throw new Error(`Public technical material contains presenter-only copy: ${file}`);
  }
}

const overviewFile = "reports/customer-demo-slides.md";
if (!tracked.includes(overviewFile)) throw new Error("The Markdown technical overview must be included in the publication set.");
const overview = fs.readFileSync(path.join(root, overviewFile), "utf8");
const sections = [...overview.matchAll(/^## ([1-5])\. /gm)];
if (sections.length !== 5 || sections.some((section, index) => Number(section[1]) !== index + 1)) {
  throw new Error("The technical overview must preserve five ordered content sections.");
}
if (/<(?:script|style|svg)\b/i.test(overview)) throw new Error("The overview must use Markdown and Mermaid rather than HTML presentation code.");
if (!/^```mermaid$/m.test(overview)) throw new Error("The converted architecture diagram must use Mermaid.");
if (tracked.some((file) => file === overviewFile.replace(/\.md$/, ".html"))) {
  throw new Error("The superseded HTML slide deck must not remain in the publication set.");
}

function assertPublicLink(sourceFile, target) {
  if (/^(?:https?:|mailto:|#)/i.test(target)) return;
  const pathname = decodeURIComponent(target.split(/[?#]/)[0]);
  const absolute = path.resolve(root, path.dirname(sourceFile), pathname);
  const relative = path.relative(root, absolute).split(path.sep).join("/");
  if (!fs.existsSync(absolute) || !tracked.includes(relative)) {
    throw new Error(`Broken or unpublished local link in ${sourceFile}: ${target}`);
  }
}

function assertMermaid(sourceFile, markdown) {
  const ids = new Set();
  const attestation = '<!-- mermaid-checked: no \\n, no em-dash/en-dash, no {} in labels, subgraphs are id["label"], arrows are -->|"label"|, all subgraphs closed by end, ids unique -->';
  for (const block of markdown.matchAll(/^```mermaid\r?\n([\s\S]*?)^```/gm)) {
    if (!markdown.slice(0, block.index).trimEnd().endsWith(attestation)) {
      throw new Error(`Missing Mermaid safety attestation: ${sourceFile}`);
    }
    const lines = block[1].trim().split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    if (!/^flowchart (?:TD|LR)$/.test(lines.shift())) throw new Error(`Unsupported Mermaid chart: ${sourceFile}`);
    const stack = [];
    const edges = [];
    let nodeCount = 0;
    for (const line of lines) {
      if (/\\n|[—–{}@#$%&“”‘’]/.test(line)) throw new Error(`Unsafe Mermaid characters in ${sourceFile}: ${line}`);
      const subgraph = /^subgraph ([A-Za-z]\w*)\["[^"]*"\]$/.exec(line);
      const node = /^([A-Za-z]\w*)(?:\["[^"]*"\]|\(\("[^"]*"\)\)|\[\("[^"]*"\)\])$/.exec(line);
      if (subgraph || node) {
        const id = (subgraph || node)[1];
        if (ids.has(id)) throw new Error(`Repeated Mermaid declaration in ${sourceFile}: ${id}`);
        ids.add(id);
        if (subgraph) stack.push(id);
        else nodeCount++;
        continue;
      }
      if (line === "end") {
        if (!stack.pop()) throw new Error(`Unmatched Mermaid end: ${sourceFile}`);
        continue;
      }
      const edge = /^([A-Za-z]\w*)\s+(?:-->|-\.->)(?:\|"[^"]*"\|)?\s+([A-Za-z]\w*)$/.exec(line);
      if (!edge) throw new Error(`Unsupported Mermaid statement in ${sourceFile}: ${line}`);
      edges.push([edge[1], edge[2]]);
    }
    if (stack.length || nodeCount > 40) throw new Error(`Unclosed or oversized Mermaid diagram: ${sourceFile}`);
    for (const edge of edges) {
      if (edge.some((id) => !ids.has(id))) throw new Error(`Undefined Mermaid endpoint: ${sourceFile}`);
    }
  }
}

for (const file of tracked.filter((name) => /\.(?:md|html)$/i.test(name))) {
  const body = fs.readFileSync(path.join(root, file), "utf8");
  if (file.endsWith(".md")) {
    for (const link of body.matchAll(/\[[^\]]+\]\(([^)\s]+)\)/g)) assertPublicLink(file, link[1]);
    assertMermaid(file, body);
  } else {
    for (const link of body.matchAll(/href="([^"]+)"/g)) assertPublicLink(file, link[1]);
    for (const [index, script] of [...body.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].entries()) {
      new vm.Script(script[1], { filename: `${file}:script-${index + 1}` });
    }
  }
}
const example = JSON.parse(fs.readFileSync(path.join(root, "demo.config.example.json"), "utf8"));
for (const field of ["subscriptionId", "tenantId", "principalId"]) {
  if (example[field] !== "00000000-0000-0000-0000-000000000000") throw new Error("Examples must not publish real identities.");
}
console.log(`PASS: ${tracked.length} staged public files; no private runtime artifacts, identity values, or detected secrets; five-section Markdown overview, safe Mermaid diagrams, and all public links.`);
console.log("PASS: public documentation and HTML use technical reference copy rather than presenter instructions.");
