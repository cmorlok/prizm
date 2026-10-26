#!/usr/bin/env bash
# Static check of the devcontainer's compose model against the values the scripts rely on.
#
#   scripts/container/compose-model.sh [compose.yaml] [devcontainer.json]
#
# Defaults to .devcontainer/compose.yaml and .devcontainer/devcontainer.json. Prints one
# "FAIL compose-model: <reason>" line per violation and exits 1, or "compose model OK".
# Checked: prizm-dev keeps the container name and workspace path from scripts/lib/common.sh,
# mounts only the repo and its home volume (no Docker socket) and gets the Dockerfile's version
# args; every rig service is profiled, pinned by digest and published on loopback only.
set -euo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

case "${1:-}" in -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;; esac

compose="${1:-${PRIZM_REPO_ROOT}/.devcontainer/compose.yaml}"
devcontainer="${2:-${PRIZM_REPO_ROOT}/.devcontainer/devcontainer.json}"
[[ -f "${compose}" ]] || die "not found: ${compose}"
[[ -f "${devcontainer}" ]] || die "not found: ${devcontainer}"

# The yaml package OpenSpec already ships; nothing is installed for this check.
NODE_PATH="$(npm root -g)/@fission-ai/openspec/node_modules"
[[ -d "${NODE_PATH}/yaml" ]] || die "yaml module not found under ${NODE_PATH} (is OpenSpec installed?)"
export NODE_PATH

node - "${compose}" "${devcontainer}" "${PRIZM_REPO_ROOT}" <<'JS'
const fs = require("fs");
const path = require("path");
const YAML = require("yaml");
const [composePath, devcontainerPath, root] = process.argv.slice(2);
const failures = [];
const fail = (reason) => failures.push(reason);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const common = fs.readFileSync(path.join(root, "scripts/lib/common.sh"), "utf8");
const containerName = (common.match(/^PRIZM_CONTAINER="\$\{PRIZM_CONTAINER:-([^}]*)\}"$/m) || [])[1];
const workspace = (common.match(/^PRIZM_CONTAINER_WORKSPACE="([^"]*)"$/m) || [])[1];
if (!containerName || !workspace) fail("cannot read PRIZM_CONTAINER / PRIZM_CONTAINER_WORKSPACE from common.sh");

const dockerfile = fs.readFileSync(path.join(root, ".devcontainer/Dockerfile"), "utf8");
const versionArgs = {};
for (const m of dockerfile.matchAll(/^ARG ([A-Z_]+_VERSION)=(\S+)$/gm)) versionArgs[m[1]] = m[2];

const raw = fs.readFileSync(composePath, "utf8");
if (raw.includes("${")) fail("compose.yaml uses ${...} interpolation");
const model = YAML.parse(raw, { merge: true }) || {};
const services = model.services || {};
if (model.name !== "prizm") fail(`project name is ${model.name}, expected prizm`);
const expected = ["edge", "prizm-dev", "vaultwarden-1-37-3", "vaultwarden-1-37-4"];
if (!same(Object.keys(services).sort(), expected)) fail(`services are ${Object.keys(services).sort()}, expected ${expected}`);

const dev = services["prizm-dev"] || {};
if (dev.container_name !== containerName) fail(`prizm-dev container_name is ${dev.container_name}, expected ${containerName}`);
if (dev.profiles) fail("prizm-dev must not have profiles");
if (!same(dev.volumes, [`..:${workspace}`, "prizm-dev-home:/home/developer"]))
  fail(`prizm-dev volumes are ${JSON.stringify(dev.volumes)}, expected only the repo and prizm-dev-home`);
if (!dev.command) fail("prizm-dev has no command (the container would exit)");
if (dev.ports) fail("prizm-dev must not publish ports");
const build = dev.build || {};
if (build.context !== "." || build.dockerfile !== "Dockerfile") fail("prizm-dev build must be context . and Dockerfile");
if (!same(build.args || {}, versionArgs)) fail(`prizm-dev build args ${JSON.stringify(build.args)} differ from the Dockerfile defaults ${JSON.stringify(versionArgs)}`);

for (const [name, svc] of Object.entries(services)) {
  if (name === "prizm-dev") continue;
  if (!same(svc.profiles, ["rig"])) fail(`${name} profiles are ${JSON.stringify(svc.profiles)}, expected [rig]`);
  if (!/^[^:@\s]+:[^@\s]+@sha256:[0-9a-f]{64}$/.test(svc.image || "")) fail(`${name} image is not pinned by tag and digest`);
  for (const port of svc.ports || []) if (!String(port).startsWith("127.0.0.1:")) fail(`${name} publishes ${port} beyond loopback`);
  for (const vol of svc.volumes || []) if (String(vol).includes("docker.sock")) fail(`${name} mounts the Docker socket`);
}
for (const version of ["1.37.4", "1.37.3"]) {
  const svc = services[`vaultwarden-${version.replace(/\./g, "-")}`] || {};
  if ((svc.image || "").split("@")[0].split(":")[1] !== version) fail(`vaultwarden-${version} image tag is not ${version}`);
  if (!same(svc.volumes, [`../dev-vault/${version}:/data`])) fail(`vaultwarden-${version} volumes must be exactly ../dev-vault/${version}:/data`);
  if ((svc.environment || {}).DOMAIN !== "https://localhost:8443") fail(`vaultwarden-${version} DOMAIN is not https://localhost:8443`);
}
const edge = services.edge || {};
if (!same(edge.ports, ["127.0.0.1:8443:8443"])) fail(`edge ports are ${JSON.stringify(edge.ports)}, expected 127.0.0.1:8443:8443`);
for (const vol of ["./rig/nginx.conf:/etc/nginx/nginx.conf:ro", "../dev-vault/certs:/certs:ro",
                   "../dev-vault/nginx:/etc/nginx/rig:ro", "../dev-vault/logs:/var/log/nginx/rig"])
  if (!(edge.volumes || []).includes(vol)) fail(`edge is missing volume ${vol}`);
if (((model.volumes || {})["prizm-dev-home"] || {}).name !== "prizm-dev-home") fail("volume prizm-dev-home has no explicit name");

// devcontainer.json is JSONC with full-line // comments only.
const jsonc = fs.readFileSync(devcontainerPath, "utf8").split("\n").filter((l) => !/^\s*\/\//.test(l)).join("\n");
let dc = {};
try { dc = JSON.parse(jsonc); } catch (e) { fail(`devcontainer.json does not parse: ${e.message}`); }
const want = { dockerComposeFile: "compose.yaml", service: "prizm-dev", shutdownAction: "none",
  workspaceFolder: workspace, remoteUser: "developer", updateRemoteUserUID: true,
  postCreateCommand: "bash .devcontainer/post-create.sh" };
for (const [key, value] of Object.entries(want)) if (dc[key] !== value) fail(`devcontainer.json ${key} is ${JSON.stringify(dc[key])}, expected ${JSON.stringify(value)}`);
if (!same(dc.runServices, ["prizm-dev"])) fail("devcontainer.json runServices must be [\"prizm-dev\"]");
for (const key of ["build", "runArgs", "workspaceMount", "mounts"]) if (key in dc) fail(`devcontainer.json still has ${key} (moved to compose.yaml)`);

for (const f of failures) console.log(`FAIL compose-model: ${f}`);
if (failures.length) process.exit(1);
console.log("compose model OK");
JS
