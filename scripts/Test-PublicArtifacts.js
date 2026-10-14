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

const deckPath = path.join(root, "reports", "customer-demo-slides.html");
const deck = fs.readFileSync(deckPath, "utf8");
const slides = [...deck.matchAll(/<section class="slide" id="slide-(\d+)"/g)];
if (slides.length !== 5 || slides.some((slide, index) => Number(slide[1]) !== index + 1)) {
  throw new Error("The published deck must have exactly five ordered slides.");
}
if ([...deck.matchAll(/data-page="\d+"/g)].length !== 5) throw new Error("All five pages need navigation buttons.");
for (const [index, script] of [...deck.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)].entries()) {
  new vm.Script(script[1], { filename: `customer-demo-slides.html:script-${index + 1}` });
}
if (/<script[^>]+src=|<link[^>]+href=/i.test(deck)) throw new Error("The deck must remain self-contained.");
for (const link of deck.matchAll(/href="(\.[^"#?]+)[^"]*"/g)) {
  const file = path.resolve(path.dirname(deckPath), link[1]);
  if (!fs.existsSync(file)) throw new Error(`Broken local deck link: ${link[1]}`);
  const relative = path.relative(root, file).split(path.sep).join("/");
  if (!tracked.includes(relative)) throw new Error(`Default public deck link points to an unpublished file: ${relative}`);
}
const example = JSON.parse(fs.readFileSync(path.join(root, "demo.config.example.json"), "utf8"));
for (const field of ["subscriptionId", "tenantId", "principalId"]) {
  if (example[field] !== "00000000-0000-0000-0000-000000000000") throw new Error("Examples must not publish real identities.");
}
console.log(`PASS: ${tracked.length} staged public files; no private runtime artifacts, identity values, or detected secrets; five offline slides and all public links.`);
console.log("PASS: public documentation and HTML use technical reference copy rather than presenter instructions.");
