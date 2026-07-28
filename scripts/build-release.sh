#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

unset CDPATH BASH_ENV ENV NODE_OPTIONS NODE_PATH NODE_REPL_EXTERNAL_MODULE
unset ELAN_TOOLCHAIN LEAN_PATH LEAN_SRC_PATH LAKE_PKG_URL_MAP
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE
unset TAR_OPTIONS
export GIT_NO_REPLACE_OBJECTS=1

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat >&2 <<'EOF'
usage: build-release.sh
       build-release.sh --self-test

Filesystem threat boundary: release and private-build paths must have
quiescent, cooperating same-UID writers while this command runs. Portable Node
does not expose the openat/renameat operations needed to exclude a hostile
same-UID path-replacement race. Parent and file identities are pinned and
rechecked at every detectable boundary; any detected change fails closed.

During publication, HUP/INT/TERM travel over a private tokenized control file;
the shell never signals a stored publisher PID. Each identity query runs in a
handshaken POSIX session owned by an external watchdog. The watchdog terminates
the whole owned group on interruption, normal query completion, publisher loss,
or direct publisher SIGKILL. The publisher restores and re-verifies prior
generations before catchable-signal exit and emits no success output.

Process containment boundary: portable macOS/Linux Node cannot prevent a
descendant from deliberately creating a new session/process group. Identity
programs must cooperate by remaining in the owned session. No member of that
owned group is left running; an unverifiable cleanup retains its private owner
record as quarantine instead of signaling an unowned group.

SIGKILL cannot run release rollback. Once a transaction marker exists, it and
any owned stage/rollback/hold paths are explicit quarantine state and a later
run fails closed.

The build input is an exact verified archive of the committed Loom source tree at
HEAD in a fresh private directory. This binds source bytes, not reproducible
build provenance; toolchain and host inputs remain separate concerns.

A successful replacement retains the verified prior generation at
.lake/release/.loom.previous. Any .loom.transaction.*, .loom.rollback.*,
.loom.previous-hold.*, or .loom.stage.* entry is interrupted/quarantined
state; future runs refuse it until an operator inspects and recovers it.
EOF
}

SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOOM_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd -P)"
NODE_BIN="$(command -v node || true)"
GIT_BIN="$(command -v git || true)"
TAR_BIN="$(command -v tar || true)"
[[ -n "$NODE_BIN" ]] || die "required command not found: node"
[[ -n "$GIT_BIN" ]] || die "required command not found: git"
[[ -n "$TAR_BIN" ]] || die "required command not found: tar"

# These guards detect path replacement before and after each path-based
# operation. They intentionally do not claim race freedom against a hostile
# same-UID process in the interval between those checks.
validate_release_paths() {
  "$NODE_BIN" - "$1" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(process.argv[2]);
const flags = fs.constants;
const guards = [];

if (typeof flags.O_NOFOLLOW !== "number" || typeof flags.O_DIRECTORY !== "number") {
  console.error("error: platform lacks O_NOFOLLOW/O_DIRECTORY required by the release path guard");
  process.exit(2);
}

const lstatOptional = (entry) => {
  try {
    return fs.lstatSync(entry, { bigint: true });
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
};
const sameInode = (left, right) => left.dev === right.dev && left.ino === right.ino;
const inside = (candidate) => {
  const relative = path.relative(root, candidate);
  return relative === "" || (!path.isAbsolute(relative) && relative !== ".." &&
    !relative.startsWith(`..${path.sep}`));
};
const recheck = (items) => {
  for (const guard of items) {
    const byFd = fs.fstatSync(guard.fd, { bigint: true });
    const byPath = fs.lstatSync(guard.path, { bigint: true });
    if (!byFd.isDirectory() || !byPath.isDirectory() || byPath.isSymbolicLink() ||
        !sameInode(guard.identity, byFd) || !sameInode(guard.identity, byPath)) {
      throw new Error(`${guard.label} changed identity during path validation: ${guard.path}`);
    }
    const resolved = fs.realpathSync(guard.path);
    if (!inside(resolved)) throw new Error(`${guard.label} resolves outside the Loom root: ${resolved}`);
  }
};
const pinDirectory = (entry, label, parents) => {
  recheck(parents);
  const before = fs.lstatSync(entry, { bigint: true });
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(`${label} must be a real directory: ${entry}`);
  }
  const fd = fs.openSync(entry, flags.O_RDONLY | flags.O_NOFOLLOW | flags.O_DIRECTORY);
  const opened = fs.fstatSync(fd, { bigint: true });
  const after = fs.lstatSync(entry, { bigint: true });
  if (!opened.isDirectory() || !after.isDirectory() || after.isSymbolicLink() ||
      !sameInode(before, opened) || !sameInode(before, after)) {
    fs.closeSync(fd);
    throw new Error(`${label} changed while it was pinned: ${entry}`);
  }
  const resolved = fs.realpathSync(entry);
  if (!inside(resolved)) {
    fs.closeSync(fd);
    throw new Error(`${label} resolves outside the Loom root: ${resolved}`);
  }
  recheck(parents);
  const guard = { path: entry, label, fd, identity: { dev: opened.dev, ino: opened.ino } };
  guards.push(guard);
  return guard;
};
const assertReleaseFile = (entry, label) => {
  recheck(guards);
  const stat = lstatOptional(entry);
  if (!stat) return null;
  if (stat.isSymbolicLink()) throw new Error(`${label} must not be a symbolic link: ${entry}`);
  if (!stat.isFile()) throw new Error(`${label} must be a regular file: ${entry}`);
  if (stat.nlink !== 1n) throw new Error(`${label} must have exactly one hard link: ${entry} has ${stat.nlink}`);
  if ((stat.mode & 0o111n) === 0n) throw new Error(`${label} must be executable: ${entry}`);
  recheck(guards);
  return stat;
};

try {
  const rootStat = fs.lstatSync(root, { bigint: true });
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory() || fs.realpathSync(root) !== root) {
    throw new Error(`Loom root must be addressed by its physical directory path: ${root}`);
  }
  const rootGuard = pinDirectory(root, "Loom root", []);
  const lake = path.join(root, ".lake");
  const lakeStat = lstatOptional(lake);
  if (!lakeStat) process.exitCode = 0;
  else {
    if (lakeStat.isSymbolicLink() || !lakeStat.isDirectory()) {
      throw new Error(`.lake must be a real directory: ${lake}`);
    }
    const lakeGuard = pinDirectory(lake, ".lake", [rootGuard]);
    const release = path.join(lake, "release");
    const releaseStat = lstatOptional(release);
    if (releaseStat) {
      if (releaseStat.isSymbolicLink() || !releaseStat.isDirectory()) {
        throw new Error(`release directory must be a real directory: ${release}`);
      }
      pinDirectory(release, "release directory", [rootGuard, lakeGuard]);
      recheck(guards);
      const interrupted = fs.readdirSync(release).filter((name) =>
        name === ".loom.stage" || name.startsWith(".loom.stage.") ||
        name === ".loom.rollback" || name.startsWith(".loom.rollback.") ||
        name === ".loom.previous-hold" || name.startsWith(".loom.previous-hold.") ||
        name === ".loom.transaction" || name.startsWith(".loom.transaction."));
      recheck(guards);
      if (interrupted.length > 0) {
        throw new Error(`interrupted release state requires inspection/recovery: ${interrupted.map((name) => path.join(release, name)).join(", ")}`);
      }
      const destination = assertReleaseFile(path.join(release, "loom"), "release destination");
      const previous = assertReleaseFile(path.join(release, ".loom.previous"), "previous release");
      if (previous && !destination) {
        throw new Error(`previous release exists without a release destination; recover it before retrying: ${release}`);
      }
    }
  }
  recheck(guards);
} catch (error) {
  console.error(`error: unsafe release filesystem state: ${error.message}`);
  console.error("action: restore real singly-linked files/directories under the Loom root; preserve and inspect transaction/rollback entries before manual recovery");
  process.exitCode = 2;
} finally {
  for (const guard of guards.reverse()) {
    try { fs.closeSync(guard.fd); } catch {}
  }
}
NODE
}

validate_repository_mapping() {
  "$NODE_BIN" - "$1" "$2" "$3" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [repoInput, loomInput, gitPath] = process.argv.slice(2);
const repo = path.resolve(repoInput);
const loom = path.resolve(loomInput);

try {
  // Empty git prefix means Loom is the repository root (sourcePath ".").
  // Nested checkouts may still live at .../spec/loom (e.g. utils host trees).
  const normalized = gitPath === "" ? "." : gitPath;
  if (path.posix.isAbsolute(normalized) || path.posix.normalize(normalized) !== normalized ||
      normalized === ".." || normalized.startsWith("../") ||
      (normalized !== "." && normalized !== "spec/loom" && !normalized.endsWith("/spec/loom"))) {
    throw new Error(`unexpected Git path for Loom sources: ${JSON.stringify(gitPath)}`);
  }
  const repoStat = fs.lstatSync(repo);
  if (repoStat.isSymbolicLink() || !repoStat.isDirectory() || fs.realpathSync(repo) !== repo) {
    throw new Error(`repository root is not a physical directory: ${repo}`);
  }
  if (normalized === ".") {
    if (fs.realpathSync(repo) !== loom) {
      throw new Error(`Git source path does not identify this Loom root: ${repo} != ${loom}`);
    }
  } else {
    let current = repo;
    for (const component of normalized.split("/")) {
      current = path.join(current, component);
      const stat = fs.lstatSync(current);
      if (stat.isSymbolicLink() || !stat.isDirectory()) {
        throw new Error(`Git source path contains a symlink or non-directory component: ${current}`);
      }
    }
    if (fs.realpathSync(current) !== loom) {
      throw new Error(`Git source path does not identify this Loom root: ${current} != ${loom}`);
    }
  }
} catch (error) {
  console.error(`error: repository identity/path validation failed: ${error.message}`);
  process.exit(2);
}
NODE
}

verify_committed_snapshot() {
  "$NODE_BIN" - "$GIT_BIN" "$1" "$2" "$3" "$4" "$5" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { createHash } = require("node:crypto");
const { spawnSync } = require("node:child_process");

const [git, repo, gitPath, revision, snapshotInput, mode] = process.argv.slice(2);
const snapshot = path.resolve(snapshotInput);
if (mode !== "exact" && mode !== "built") {
  console.error(`error: invalid committed-snapshot verification mode: ${mode}`);
  process.exit(2);
}

const safeRelativePath = (name) => name.length > 0 && !path.posix.isAbsolute(name) &&
  path.posix.normalize(name) === name && name !== ".." && !name.startsWith("../");
const gitBlobId = (bytes) => createHash("sha1")
  .update(Buffer.from(`blob ${bytes.length}\0`, "utf8")).update(bytes).digest("hex");

try {
  const rootStat = fs.lstatSync(snapshot);
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory() || fs.realpathSync(snapshot) !== snapshot) {
    throw new Error(`snapshot root must be a physical directory: ${snapshot}`);
  }
  const listing = spawnSync(git, ["-C", repo, "ls-tree", "-rz", `${revision}:${gitPath}`], {
    encoding: null,
    env: process.env,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (listing.error || listing.status !== 0) {
    throw new Error(`could not enumerate committed tree: ${listing.error?.message || listing.stderr?.toString("utf8").trim() || listing.status}`);
  }
  const expected = new Map();
  let recordStart = 0;
  while (recordStart < listing.stdout.length) {
    const recordEnd = listing.stdout.indexOf(0, recordStart);
    if (recordEnd < 0) throw new Error("git ls-tree output lacks its final NUL delimiter");
    const recordBytes = listing.stdout.subarray(recordStart, recordEnd);
    const rawRecord = recordBytes.toString("utf8");
    if (!Buffer.from(rawRecord, "utf8").equals(recordBytes)) {
      throw new Error("committed tree contains a path that is not valid UTF-8");
    }
    const match = rawRecord.match(/^(\d{6}) (\S+) ([0-9a-f]{40})\t([\s\S]+)$/);
    if (!match) throw new Error(`malformed git ls-tree record: ${JSON.stringify(rawRecord)}`);
    const [, fileMode, type, objectId, name] = match;
    if (!safeRelativePath(name)) throw new Error(`unsafe committed-tree path: ${JSON.stringify(name)}`);
    if (type !== "blob" || (fileMode !== "100644" && fileMode !== "100755")) {
      throw new Error(`symlink, gitlink, or special build input is forbidden: ${fileMode} ${type} ${name}`);
    }
    if (expected.has(name)) throw new Error(`duplicate committed-tree path: ${name}`);
    expected.set(name, { fileMode, objectId });
    recordStart = recordEnd + 1;
  }
  if (!expected.has("lakefile.lean") || !expected.has("lean-toolchain")) {
    throw new Error("committed Loom tree lacks lakefile.lean or lean-toolchain");
  }
  if ([...expected].some(([name]) => name === ".lake" || name.startsWith(".lake/"))) {
    throw new Error("committed Loom tree unexpectedly contains .lake state");
  }

  const actual = new Set();
  const walk = (directory, relativeDirectory = "") => {
    for (const name of fs.readdirSync(directory).sort()) {
      const entry = path.join(directory, name);
      const relative = relativeDirectory ? `${relativeDirectory}/${name}` : name;
      const stat = fs.lstatSync(entry);
      if (stat.isSymbolicLink()) throw new Error(`snapshot contains a symlink: ${relative}`);
      if (stat.isDirectory()) {
        if (relative === ".lake" && mode === "built") continue;
        walk(entry, relative);
        continue;
      }
      if (!stat.isFile() || stat.nlink !== 1) throw new Error(`snapshot contains a special or hard-linked file: ${relative}`);
      const record = expected.get(relative);
      if (!record) throw new Error(`snapshot contains a non-committed file: ${relative}`);
      const bytes = fs.readFileSync(entry);
      const objectId = gitBlobId(bytes);
      if (objectId !== record.objectId) {
        throw new Error(`snapshot bytes differ from committed blob for ${relative}: ${objectId} != ${record.objectId}`);
      }
      const executable = (stat.mode & 0o111) !== 0;
      if (executable !== (record.fileMode === "100755")) {
        throw new Error(`snapshot executable bit differs from committed mode for ${relative}`);
      }
      actual.add(relative);
    }
  };
  walk(snapshot);
  for (const name of expected.keys()) {
    if (!actual.has(name)) throw new Error(`snapshot omitted committed file: ${name}`);
  }
  if (mode === "exact" && fs.existsSync(path.join(snapshot, ".lake"))) {
    throw new Error("fresh committed snapshot already contains .lake state");
  }
} catch (error) {
  console.error(`error: committed-tree snapshot verification failed: ${error.message}`);
  process.exit(2);
}
NODE
}

export_committed_snapshot() {
  local repo_root="$1"
  local git_path="$2"
  local revision="$3"
  local workspace="$4"
  local archive="$workspace/source.tar"
  local snapshot="$workspace/source"

  mkdir -m 700 -- "$snapshot"
  "$GIT_BIN" -C "$repo_root" archive --format=tar --output="$archive" "$revision:$git_path"
  "$TAR_BIN" -xf "$archive" -C "$snapshot"
  verify_committed_snapshot "$repo_root" "$git_path" "$revision" "$snapshot" exact
  printf '%s\n' "$snapshot"
}

workspace_identity() {
  "$NODE_BIN" - "$1" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const entry = path.resolve(process.argv[2]);
const stat = fs.lstatSync(entry, { bigint: true });
if (stat.isSymbolicLink() || !stat.isDirectory() || fs.realpathSync(entry) !== entry) {
  console.error(`error: private build workspace is not a physical directory: ${entry}`);
  process.exit(2);
}
process.stdout.write(`${stat.dev}\t${stat.ino}`);
NODE
}

cleanup_owned_workspace() {
  "$NODE_BIN" - "$1" "$2" "$3" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [entryInput, expectedDev, expectedIno] = process.argv.slice(2);
const entry = path.resolve(entryInput);

try {
  const root = fs.lstatSync(entry, { bigint: true });
  if (root.isSymbolicLink() || !root.isDirectory() || root.dev.toString() !== expectedDev ||
      root.ino.toString() !== expectedIno || !path.basename(entry).startsWith("loom-release-build.")) {
    throw new Error(`refusing to remove workspace whose owned identity changed: ${entry}`);
  }
  const removeTree = (directory) => {
    for (const name of fs.readdirSync(directory)) {
      const child = path.join(directory, name);
      const stat = fs.lstatSync(child);
      if (stat.isDirectory() && !stat.isSymbolicLink()) {
        removeTree(child);
        fs.rmdirSync(child);
      } else {
        fs.unlinkSync(child);
      }
    }
  };
  removeTree(entry);
  const final = fs.lstatSync(entry, { bigint: true });
  if (!final.isDirectory() || final.isSymbolicLink() || final.dev !== root.dev || final.ino !== root.ino) {
    throw new Error(`workspace identity changed during cleanup: ${entry}`);
  }
  fs.rmdirSync(entry);
} catch (error) {
  if (error.code === "ENOENT") process.exit(0);
  console.error(`error: private build workspace cleanup failed: ${error.message}`);
  console.error(`action: inspect and remove the quarantined workspace manually: ${entry}`);
  process.exit(2);
}
NODE
}

new_token() {
  "$NODE_BIN" -e 'process.stdout.write(require("node:crypto").randomBytes(16).toString("hex"))'
}

PUBLISH_PID=""
PUBLISH_CHILD_OWNED=0
PUBLISH_TOKEN=""
PUBLISH_CONTROL_PATH=""
PUBLISH_OWNER_DIRECTORY=""
PUBLISH_SUPERVISION_DIRECTORY=""
PUBLISH_SUPERVISION_DEV=""
PUBLISH_SUPERVISION_INO=""

create_publish_supervision() {
  local token="$1"
  local identity
  PUBLISH_SUPERVISION_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/loom-release-supervisor.XXXXXX")"
  PUBLISH_SUPERVISION_DIRECTORY="$(cd -P -- "$PUBLISH_SUPERVISION_DIRECTORY" && pwd -P)"
  chmod 700 "$PUBLISH_SUPERVISION_DIRECTORY"
  PUBLISH_CONTROL_PATH="$PUBLISH_SUPERVISION_DIRECTORY/control"
  PUBLISH_OWNER_DIRECTORY="$PUBLISH_SUPERVISION_DIRECTORY/owners"
  mkdir -m 700 -- "$PUBLISH_OWNER_DIRECTORY"
  : >"$PUBLISH_CONTROL_PATH"
  chmod 600 "$PUBLISH_CONTROL_PATH"
  identity="$(workspace_identity "$PUBLISH_SUPERVISION_DIRECTORY")"
  IFS=$'\t' read -r PUBLISH_SUPERVISION_DEV PUBLISH_SUPERVISION_INO <<<"$identity"
  IFS=$'\n\t'
  PUBLISH_TOKEN="$token"
}

wait_for_identity_owners() {
  "$NODE_BIN" - "$1" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const directory = path.resolve(process.argv[2]);
const started = Date.now();

const inspect = () => {
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory() || fs.realpathSync(directory) !== directory) {
    throw new Error(`identity-owner directory changed identity: ${directory}`);
  }
  const entries = fs.readdirSync(directory);
  for (const name of entries) {
    if (!/^identity\.[0-9a-f]{32}$/.test(name)) {
      throw new Error(`unexpected identity-owner entry: ${path.join(directory, name)}`);
    }
    const entry = path.join(directory, name);
    const owner = fs.lstatSync(entry);
    if (owner.isSymbolicLink() || !owner.isFile() || owner.nlink !== 1) {
      throw new Error(`identity-owner entry is not a singly-linked regular file: ${entry}`);
    }
  }
  return entries;
};

const poll = () => {
  try {
    const entries = inspect();
    if (entries.length === 0) return;
    if (Date.now() - started >= 10000) {
      console.error(`error: identity watchdog cleanup timed out: ${entries.join(", ")}`);
      console.error(`action: preserve and inspect the supervision directory: ${directory}`);
      process.exitCode = 2;
      return;
    }
    setTimeout(poll, 25);
  } catch (error) {
    console.error(`error: identity watchdog ownership check failed: ${error.message}`);
    process.exitCode = 2;
  }
};
poll();
NODE
}

cleanup_publish_supervision() {
  "$NODE_BIN" - "$1" "$2" "$3" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [directoryInput, expectedDev, expectedIno] = process.argv.slice(2);
const directory = path.resolve(directoryInput);

try {
  const root = fs.lstatSync(directory, { bigint: true });
  if (root.isSymbolicLink() || !root.isDirectory() || root.dev.toString() !== expectedDev ||
      root.ino.toString() !== expectedIno ||
      !path.basename(directory).startsWith("loom-release-supervisor.")) {
    throw new Error(`refusing to remove supervision directory whose owned identity changed: ${directory}`);
  }
  const names = fs.readdirSync(directory).sort();
  if (names.join("\n") !== "control\nowners") {
    throw new Error(`supervision directory has unexpected entries: ${names.join(", ")}`);
  }
  const owners = path.join(directory, "owners");
  const ownersStat = fs.lstatSync(owners);
  if (ownersStat.isSymbolicLink() || !ownersStat.isDirectory() || fs.readdirSync(owners).length !== 0) {
    throw new Error(`identity-owner directory is unsafe or nonempty: ${owners}`);
  }
  const control = path.join(directory, "control");
  const controlStat = fs.lstatSync(control);
  if (controlStat.isSymbolicLink() || !controlStat.isFile() || controlStat.nlink !== 1) {
    throw new Error(`publisher control path is not a singly-linked regular file: ${control}`);
  }
  fs.unlinkSync(control);
  fs.rmdirSync(owners);
  const final = fs.lstatSync(directory, { bigint: true });
  if (final.dev !== root.dev || final.ino !== root.ino || fs.readdirSync(directory).length !== 0) {
    throw new Error(`supervision directory changed during cleanup: ${directory}`);
  }
  fs.rmdirSync(directory);
} catch (error) {
  console.error(`error: publisher supervision cleanup failed: ${error.message}`);
  console.error(`action: preserve and inspect the supervision directory: ${directory}`);
  process.exit(2);
}
NODE
}

wait_publish_release() {
  local status owner_status cleanup_status
  local pid="${PUBLISH_PID:-}"
  if [[ "$PUBLISH_CHILD_OWNED" -ne 1 || -z "$pid" ]]; then
    printf '%s\n' "error: no owned publisher child is available to wait" >&2
    return 2
  fi
  if wait "$pid"; then status=0; else status=$?; fi
  PUBLISH_PID=""
  PUBLISH_CHILD_OWNED=0
  if wait_for_identity_owners "$PUBLISH_OWNER_DIRECTORY"; then owner_status=0; else owner_status=$?; fi
  if [[ "$owner_status" -eq 0 ]]; then
    if cleanup_publish_supervision "$PUBLISH_SUPERVISION_DIRECTORY" \
      "$PUBLISH_SUPERVISION_DEV" "$PUBLISH_SUPERVISION_INO"; then
      cleanup_status=0
    else
      cleanup_status=$?
    fi
  else
    cleanup_status=0
  fi
  if [[ "$owner_status" -eq 0 && "$cleanup_status" -eq 0 ]]; then
    PUBLISH_TOKEN=""
    PUBLISH_CONTROL_PATH=""
    PUBLISH_OWNER_DIRECTORY=""
    PUBLISH_SUPERVISION_DIRECTORY=""
    PUBLISH_SUPERVISION_DEV=""
    PUBLISH_SUPERVISION_INO=""
  fi
  [[ "$owner_status" -eq 0 && "$cleanup_status" -eq 0 ]] || return 2
  return "$status"
}

start_publish_release() {
  local stdout_path="$1"
  shift
  create_publish_supervision "$4"
  "$NODE_BIN" - "$1" "$2" "$3" "$4" "${5:-none}" "${6:--}" \
    "$PUBLISH_CONTROL_PATH" "$PUBLISH_OWNER_DIRECTORY" >"$stdout_path" <<'NODE' &
const fs = require("node:fs");
const path = require("node:path");
const { createHash, randomBytes } = require("node:crypto");
const { spawn } = require("node:child_process");

const [sourceRootInput, releaseRootInput, expectedRevision, token, testHook, reportPath,
  controlPathInput, ownerDirectoryInput] = process.argv.slice(2);
const sourceRoot = path.resolve(sourceRootInput);
const releaseRoot = path.resolve(releaseRootInput);
const controlPath = path.resolve(controlPathInput);
const ownerDirectory = path.resolve(ownerDirectoryInput);
const flags = fs.constants;
const allGuards = [];
let sourceFd;
let stageFd;
let markerFd;
let priorFd;
let olderPreviousFd;
let controlFd;
let ownerDirectoryFd;
let sourceGuards = [];
let releaseGuards = [];
let stageIdentity;
let markerIdentity;
let priorIdentity;
let olderPreviousIdentity;
let priorBytes;
let priorClaim;
let olderPreviousBytes;
let olderPreviousClaim;
let candidateLocation = null;
let rollbackLocation = null;
let olderPreviousLocation = null;
let markerPresent = false;
let committed = false;
let finalClaim;
let finalBytes;
let activeChild = null;
let interruption = null;
let controlIdentity;
let ownerDirectoryIdentity;
let controlOffset = 0;
let controlRemainder = "";
let controlWatch = null;

if (typeof flags.O_NOFOLLOW !== "number" || typeof flags.O_DIRECTORY !== "number") {
  console.error("error: platform lacks O_NOFOLLOW/O_DIRECTORY required for guarded publication");
  process.exit(2);
}
if (!/^[0-9a-f]{40}$/.test(expectedRevision)) {
  console.error(`error: release revision must be exactly 40 lowercase hexadecimal characters: ${expectedRevision}`);
  process.exit(2);
}
if (!/^[0-9a-f]{32}$/.test(token)) {
  console.error(`error: internal release transaction token is invalid: ${token}`);
  process.exit(2);
}
if (!["none", "fail-after-backup", "fail-after-rename", "fail-after-rotation",
      "replace-release-parent-before-rename"].includes(testHook)) {
  console.error(`error: internal release self-test hook is invalid: ${testHook}`);
  process.exit(2);
}

const buildLake = path.join(sourceRoot, ".lake");
const buildDirectory = path.join(buildLake, "build");
const buildBinDirectory = path.join(buildDirectory, "bin");
const buildBinary = path.join(buildBinDirectory, "loom");
const releaseLake = path.join(releaseRoot, ".lake");
const releaseDirectory = path.join(releaseLake, "release");
const releaseBinary = path.join(releaseDirectory, "loom");
const previousBinary = path.join(releaseDirectory, ".loom.previous");
const stage = path.join(releaseDirectory, `.loom.stage.${token}`);
const rollback = path.join(releaseDirectory, `.loom.rollback.${token}`);
const previousHold = path.join(releaseDirectory, `.loom.previous-hold.${token}`);
const marker = path.join(releaseDirectory, `.loom.transaction.${token}`);

const lstatOptional = (entry) => {
  try {
    return fs.lstatSync(entry, { bigint: true });
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
};
const inode = (stat) => ({ dev: stat.dev, ino: stat.ino });
const sameInode = (left, right) => left.dev === right.dev && left.ino === right.ino;
const stableFile = (left, right) => sameInode(left, right) && left.size === right.size &&
  left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs && left.nlink === right.nlink &&
  left.mode === right.mode;
const within = (root, candidate) => {
  const relative = path.relative(root, candidate);
  return relative === "" || (!path.isAbsolute(relative) && relative !== ".." &&
    !relative.startsWith(`..${path.sep}`));
};
const closeFd = (fd) => {
  if (fd !== undefined) {
    try { fs.closeSync(fd); } catch {}
  }
};
const recheckGuards = (guards) => {
  for (const guard of guards) {
    const viaFd = fs.fstatSync(guard.fd, { bigint: true });
    const viaPath = fs.lstatSync(guard.path, { bigint: true });
    if (!viaFd.isDirectory() || !viaPath.isDirectory() || viaPath.isSymbolicLink() ||
        !sameInode(guard.identity, viaFd) || !sameInode(guard.identity, viaPath)) {
      throw new Error(`${guard.label} changed identity at a path boundary: ${guard.path}`);
    }
    const resolved = fs.realpathSync(guard.path);
    if (!within(guard.root, resolved)) {
      throw new Error(`${guard.label} resolves outside its guarded root: ${resolved}`);
    }
  }
};
const pinDirectory = (entry, label, root, parents) => {
  recheckGuards(parents);
  const before = fs.lstatSync(entry, { bigint: true });
  if (before.isSymbolicLink() || !before.isDirectory()) throw new Error(`${label} must be a real directory: ${entry}`);
  const fd = fs.openSync(entry, flags.O_RDONLY | flags.O_NOFOLLOW | flags.O_DIRECTORY);
  const opened = fs.fstatSync(fd, { bigint: true });
  const after = fs.lstatSync(entry, { bigint: true });
  if (!opened.isDirectory() || !after.isDirectory() || after.isSymbolicLink() ||
      !sameInode(before, opened) || !sameInode(before, after)) {
    closeFd(fd);
    throw new Error(`${label} changed while it was pinned: ${entry}`);
  }
  const resolved = fs.realpathSync(entry);
  if (!within(root, resolved)) {
    closeFd(fd);
    throw new Error(`${label} resolves outside its guarded root: ${resolved}`);
  }
  recheckGuards(parents);
  const guard = { path: entry, label, root, fd, identity: inode(opened) };
  allGuards.push(guard);
  return guard;
};
const ensurePinnedDirectory = (entry, label, root, parents, mode) => {
  recheckGuards(parents);
  const existing = lstatOptional(entry);
  if (!existing) {
    fs.mkdirSync(entry, { mode });
    recheckGuards(parents);
  } else if (existing.isSymbolicLink() || !existing.isDirectory()) {
    throw new Error(`${label} must be a real directory: ${entry}`);
  }
  const guard = pinDirectory(entry, label, root, parents);
  if (!existing) {
    fs.fchmodSync(guard.fd, mode);
    fs.fsyncSync(guard.fd);
    recheckGuards([...parents, guard]);
    fs.fsyncSync(parents[parents.length - 1].fd);
  }
  recheckGuards([...parents, guard]);
  return guard;
};
const assertOwnedPath = (entry, expected, label, guards, { executable = false, links = 1n } = {}) => {
  recheckGuards(guards);
  const stat = fs.lstatSync(entry, { bigint: true });
  if (stat.isSymbolicLink() || !stat.isFile() || !sameInode(stat, expected)) {
    throw new Error(`${label} no longer names the owned regular inode: ${entry}`);
  }
  if (links !== null && stat.nlink !== links) {
    throw new Error(`${label} has unexpected hard-link count ${stat.nlink}, expected ${links}: ${entry}`);
  }
  if (executable && (stat.mode & 0o111n) === 0n) throw new Error(`${label} is not executable: ${entry}`);
  recheckGuards(guards);
  return stat;
};
const openRegular = (entry, label, guards, { executable = false } = {}) => {
  recheckGuards(guards);
  const before = fs.lstatSync(entry, { bigint: true });
  if (before.isSymbolicLink() || !before.isFile() || before.nlink !== 1n) {
    throw new Error(`${label} must be a singly-linked regular non-symlink file: ${entry}`);
  }
  if (executable && (before.mode & 0o111n) === 0n) throw new Error(`${label} is not executable: ${entry}`);
  const fd = fs.openSync(entry, flags.O_RDONLY | flags.O_NOFOLLOW);
  const opened = fs.fstatSync(fd, { bigint: true });
  const after = fs.lstatSync(entry, { bigint: true });
  if (!opened.isFile() || opened.nlink !== 1n || !sameInode(before, opened) || !stableFile(before, after)) {
    closeFd(fd);
    throw new Error(`${label} changed while it was opened: ${entry}`);
  }
  recheckGuards(guards);
  return { fd, stat: opened, identity: inode(opened) };
};
const createOwnedFile = (entry, label, guards, mode) => {
  recheckGuards(guards);
  if (lstatOptional(entry)) throw new Error(`${label} already exists: ${entry}`);
  const fd = fs.openSync(entry,
    flags.O_RDWR | flags.O_CREAT | flags.O_EXCL | flags.O_NOFOLLOW, mode);
  fs.fchmodSync(fd, mode);
  const opened = fs.fstatSync(fd, { bigint: true });
  if (!opened.isFile() || opened.nlink !== 1n) {
    closeFd(fd);
    throw new Error(`${label} was not created as a singly-linked regular file: ${entry}`);
  }
  const expected = inode(opened);
  assertOwnedPath(entry, expected, label, guards);
  return { fd, identity: expected };
};
const hashFd = (fd, label) => {
  const before = fs.fstatSync(fd, { bigint: true });
  if (!before.isFile()) throw new Error(`${label} descriptor is no longer regular`);
  const hash = createHash("sha256");
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let position = 0;
  for (;;) {
    const count = fs.readSync(fd, buffer, 0, buffer.length, position);
    if (count === 0) break;
    hash.update(buffer.subarray(0, count));
    position += count;
  }
  const after = fs.fstatSync(fd, { bigint: true });
  if (!stableFile(before, after)) throw new Error(`${label} changed while it was hashed`);
  return {
    sha256: hash.digest("hex"), size: after.size.toString(),
    dev: after.dev, ino: after.ino, mode: Number(after.mode & 0o777n), nlink: after.nlink,
  };
};
const sameBytes = (left, right) => left.sha256 === right.sha256 && left.size === right.size;
const writeAll = (fd, bytes) => {
  let offset = 0;
  while (offset < bytes.length) offset += fs.writeSync(fd, bytes, offset, bytes.length - offset, offset);
};
const recheckSupervision = () => {
  const controlByFd = fs.fstatSync(controlFd, { bigint: true });
  const controlByPath = fs.lstatSync(controlPath, { bigint: true });
  if (!controlByFd.isFile() || !controlByPath.isFile() || controlByPath.isSymbolicLink() ||
      controlByFd.nlink !== 1n || controlByPath.nlink !== 1n ||
      !sameInode(controlIdentity, controlByFd) || !sameInode(controlIdentity, controlByPath)) {
    throw new Error(`publisher control path changed owned identity: ${controlPath}`);
  }
  const ownersByFd = fs.fstatSync(ownerDirectoryFd, { bigint: true });
  const ownersByPath = fs.lstatSync(ownerDirectory, { bigint: true });
  if (!ownersByFd.isDirectory() || !ownersByPath.isDirectory() || ownersByPath.isSymbolicLink() ||
      !sameInode(ownerDirectoryIdentity, ownersByFd) ||
      !sameInode(ownerDirectoryIdentity, ownersByPath)) {
    throw new Error(`identity-owner directory changed owned identity: ${ownerDirectory}`);
  }
};
const initializeSupervision = () => {
  const controlBefore = fs.lstatSync(controlPath, { bigint: true });
  if (controlBefore.isSymbolicLink() || !controlBefore.isFile() || controlBefore.nlink !== 1n) {
    throw new Error(`publisher control path must be a singly-linked regular file: ${controlPath}`);
  }
  controlFd = fs.openSync(controlPath, flags.O_RDONLY | flags.O_NOFOLLOW);
  const controlOpened = fs.fstatSync(controlFd, { bigint: true });
  if (!sameInode(controlBefore, controlOpened)) {
    throw new Error(`publisher control path changed while opening: ${controlPath}`);
  }
  controlIdentity = inode(controlOpened);
  const ownersBefore = fs.lstatSync(ownerDirectory, { bigint: true });
  if (ownersBefore.isSymbolicLink() || !ownersBefore.isDirectory()) {
    throw new Error(`identity-owner path must be a real directory: ${ownerDirectory}`);
  }
  ownerDirectoryFd = fs.openSync(ownerDirectory,
    flags.O_RDONLY | flags.O_NOFOLLOW | flags.O_DIRECTORY);
  const ownersOpened = fs.fstatSync(ownerDirectoryFd, { bigint: true });
  if (!sameInode(ownersBefore, ownersOpened)) {
    throw new Error(`identity-owner directory changed while opening: ${ownerDirectory}`);
  }
  ownerDirectoryIdentity = inode(ownersOpened);
  recheckSupervision();
};
const createIdentityOwner = (identityToken, label) => {
  recheckSupervision();
  const ownerPath = path.join(ownerDirectory, `identity.${identityToken}`);
  if (lstatOptional(ownerPath)) throw new Error(`${label} owner record already exists: ${ownerPath}`);
  const fd = fs.openSync(ownerPath,
    flags.O_RDWR | flags.O_CREAT | flags.O_EXCL | flags.O_NOFOLLOW, 0o600);
  fs.fchmodSync(fd, 0o600);
  const stat = fs.fstatSync(fd, { bigint: true });
  if (!stat.isFile() || stat.nlink !== 1n) {
    closeFd(fd);
    throw new Error(`${label} owner record is not a singly-linked regular file: ${ownerPath}`);
  }
  const bytes = Buffer.from(`${JSON.stringify({
    schema: "loom.identity-owner.v1", state: "launching", publicationToken: token,
    identityToken, publisherPid: process.pid, label,
  })}\n`, "utf8");
  writeAll(fd, bytes);
  fs.fsyncSync(fd);
  fs.fsyncSync(ownerDirectoryFd);
  recheckSupervision();
  return { path: ownerPath, fd, identity: inode(stat) };
};
const removeUnlaunchedOwner = (owner, label) => {
  const byFd = fs.fstatSync(owner.fd, { bigint: true });
  const byPath = fs.lstatSync(owner.path, { bigint: true });
  if (!sameInode(owner.identity, byFd) || !sameInode(owner.identity, byPath) ||
      byPath.isSymbolicLink() || !byPath.isFile() || byPath.nlink !== 1n) {
    throw new Error(`${label} unlaunched owner record changed identity: ${owner.path}`);
  }
  fs.unlinkSync(owner.path);
  fs.fsyncSync(ownerDirectoryFd);
  closeFd(owner.fd);
  owner.fd = undefined;
};
const copyAndHash = (fromFd, toFd) => {
  const before = fs.fstatSync(fromFd, { bigint: true });
  const hash = createHash("sha256");
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let position = 0;
  for (;;) {
    const count = fs.readSync(fromFd, buffer, 0, buffer.length, position);
    if (count === 0) break;
    hash.update(buffer.subarray(0, count));
    let written = 0;
    while (written < count) {
      written += fs.writeSync(toFd, buffer, written, count - written, position + written);
    }
    position += count;
  }
  fs.fsyncSync(toFd);
  const after = fs.fstatSync(fromFd, { bigint: true });
  if (!stableFile(before, after)) throw new Error("built core changed during descriptor-bound copy");
  return {
    sha256: hash.digest("hex"), size: after.size.toString(), dev: after.dev, ino: after.ino,
    mode: Number(after.mode & 0o777n), nlink: after.nlink,
  };
};
const fsyncGuard = (guard) => {
  recheckGuards(releaseGuards);
  fs.fsyncSync(guard.fd);
  recheckGuards(releaseGuards);
};

const rejectDuplicateKeys = (text) => {
  let index = 0;
  const whitespace = () => { while (/\s/.test(text[index] || "")) index += 1; };
  const fail = (message) => { throw new Error(`${message} at JSON offset ${index}`); };
  const string = () => {
    const start = index;
    if (text[index++] !== '"') fail("expected string");
    while (index < text.length) {
      const code = text.charCodeAt(index);
      if (text[index] === '"') {
        index += 1;
        return JSON.parse(text.slice(start, index));
      }
      if (code < 0x20) fail("control character in string");
      if (text[index] === "\\") {
        index += 1;
        const escape = text[index];
        if (escape === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(text.slice(index + 1, index + 5))) fail("invalid Unicode escape");
          index += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape || "")) fail("invalid string escape");
      }
      index += 1;
    }
    fail("unterminated string");
  };
  const value = () => {
    whitespace();
    if (text[index] === '"') { string(); return; }
    if (text[index] === "{") {
      index += 1;
      whitespace();
      const keys = new Set();
      if (text[index] === "}") { index += 1; return; }
      for (;;) {
        whitespace();
        if (text[index] !== '"') fail("expected object key");
        const key = string();
        if (keys.has(key)) throw new Error(`duplicate JSON object key ${JSON.stringify(key)}`);
        keys.add(key);
        whitespace();
        if (text[index++] !== ":") fail("expected colon");
        value();
        whitespace();
        if (text[index] === "}") { index += 1; return; }
        if (text[index++] !== ",") fail("expected object comma");
      }
    }
    if (text[index] === "[") {
      index += 1;
      whitespace();
      if (text[index] === "]") { index += 1; return; }
      for (;;) {
        value();
        whitespace();
        if (text[index] === "]") { index += 1; return; }
        if (text[index++] !== ",") fail("expected array comma");
      }
    }
    const rest = text.slice(index);
    const literal = rest.match(/^(?:true|false|null)/)?.[0];
    if (literal) { index += literal.length; return; }
    const number = rest.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)?.[0];
    if (number) { index += number.length; return; }
    fail("invalid JSON value");
  };
  whitespace();
  value();
  whitespace();
  if (index !== text.length) fail("trailing JSON data");
};
const validateIdentity = (raw, label, requiredRevision) => {
  rejectDuplicateKeys(raw);
  let value;
  try { value = JSON.parse(raw); }
  catch (error) { throw new Error(`${label} identity is not JSON: ${error.message}`); }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} identity must be a JSON object`);
  }
  const mismatches = [];
  if (value.engine !== "lean") mismatches.push(`engine=${JSON.stringify(value.engine)}`);
  if (value.engineVersion !== "0.2.0-preview.0") mismatches.push(`engineVersion=${JSON.stringify(value.engineVersion)}`);
  if (value.protocolVersion !== "loom.cli.v1") mismatches.push(`protocolVersion=${JSON.stringify(value.protocolVersion)}`);
  if (requiredRevision === null) {
    if (typeof value.coreRevision !== "string" || !/^[0-9a-f]{40}$/.test(value.coreRevision)) {
      mismatches.push(`coreRevision=${JSON.stringify(value.coreRevision)}`);
    }
  } else if (value.coreRevision !== requiredRevision) {
    mismatches.push(`coreRevision=${JSON.stringify(value.coreRevision)} (expected ${requiredRevision})`);
  }
  if (value.sourceRepository !== "https://github.com/theoriclabs/agent-convert-lean") {
    mismatches.push(`sourceRepository=${JSON.stringify(value.sourceRepository)}`);
  }
  if (value.sourcePath !== ".") mismatches.push(`sourcePath=${JSON.stringify(value.sourcePath)}`);
  if (!Array.isArray(value.wireSchemas) || !value.wireSchemas.includes("loom.transcript.v0") ||
      value.wireSchemas.some((schema) => typeof schema !== "string")) {
    mismatches.push(`wireSchemas=${JSON.stringify(value.wireSchemas)}`);
  }
  if (typeof value.targetTriple !== "string" || value.targetTriple.length === 0) {
    mismatches.push(`targetTriple=${JSON.stringify(value.targetTriple)}`);
  }
  if (mismatches.length > 0) throw new Error(`${label} identity mismatch: ${mismatches.join("; ")}`);
  const canonical = {
    engine: value.engine,
    engineVersion: value.engineVersion,
    protocolVersion: value.protocolVersion,
    coreRevision: value.coreRevision,
    sourceRepository: value.sourceRepository,
    sourcePath: value.sourcePath,
    targetTriple: value.targetTriple,
    wireSchemas: [...value.wireSchemas],
  };
  return { value: canonical, json: JSON.stringify(canonical) };
};
class InterruptedError extends Error {
  constructor(name) {
    super(`publication interrupted by ${name}`);
    this.name = "InterruptedError";
  }
}
let recovering = false;
const throwIfInterrupted = (allowInterrupted = false) => {
  if (interruption && !allowInterrupted) throw new InterruptedError(interruption.name);
};
const checkpoint = async (allowInterrupted = false) => {
  await new Promise((resolve) => setImmediate(resolve));
  throwIfInterrupted(allowInterrupted);
};
const stopActiveIdentity = (signal) => {
  if (!activeChild) return;
  const owned = activeChild;
  if (owned.child.connected) {
    try {
      owned.child.send({ type: "stop", token: owned.token, signal });
      return;
    } catch {}
  }
  // This ChildProcess object is still unreaped and directly owned. Signaling it
  // asks the watchdog to clean its nested group; no stored numeric PID is used.
  try { owned.child.kill(signal); } catch {}
};
const requestInterruption = (status, name, signal) => {
  if (!interruption) interruption = { status, name, signal };
  if (committed || recovering || !activeChild) return;
  stopActiveIdentity(signal);
};
process.on("SIGHUP", () => requestInterruption(129, "SIGHUP", "SIGHUP"));
process.on("SIGINT", () => requestInterruption(130, "SIGINT", "SIGINT"));
process.on("SIGTERM", () => requestInterruption(143, "SIGTERM", "SIGTERM"));
const supervisorPid = process.ppid;
const supervisorWatch = setInterval(() => {
  if (process.ppid !== supervisorPid) {
    requestInterruption(143, "publication supervisor loss", "SIGTERM");
  }
}, 50);

// The watchdog stays outside the nested identity session. A token/PID/PPID
// handshake proves the runner is the live group leader before the watchdog
// ever uses a negative-PID group signal; the leader remains until group kill.
const identityRunnerProgram = String.raw`
"use strict";
const { spawn } = require("node:child_process");
const [target, cwd, token, expectedParentText] = process.argv.slice(1);
const expectedParent = Number(expectedParentText);
let targetChild = null;
let resultSent = false;
let parentCleanup = false;

const send = (message) => {
  if (process.connected) {
    try { process.send(message); } catch {}
  }
};
const signalOwnGroup = (signal) => {
  try { process.kill(-process.pid, signal); }
  catch (error) { if (error.code !== "ESRCH") throw error; }
};
const beginParentCleanup = () => {
  if (parentCleanup) return;
  parentCleanup = true;
  signalOwnGroup("SIGTERM");
  setTimeout(() => signalOwnGroup("SIGKILL"), 200);
};
for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) {
  process.on(signal, () => {});
}
process.on("disconnect", beginParentCleanup);
const parentWatch = setInterval(() => {
  if (process.ppid !== expectedParent) beginParentCleanup();
}, 25);

if (!/^[0-9a-f]{32}$/.test(token) || process.ppid !== expectedParent) {
  process.exit(72);
}
try { process.kill(-process.pid, 0); }
catch { process.exit(73); }
send({ type: "runner-ready", token, pid: process.pid, parentPid: process.ppid });

let startError = null;
try {
  targetChild = spawn(target, ["version", "--json"], {
    cwd,
    env: { ...process.env, LOOM_RELEASE_IDENTITY_OWNER: token },
    detached: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
} catch (error) {
  startError = error;
}
if (!targetChild) {
  resultSent = true;
  send({ type: "target-result", token, status: 127, signal: null,
    startError: startError ? startError.message : "spawn failed" });
} else {
  targetChild.stdout.pipe(process.stdout, { end: false });
  targetChild.stderr.pipe(process.stderr, { end: false });
  targetChild.once("error", (error) => { startError = error; });
  targetChild.once("close", (status, signal) => {
    if (resultSent) return;
    resultSent = true;
    send({ type: "target-result", token, status, signal,
      startError: startError ? startError.message : null });
  });
}
setInterval(() => {}, 1000);
`;

const identityWatchdogProgram = String.raw`
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const [target, cwd, token, ownerPath, expectedDev, expectedIno,
  expectedPublisherText, runnerBase64] = process.argv.slice(1);
const expectedPublisher = Number(expectedPublisherText);
const flags = fs.constants;
let ownerFd;
let ownerDirectoryFd;
let ownerIdentity;
let runner = null;
let runnerPid = null;
let groupOwned = false;
let targetResult = null;
let stopping = null;
let cleaning = false;
let cleanupTimer = null;
let preserveOwner = false;
let finished = false;

process.stdout.on("error", () => {});
process.stderr.on("error", () => {});
const sameInode = (left, right) => left.dev === right.dev && left.ino === right.ino;
const send = (message) => {
  if (process.connected) {
    try { process.send(message); } catch {}
  }
};
const writeAll = (fd, bytes) => {
  let offset = 0;
  while (offset < bytes.length) offset += fs.writeSync(fd, bytes, offset,
    bytes.length - offset, offset);
};
const writeOwner = (state) => {
  const byFd = fs.fstatSync(ownerFd, { bigint: true });
  const byPath = fs.lstatSync(ownerPath, { bigint: true });
  if (!sameInode(ownerIdentity, byFd) || !sameInode(ownerIdentity, byPath) ||
      byPath.isSymbolicLink() || !byPath.isFile() || byPath.nlink !== 1n) {
    throw new Error("identity owner record changed owned identity");
  }
  const bytes = Buffer.from(JSON.stringify({
    schema: "loom.identity-owner.v1", state, identityToken: token,
    publisherPid: expectedPublisher, watchdogPid: process.pid,
    runnerPid: runnerPid,
  }) + "\n", "utf8");
  fs.ftruncateSync(ownerFd, 0);
  writeAll(ownerFd, bytes);
  fs.fsyncSync(ownerFd);
};
const removeOwner = () => {
  const byFd = fs.fstatSync(ownerFd, { bigint: true });
  const byPath = fs.lstatSync(ownerPath, { bigint: true });
  if (!sameInode(ownerIdentity, byFd) || !sameInode(ownerIdentity, byPath) ||
      byPath.isSymbolicLink() || !byPath.isFile() || byPath.nlink !== 1n) {
    throw new Error("identity owner record changed before cleanup");
  }
  fs.unlinkSync(ownerPath);
  fs.fsyncSync(ownerDirectoryFd);
};
const signalRunnerGroup = (signal) => {
  if (!groupOwned || !runner || runner.pid !== runnerPid) {
    throw new Error("refusing to signal an unverified identity process group");
  }
  try { process.kill(-runnerPid, signal); }
  catch (error) { if (error.code !== "ESRCH") throw error; }
};
const beginGroupCleanup = (signal) => {
  if (cleaning || !runner) return;
  cleaning = true;
  try {
    if (groupOwned) signalRunnerGroup(signal);
    else runner.kill(signal);
  } catch (error) {
    process.stderr.write("identity watchdog initial cleanup failed: " + error.message + "\n");
  }
  cleanupTimer = setTimeout(() => {
    try {
      if (groupOwned) signalRunnerGroup("SIGKILL");
      else if (runner) runner.kill("SIGKILL");
    } catch (error) {
      process.stderr.write("identity watchdog escalation failed: " + error.message + "\n");
      preserveOwner = true;
    }
  }, 200);
};
const beginStop = (status, name, signal) => {
  if (!stopping) stopping = { status, name, signal };
  beginGroupCleanup(signal);
};
const finish = () => {
  if (finished) return;
  finished = true;
  clearInterval(parentWatch);
  if (cleanupTimer) clearTimeout(cleanupTimer);
  let status = stopping ? stopping.status : (targetResult && Number.isInteger(targetResult.status)
    ? targetResult.status : 1);
  try {
    if (!preserveOwner) removeOwner();
  } catch (error) {
    preserveOwner = true;
    status = 2;
    process.stderr.write("identity watchdog owner cleanup failed: " + error.message + "\n");
  }
  try { fs.closeSync(ownerFd); } catch {}
  try { fs.closeSync(ownerDirectoryFd); } catch {}
  if (preserveOwner) status = 2;
  process.exitCode = status;
  if (process.connected) {
    try { process.disconnect(); } catch {}
  }
};

try {
  if (!/^[0-9a-f]{32}$/.test(token) || process.ppid !== expectedPublisher) {
    throw new Error("identity watchdog parent or token mismatch");
  }
  const before = fs.lstatSync(ownerPath, { bigint: true });
  if (before.isSymbolicLink() || !before.isFile() || before.nlink !== 1n ||
      before.dev.toString() !== expectedDev || before.ino.toString() !== expectedIno) {
    throw new Error("identity watchdog owner record mismatch");
  }
  ownerFd = fs.openSync(ownerPath, flags.O_RDWR | flags.O_NOFOLLOW);
  const opened = fs.fstatSync(ownerFd, { bigint: true });
  if (!sameInode(before, opened)) throw new Error("identity owner changed while opening");
  ownerIdentity = { dev: opened.dev, ino: opened.ino };
  const ownerDirectory = path.dirname(ownerPath);
  ownerDirectoryFd = fs.openSync(ownerDirectory,
    flags.O_RDONLY | flags.O_NOFOLLOW | flags.O_DIRECTORY);
  writeOwner("watchdog-starting");
} catch (error) {
  process.stderr.write("identity watchdog initialization failed: " + error.message + "\n");
  process.exit(2);
}

for (const [signal, status] of [["SIGHUP", 129], ["SIGINT", 130], ["SIGTERM", 143]]) {
  process.on(signal, () => beginStop(status, signal, signal));
}
process.on("disconnect", () => beginStop(143, "publisher disconnect", "SIGTERM"));
const parentWatch = setInterval(() => {
  if (process.ppid !== expectedPublisher) {
    beginStop(143, "publisher parent loss", "SIGTERM");
  }
}, 25);
process.on("message", (message) => {
  if (!message || message.type !== "stop" || message.token !== token ||
      !["SIGHUP", "SIGINT", "SIGTERM"].includes(message.signal)) return;
  const status = message.signal === "SIGHUP" ? 129 : message.signal === "SIGINT" ? 130 : 143;
  beginStop(status, message.signal, message.signal);
});

const runnerProgram = Buffer.from(runnerBase64, "base64").toString("utf8");
try {
  runner = spawn(process.execPath,
    ["-e", runnerProgram, target, cwd, token, String(process.pid)], {
      detached: true,
      env: { ...process.env, LOOM_RELEASE_IDENTITY_OWNER: token },
      stdio: ["ignore", "pipe", "pipe", "ipc"],
    });
} catch (error) {
  process.stderr.write("identity runner could not start: " + error.message + "\n");
  targetResult = { status: 127, signal: null, startError: error.message };
  finish();
}
if (runner) {
  runner.stdout.pipe(process.stdout, { end: false });
  runner.stderr.pipe(process.stderr, { end: false });
  runner.once("error", (error) => {
    if (!targetResult) targetResult = { status: 127, signal: null, startError: error.message };
  });
  runner.on("message", (message) => {
    if (!message || message.token !== token) return;
    if (message.type === "runner-ready") {
      if (message.pid !== runner.pid || message.parentPid !== process.pid || groupOwned) {
        preserveOwner = true;
        beginStop(2, "runner ownership mismatch", "SIGTERM");
        return;
      }
      try { process.kill(-message.pid, 0); }
      catch {
        preserveOwner = true;
        beginStop(2, "runner process-group verification failure", "SIGTERM");
        return;
      }
      runnerPid = message.pid;
      groupOwned = true;
      try { writeOwner("group-owned"); }
      catch (error) {
        preserveOwner = true;
        beginStop(2, "owner update failure", "SIGTERM");
        return;
      }
      send({ type: "watchdog-ready", token, pid: process.pid,
        parentPid: process.ppid, runnerPid });
      if (stopping) beginGroupCleanup(stopping.signal);
    } else if (message.type === "target-result") {
      targetResult = message;
      if (message.startError) {
        process.stderr.write("identity query could not start: " + message.startError + "\n");
      }
      if (!stopping) beginGroupCleanup("SIGTERM");
    }
  });
  runner.once("close", () => {
    if (!cleaning) {
      preserveOwner = true;
      process.stderr.write("identity runner exited outside verified group cleanup\n");
    }
    finish();
  });
}
`;

const pollControl = () => {
  try {
    recheckSupervision();
    const stat = fs.fstatSync(controlFd, { bigint: true });
    if (stat.size < BigInt(controlOffset)) throw new Error("publisher control file was truncated");
    const available = Number(stat.size - BigInt(controlOffset));
    if (available > 64 * 1024) throw new Error("publisher control input exceeded 64 KiB");
    if (available > 0) {
      const buffer = Buffer.allocUnsafe(available);
      const count = fs.readSync(controlFd, buffer, 0, available, controlOffset);
      controlOffset += count;
      controlRemainder += buffer.subarray(0, count).toString("utf8");
      const lines = controlRemainder.split("\n");
      controlRemainder = lines.pop();
      for (const line of lines) {
        const [messageToken, signal, extra] = line.split("\t");
        if (messageToken !== token || extra !== undefined ||
            !["SIGHUP", "SIGINT", "SIGTERM"].includes(signal)) {
          throw new Error(`invalid publisher control message: ${JSON.stringify(line)}`);
        }
        const status = signal === "SIGHUP" ? 129 : signal === "SIGINT" ? 130 : 143;
        requestInterruption(status, signal, signal);
      }
    }
  } catch (error) {
    requestInterruption(2, `publisher control failure: ${error.message}`, "SIGTERM");
  }
};

const runIdentity = (entry, args, label, allowInterrupted) => new Promise((resolve, reject) => {
  throwIfInterrupted(allowInterrupted);
  if (args.length !== 2 || args[0] !== "version" || args[1] !== "--json") {
    reject(new Error(`${label} identity invocation arguments are not exact`));
    return;
  }
  const identityToken = randomBytes(16).toString("hex");
  let owner;
  try { owner = createIdentityOwner(identityToken, label); }
  catch (error) { reject(error); return; }
  let child;
  try {
    child = spawn(process.execPath, ["-e", identityWatchdogProgram, entry, sourceRoot,
      identityToken, owner.path, owner.identity.dev.toString(), owner.identity.ino.toString(),
      String(process.pid), Buffer.from(identityRunnerProgram, "utf8").toString("base64")], {
        detached: true,
        cwd: sourceRoot,
        env: process.env,
        stdio: ["ignore", "pipe", "pipe", "ipc"],
      });
  } catch (error) {
    try { removeUnlaunchedOwner(owner, label); } catch {}
    reject(new Error(`${label} identity query could not start: ${error.message}`));
    return;
  }
  closeFd(owner.fd);
  owner.fd = undefined;
  const ownedChild = { child, token: identityToken, ready: false };
  activeChild = ownedChild;
  const stdout = [];
  const stderr = [];
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let outputError = null;
  const collect = (chunks, kind) => (chunk) => {
    const next = (kind === "stdout" ? stdoutBytes : stderrBytes) + chunk.length;
    if (kind === "stdout") stdoutBytes = next;
    else stderrBytes = next;
    if (next > 1024 * 1024) {
      outputError = new Error(`${label} identity ${kind} exceeded 1 MiB`);
      stopActiveIdentity("SIGTERM");
      return;
    }
    chunks.push(chunk);
  };
  child.stdout.on("data", collect(stdout, "stdout"));
  child.stderr.on("data", collect(stderr, "stderr"));
  child.on("message", (message) => {
    if (!message || message.type !== "watchdog-ready" || message.token !== identityToken ||
        message.pid !== child.pid || message.parentPid !== process.pid ||
        !Number.isInteger(message.runnerPid) || message.runnerPid <= 1) {
      outputError = new Error(`${label} identity watchdog ownership handshake failed`);
      stopActiveIdentity("SIGTERM");
      return;
    }
    ownedChild.ready = true;
    if (interruption && !allowInterrupted) stopActiveIdentity(interruption.signal);
  });
  let startError = null;
  child.once("error", (error) => { startError = error; });
  child.once("close", (status, signal) => {
    if (activeChild === ownedChild) activeChild = null;
    if (!ownedChild.ready) {
      outputError = outputError || new Error(`${label} identity watchdog never established owned-group readiness`);
    }
    if (lstatOptional(owner.path)) {
      outputError = outputError || new Error(`${label} identity watchdog left an owned quarantine record`);
    }
    if (interruption && !allowInterrupted) {
      reject(new InterruptedError(interruption.name));
      return;
    }
    if (outputError) { reject(outputError); return; }
    if (startError) {
      reject(new Error(`${label} identity query could not start: ${startError.message}`));
      return;
    }
    const stderrText = Buffer.concat(stderr).toString("utf8").trim();
    if (status !== 0) {
      const statusText = status === null ? "no exit status" : `status ${status}`;
      const signalText = signal ? ` signal ${signal}` : "";
      reject(new Error(`${label} identity query failed with ${statusText}${signalText}${stderrText ? `: ${stderrText}` : ""}`));
      return;
    }
    resolve(Buffer.concat(stdout).toString("utf8").trim());
  });
});
const queryIdentity = async (entry, label, revision, guards, expectedFile,
  { allowInterrupted = false } = {}) => {
  assertOwnedPath(entry, expectedFile, label, guards, { executable: true, links: 1n });
  const raw = await runIdentity(entry, ["version", "--json"], label, allowInterrupted);
  assertOwnedPath(entry, expectedFile, label, guards, { executable: true, links: 1n });
  return validateIdentity(raw, label, revision);
};
const writePhase = (phase) => {
  if (!markerPresent) return;
  assertOwnedPath(marker, markerIdentity, "transaction marker", releaseGuards, { links: 1n });
  const bytes = Buffer.from(`${JSON.stringify({
    schema: "loom.release-transaction.v1", phase, token, expectedRevision,
    releaseBinary, previousBinary, stage, rollback, previousHold,
  })}\n`, "utf8");
  fs.ftruncateSync(markerFd, 0);
  writeAll(markerFd, bytes);
  fs.fsyncSync(markerFd);
  assertOwnedPath(marker, markerIdentity, "transaction marker", releaseGuards, { links: 1n });
};
const unlinkOwned = (entry, expected, label) => {
  assertOwnedPath(entry, expected, label, releaseGuards, { links: 1n });
  fs.unlinkSync(entry);
  recheckGuards(releaseGuards);
  if (lstatOptional(entry)) throw new Error(`${label} still exists after unlink: ${entry}`);
};
const removeMarker = () => {
  if (!markerPresent) return;
  unlinkOwned(marker, markerIdentity, "transaction marker");
  markerPresent = false;
};

const verifyRestoredGeneration = async (fd, entry, identity, bytes, claim, label) => {
  assertOwnedPath(entry, identity, label, releaseGuards, { executable: true, links: 1n });
  if (!bytes) throw new Error(`${label} lacks a pre-publication byte baseline`);
  const before = hashFd(fd, `${label} before identity`);
  const restoredClaim = await queryIdentity(entry, label, null, releaseGuards, identity,
    { allowInterrupted: true });
  const after = hashFd(fd, `${label} after identity`);
  if (!sameBytes(before, bytes) || !sameBytes(after, bytes) ||
      (claim && restoredClaim.json !== claim.json)) {
    throw new Error(`${label} does not match its verified pre-publication generation`);
  }
};

const rollbackPublication = async () => {
  if (committed) return;
  recovering = true;
  try { writePhase("rolling-back"); } catch {}
  recheckGuards(releaseGuards);
  if (candidateLocation === "stage" && rollbackLocation === rollback) {
    assertOwnedPath(releaseBinary, priorIdentity, "prior release", releaseGuards,
      { executable: true, links: 2n });
    assertOwnedPath(rollback, priorIdentity, "rollback generation", releaseGuards,
      { executable: true, links: 2n });
    fs.unlinkSync(rollback);
    rollbackLocation = null;
    recheckGuards(releaseGuards);
    assertOwnedPath(releaseBinary, priorIdentity, "prior release", releaseGuards,
      { executable: true, links: 1n });
    fsyncGuard(releaseGuards[releaseGuards.length - 1]);
  }
  if (candidateLocation === "release") {
    assertOwnedPath(releaseBinary, stageIdentity, "published candidate", releaseGuards,
      { executable: true, links: 1n });
    if (lstatOptional(stage)) throw new Error(`cannot quarantine candidate because staging path is occupied: ${stage}`);
    fs.renameSync(releaseBinary, stage);
    candidateLocation = "stage";
    recheckGuards(releaseGuards);
    fsyncGuard(releaseGuards[releaseGuards.length - 1]);
  }
  if (rollbackLocation) {
    if (lstatOptional(releaseBinary)) throw new Error(`cannot restore prior release because destination is occupied: ${releaseBinary}`);
    assertOwnedPath(rollbackLocation, priorIdentity, "rollback generation", releaseGuards,
      { executable: true, links: 1n });
    fs.renameSync(rollbackLocation, releaseBinary);
    rollbackLocation = null;
    recheckGuards(releaseGuards);
    fsyncGuard(releaseGuards[releaseGuards.length - 1]);
    assertOwnedPath(releaseBinary, priorIdentity, "restored prior release", releaseGuards,
      { executable: true, links: 1n });
  }
  if (olderPreviousLocation) {
    if (lstatOptional(previousBinary)) {
      throw new Error(`cannot restore the older previous generation because its destination is occupied: ${previousBinary}`);
    }
    assertOwnedPath(olderPreviousLocation, olderPreviousIdentity, "held older previous generation",
      releaseGuards, { executable: true, links: 1n });
    fs.renameSync(olderPreviousLocation, previousBinary);
    olderPreviousLocation = null;
    recheckGuards(releaseGuards);
    fsyncGuard(releaseGuards[releaseGuards.length - 1]);
    assertOwnedPath(previousBinary, olderPreviousIdentity, "restored older previous generation",
      releaseGuards, { executable: true, links: 1n });
  }
  if (priorFd !== undefined) {
    await verifyRestoredGeneration(priorFd, releaseBinary, priorIdentity, priorBytes, priorClaim,
      "restored prior release");
  }
  if (olderPreviousFd !== undefined) {
    await verifyRestoredGeneration(olderPreviousFd, previousBinary, olderPreviousIdentity,
      olderPreviousBytes, olderPreviousClaim, "restored older previous generation");
  }
  if (candidateLocation === "stage") {
    unlinkOwned(stage, stageIdentity, "owned staging candidate");
    candidateLocation = null;
  }
  removeMarker();
  if (releaseGuards.length > 0) fsyncGuard(releaseGuards[releaseGuards.length - 1]);
};

(async () => {
try {
  initializeSupervision();
  pollControl();
  controlWatch = setInterval(pollControl, 25);
  for (const [root, label] of [[sourceRoot, "private build root"], [releaseRoot, "Loom root"]]) {
    const stat = fs.lstatSync(root, { bigint: true });
    if (stat.isSymbolicLink() || !stat.isDirectory() || fs.realpathSync(root) !== root) {
      throw new Error(`${label} must be addressed by its physical directory path: ${root}`);
    }
  }

  const sourceRootGuard = pinDirectory(sourceRoot, "private build root", sourceRoot, []);
  const buildLakeGuard = pinDirectory(buildLake, "private build .lake", sourceRoot, [sourceRootGuard]);
  const buildGuard = pinDirectory(buildDirectory, "private build directory", sourceRoot,
    [sourceRootGuard, buildLakeGuard]);
  const buildBinGuard = pinDirectory(buildBinDirectory, "private build bin directory", sourceRoot,
    [sourceRootGuard, buildLakeGuard, buildGuard]);
  sourceGuards = [sourceRootGuard, buildLakeGuard, buildGuard, buildBinGuard];
  const source = openRegular(buildBinary, "built core", sourceGuards, { executable: true });
  sourceFd = source.fd;

  const releaseRootGuard = pinDirectory(releaseRoot, "Loom root", releaseRoot, []);
  const releaseLakeGuard = ensurePinnedDirectory(releaseLake, ".lake", releaseRoot,
    [releaseRootGuard], 0o755);
  const releaseDirectoryGuard = ensurePinnedDirectory(releaseDirectory, "release directory", releaseRoot,
    [releaseRootGuard, releaseLakeGuard], 0o755);
  releaseGuards = [releaseRootGuard, releaseLakeGuard, releaseDirectoryGuard];

  recheckGuards(releaseGuards);
  const interrupted = fs.readdirSync(releaseDirectory).filter((name) =>
    name === ".loom.stage" || name.startsWith(".loom.stage.") ||
    name === ".loom.rollback" || name.startsWith(".loom.rollback.") ||
    name === ".loom.previous-hold" || name.startsWith(".loom.previous-hold.") ||
    name === ".loom.transaction" || name.startsWith(".loom.transaction."));
  recheckGuards(releaseGuards);
  if (interrupted.length > 0) {
    throw new Error(`interrupted release state requires inspection/recovery: ${interrupted.join(", ")}`);
  }
  const existingPrevious = lstatOptional(previousBinary);

  const existingRelease = lstatOptional(releaseBinary);
  if (existingRelease) {
    const prior = openRegular(releaseBinary, "prior release", releaseGuards, { executable: true });
    priorFd = prior.fd;
    priorIdentity = prior.identity;
    priorBytes = hashFd(priorFd, "prior release before identity");
    priorClaim = await queryIdentity(releaseBinary, "prior release", null, releaseGuards, priorIdentity);
    const priorAfterIdentity = hashFd(priorFd, "prior release after identity");
    if (!sameBytes(priorBytes, priorAfterIdentity)) throw new Error("prior release changed during identity verification");
  } else if (existingPrevious) {
    throw new Error(`previous release exists without current destination; recover ${previousBinary} first`);
  }
  if (existingPrevious) {
    const older = openRegular(previousBinary, "older previous release", releaseGuards,
      { executable: true });
    olderPreviousFd = older.fd;
    olderPreviousIdentity = older.identity;
    olderPreviousBytes = hashFd(olderPreviousFd, "older previous release before identity");
    olderPreviousClaim = await queryIdentity(previousBinary, "older previous release", null,
      releaseGuards, olderPreviousIdentity);
    const olderAfterIdentity = hashFd(olderPreviousFd, "older previous release after identity");
    if (!sameBytes(olderPreviousBytes, olderAfterIdentity)) {
      throw new Error("older previous release changed during identity verification");
    }
  }
  await checkpoint();

  const markerFile = createOwnedFile(marker, "transaction marker", releaseGuards, 0o600);
  markerFd = markerFile.fd;
  markerIdentity = markerFile.identity;
  markerPresent = true;
  writePhase("staging");
  fsyncGuard(releaseDirectoryGuard);

  const stageFile = createOwnedFile(stage, "staging candidate", releaseGuards, 0o700);
  stageFd = stageFile.fd;
  stageIdentity = stageFile.identity;
  candidateLocation = "stage";
  const sourceBytes = copyAndHash(sourceFd, stageFd);
  assertOwnedPath(buildBinary, source.identity, "built core", sourceGuards,
    { executable: true, links: 1n });
  assertOwnedPath(stage, stageIdentity, "staging candidate", releaseGuards,
    { executable: true, links: 1n });
  writePhase("stage-copied");
  fsyncGuard(releaseDirectoryGuard);
  await checkpoint();

  const stagedClaim = await queryIdentity(stage, "staged release", expectedRevision,
    releaseGuards, stageIdentity);
  const stagedBytes = hashFd(stageFd, "staged release after identity");
  assertOwnedPath(stage, stageIdentity, "staging candidate", releaseGuards,
    { executable: true, links: 1n });
  if (!sameBytes(sourceBytes, stagedBytes)) throw new Error("staged bytes differ from descriptor-bound built core bytes");

  fs.fchmodSync(stageFd, 0o755);
  fs.fsyncSync(stageFd);
  const readyBytes = hashFd(stageFd, "ready staged release");
  assertOwnedPath(stage, stageIdentity, "ready staging candidate", releaseGuards,
    { executable: true, links: 1n });
  if (!sameBytes(stagedBytes, readyBytes) || readyBytes.mode !== 0o755) {
    throw new Error("staged release changed while applying final executable mode");
  }
  await checkpoint();

  if (testHook === "replace-release-parent-before-rename") {
    const displaced = `${releaseDirectory}.selftest-moved.${token}`;
    fs.renameSync(releaseDirectory, displaced);
    fs.mkdirSync(releaseDirectory, { mode: 0o700 });
    recheckGuards(releaseGuards);
  }

  if (priorFd !== undefined) {
    writePhase("backing-up-prior");
    recheckGuards(releaseGuards);
    if (lstatOptional(rollback)) throw new Error(`rollback path unexpectedly exists: ${rollback}`);
    fs.linkSync(releaseBinary, rollback);
    rollbackLocation = rollback;
    recheckGuards(releaseGuards);
    assertOwnedPath(releaseBinary, priorIdentity, "prior release", releaseGuards,
      { executable: true, links: 2n });
    assertOwnedPath(rollback, priorIdentity, "rollback generation", releaseGuards,
      { executable: true, links: 2n });
    fsyncGuard(releaseDirectoryGuard);
    writePhase("prior-backed-up");
    if (testHook === "fail-after-backup") throw new Error("injected pre-rename backup failure");
  }
  await checkpoint();

  assertOwnedPath(stage, stageIdentity, "ready staging candidate", releaseGuards,
    { executable: true, links: 1n });
  if (priorFd === undefined && lstatOptional(releaseBinary)) {
    throw new Error(`release destination appeared before atomic rename: ${releaseBinary}`);
  }
  fs.renameSync(stage, releaseBinary);
  candidateLocation = "release";
  recheckGuards(releaseGuards);
  assertOwnedPath(releaseBinary, stageIdentity, "published candidate", releaseGuards,
    { executable: true, links: 1n });
  if (lstatOptional(stage)) throw new Error(`staging path still exists after atomic rename: ${stage}`);
  if (rollbackLocation) {
    assertOwnedPath(rollback, priorIdentity, "rollback generation", releaseGuards,
      { executable: true, links: 1n });
  }
  fsyncGuard(releaseDirectoryGuard);
  writePhase("candidate-published");

  if (testHook === "fail-after-rename") throw new Error("injected post-rename verification failure");

  finalClaim = await queryIdentity(releaseBinary, "published release", expectedRevision,
    releaseGuards, stageIdentity);
  finalBytes = hashFd(stageFd, "published release after final identity");
  assertOwnedPath(releaseBinary, stageIdentity, "published release", releaseGuards,
    { executable: true, links: 1n });
  if (finalClaim.json !== stagedClaim.json || !sameBytes(finalBytes, readyBytes) ||
      !sameInode(finalBytes, stageIdentity) || finalBytes.mode !== 0o755) {
    throw new Error("published release identity, bytes, inode, or mode differ from the verified stage");
  }
  writePhase("final-verified");
  await checkpoint();

  if (rollbackLocation) {
    assertOwnedPath(rollback, priorIdentity, "rollback generation", releaseGuards,
      { executable: true, links: 1n });
    if (existingPrevious) {
      const olderBefore = hashFd(olderPreviousFd, "older previous generation before hold");
      const olderClaim = await queryIdentity(previousBinary, "older previous generation before hold",
        null, releaseGuards, olderPreviousIdentity);
      const olderAfter = hashFd(olderPreviousFd, "older previous generation after hold identity");
      if (!sameBytes(olderBefore, olderPreviousBytes) ||
          !sameBytes(olderAfter, olderPreviousBytes) || olderClaim.json !== olderPreviousClaim.json) {
        throw new Error("older previous generation changed before transactional rotation");
      }
      if (lstatOptional(previousHold)) {
        throw new Error(`older-previous hold path unexpectedly exists: ${previousHold}`);
      }
      writePhase("holding-older-previous");
      recheckGuards(releaseGuards);
      fs.renameSync(previousBinary, previousHold);
      olderPreviousLocation = previousHold;
      recheckGuards(releaseGuards);
      assertOwnedPath(previousHold, olderPreviousIdentity, "held older previous generation",
        releaseGuards, { executable: true, links: 1n });
      fsyncGuard(releaseDirectoryGuard);
      await checkpoint();
    }
    if (lstatOptional(previousBinary)) {
      throw new Error(`previous-generation destination is occupied before rotation: ${previousBinary}`);
    }
    writePhase("rotating-prior");
    recheckGuards(releaseGuards);
    fs.renameSync(rollback, previousBinary);
    rollbackLocation = previousBinary;
    recheckGuards(releaseGuards);
    assertOwnedPath(previousBinary, priorIdentity, "recoverable previous generation", releaseGuards,
      { executable: true, links: 1n });
    const preservedBefore = hashFd(priorFd, "recoverable previous generation before identity");
    const preservedClaim = await queryIdentity(previousBinary, "recoverable previous generation",
      null, releaseGuards, priorIdentity);
    const preservedAfter = hashFd(priorFd, "recoverable previous generation after identity");
    if (!sameBytes(preservedBefore, priorBytes) || !sameBytes(preservedAfter, priorBytes) ||
        preservedClaim.json !== priorClaim.json) {
      throw new Error("recoverable previous generation changed during rotation");
    }
    fsyncGuard(releaseDirectoryGuard);
    writePhase("prior-rotated");
    await checkpoint();
    if (testHook === "fail-after-rotation") {
      throw new Error("injected post-rotation precommit failure");
    }
  }

  const commitBytes = hashFd(stageFd, "published release at commit boundary");
  assertOwnedPath(releaseBinary, stageIdentity, "published release at commit boundary",
    releaseGuards, { executable: true, links: 1n });
  if (!sameBytes(commitBytes, readyBytes) || !sameInode(commitBytes, stageIdentity) ||
      commitBytes.mode !== 0o755) {
    throw new Error("published release bytes, inode, or mode changed after final identity verification");
  }
  finalBytes = commitBytes;
  await checkpoint();

  if (reportPath !== "-") {
    if (testHook !== "none") throw new Error("self-test report is only valid for a successful publication");
    const record = (value) => ({
      sha256: value.sha256, size: value.size,
      dev: value.dev.toString(), ino: value.ino.toString(), mode: value.mode,
    });
    fs.writeFileSync(reportPath, `${JSON.stringify({
      source: record(sourceBytes), staged: record(stagedBytes), ready: record(readyBytes),
      final: record(finalBytes), identity: finalClaim.value,
      prior: priorBytes ? record(priorBytes) : null,
    })}\n`, { flag: "wx", mode: 0o600 });
  }

  writePhase("committed");
  fsyncGuard(releaseDirectoryGuard);
  await checkpoint();
  committed = true;
  if (olderPreviousLocation) {
    unlinkOwned(olderPreviousLocation, olderPreviousIdentity, "committed older previous hold");
    olderPreviousLocation = null;
    fsyncGuard(releaseDirectoryGuard);
  }
  removeMarker();
  fsyncGuard(releaseDirectoryGuard);
  await checkpoint();

  console.error(`release binary: ${releaseBinary}`);
  console.error(`release sha256: ${finalBytes.sha256}`);
  console.error(`release size: ${finalBytes.size} bytes`);
  if (rollbackLocation) console.error(`release previous: ${previousBinary}`);
  console.error("release filesystem assumption: cooperating, quiescent same-UID writers; portable Node path operations are not hostile-race-proof");
  console.error("release process assumption: identity descendants remain in the owned POSIX session; deliberate session escape is not portably containable");
  process.stdout.write(`${finalClaim.json}\n`);
} catch (error) {
  let rollbackError = null;
  if (!committed) {
    try { await rollbackPublication(); }
    catch (failure) { rollbackError = failure; }
  }
  console.error(`error: release publication failed: ${error.message}`);
  if (rollbackError) {
    console.error(`error: automatic rollback was incomplete: ${rollbackError.message}`);
    console.error(`action: preserve and inspect ${marker}, ${rollback}, ${previousHold}, ${stage}, ${releaseBinary}, and ${previousBinary}`);
    console.error("action: stop same-UID writers and reconcile every pinned parent identity before recovery or retry");
  } else if (committed && priorFd !== undefined) {
    console.error(`action: release was fully verified before this post-commit failure; prior generation remains at ${previousBinary}`);
  } else if (committed) {
    console.error("action: release was fully verified before this post-commit failure; no prior generation existed");
  } else if (priorFd !== undefined) {
    console.error(`action: prior release was restored and reverified at ${releaseBinary}`);
  } else {
    console.error("action: no prior release existed; the failed owned candidate was removed unless quarantined state was reported above");
  }
  process.exitCode = interruption ? interruption.status : 2;
} finally {
  clearInterval(supervisorWatch);
  if (controlWatch) clearInterval(controlWatch);
  closeFd(ownerDirectoryFd);
  closeFd(controlFd);
  closeFd(olderPreviousFd);
  closeFd(priorFd);
  closeFd(markerFd);
  closeFd(stageFd);
  closeFd(sourceFd);
  for (const guard of allGuards.reverse()) closeFd(guard.fd);
}
})().catch((error) => {
  console.error(`error: release publication supervisor failed: ${error.message}`);
  process.exitCode = interruption ? interruption.status : 2;
});
NODE
  PUBLISH_PID=$!
  PUBLISH_CHILD_OWNED=1
}

publish_release() {
  local output status
  output="$(mktemp "${TMPDIR:-/tmp}/loom-release-identity.XXXXXX")"
  start_publish_release "$output" "$@"
  if wait_publish_release; then
    status=0
  else
    status=$?
  fi
  if [[ -s "$output" ]]; then
    cat -- "$output"
  fi
  rm -f -- "$output"
  return "$status"
}

make_fake_binary() {
  local output="$1"
  local revision="$2"
  local engine="${3:-lean}"
  local duplicate="${4:-no}"
  local behavior="${5:-normal}"
  local started_file="${6:-}"
  local continue_file="${7:-}"
  local identity_json
  if [[ "$duplicate" == "yes" ]]; then
    identity_json="{\"engine\":\"not-lean\",\"engine\":\"$engine\",\"engineVersion\":\"0.2.0-preview.0\",\"protocolVersion\":\"loom.cli.v1\",\"coreRevision\":\"$revision\",\"sourceRepository\":\"https://github.com/theoriclabs/agent-convert-lean\",\"sourcePath\":\".\",\"targetTriple\":\"self-test-target\",\"wireSchemas\":[\"loom.transcript.v0\"]}"
  else
    identity_json="{\"engine\":\"$engine\",\"engineVersion\":\"0.2.0-preview.0\",\"protocolVersion\":\"loom.cli.v1\",\"coreRevision\":\"$revision\",\"sourceRepository\":\"https://github.com/theoriclabs/agent-convert-lean\",\"sourcePath\":\".\",\"targetTriple\":\"self-test-target\",\"wireSchemas\":[\"loom.transcript.v0\"]}"
  fi
  mkdir -p -- "$(dirname -- "$output")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'if [[ "$#" -ne 2 || "$1" != "version" || "$2" != "--json" ]]; then exit 64; fi'
    if [[ "$behavior" == "block" || "$behavior" == "gate" ||
          "$behavior" == "descendant-block" ]]; then
      [[ -n "$started_file" ]] || die "$behavior fake binary requires a started-file path"
      printf 'started_file=%q\n' "$started_file"
      if [[ "$behavior" == "block" ]]; then
        printf '%s\n' 'printf "%s\n" "$$" >"$started_file"'
        printf '%s\n' "trap 'exit 129' HUP"
        printf '%s\n' "trap 'exit 130' INT"
        printf '%s\n' "trap 'exit 143' TERM"
        printf '%s\n' 'while :; do sleep 0.1; done'
      elif [[ "$behavior" == "gate" ]]; then
        [[ -n "$continue_file" ]] || die "gate fake binary requires a continue-file path"
        printf 'continue_file=%q\n' "$continue_file"
        printf '%s\n' 'printf "%s\n" "$$" >"$started_file"'
        printf '%s\n' 'while [[ ! -e "$continue_file" ]]; do sleep 0.05; done'
      else
        printf '%s\n' 'heartbeat_file="${started_file}.heartbeat"'
        printf '%s\n' 'stopped_file="${started_file}.descendant-stopped"'
        printf '%s\n' '('
        printf '%s\n' "  trap 'printf \"%s\\n\" stopped >\"\$stopped_file\"; exit 0' HUP INT TERM"
        printf '%s\n' '  while :; do printf "." >>"$heartbeat_file"; sleep 0.02; done'
        printf '%s\n' ') &'
        printf '%s\n' 'descendant_pid=$!'
        printf '%s\n' 'printf "%s %s\n" "$$" "$descendant_pid" >"$started_file"'
        printf '%s\n' "trap 'wait \"\$descendant_pid\" 2>/dev/null || true; exit 129' HUP"
        printf '%s\n' "trap 'wait \"\$descendant_pid\" 2>/dev/null || true; exit 130' INT"
        printf '%s\n' "trap 'wait \"\$descendant_pid\" 2>/dev/null || true; exit 143' TERM"
        printf '%s\n' 'while :; do sleep 0.1; done'
      fi
    elif [[ "$behavior" != "normal" ]]; then
      die "unknown fake binary behavior: $behavior"
    fi
    printf "printf '%%s\\n' '%s'\n" "$identity_json"
  } >"$output"
  chmod 755 "$output"
}

make_publish_fixture() {
  local source_root="$1"
  local revision="$2"
  local engine="${3:-lean}"
  local duplicate="${4:-no}"
  local behavior="${5:-normal}"
  local started_file="${6:-}"
  local continue_file="${7:-}"
  make_fake_binary "$source_root/.lake/build/bin/loom" "$revision" "$engine" "$duplicate" \
    "$behavior" "$started_file" "$continue_file"
}

file_identity() {
  "$NODE_BIN" - "$1" <<'NODE'
const fs = require("node:fs");
const stat = fs.lstatSync(process.argv[2], { bigint: true });
if (stat.isSymbolicLink() || !stat.isFile()) process.exit(2);
process.stdout.write(`${stat.dev}\t${stat.ino}`);
NODE
}

wait_for_file() {
  local entry="$1"
  local _pid="$2"
  local attempt
  for attempt in {1..200}; do
    [[ -s "$entry" ]] && return 0
    sleep 0.05
  done
  return 1
}

assert_descendant_stopped() {
  local started_file="$1"
  local label="$2"
  local heartbeat="${started_file}.heartbeat"
  local before after
  wait_for_file "$heartbeat" 0 || die "$label descendant did not produce a heartbeat"
  before="$(wc -c <"$heartbeat" | tr -d '[:space:]')"
  sleep 0.3
  after="$(wc -c <"$heartbeat" | tr -d '[:space:]')"
  [[ "$before" == "$after" ]] || die "$label descendant continued after owned-group cleanup"
  [[ -s "${started_file}.descendant-stopped" ]] || \
    die "$label descendant did not observe group termination"
}

run_private_lake_build() {
  local build_root="$1"
  local revision="$2"
  local lake_bin="$3"
  (cd -P -- "$build_root" &&
    "$lake_bin" -R -H --no-cache -KcoreRevision="$revision" build loom) >&2
}

forward_publish_signal() {
  local status="$1"
  local signal="$2"
  local wire_signal
  case "$signal" in
    HUP|SIGHUP) wire_signal="SIGHUP" ;;
    INT|SIGINT) wire_signal="SIGINT" ;;
    TERM|SIGTERM) wire_signal="SIGTERM" ;;
    *) printf '%s\n' "error: invalid publisher signal request: $signal" >&2; exit 2 ;;
  esac
  trap '' HUP INT TERM
  if [[ "$PUBLISH_CHILD_OWNED" -eq 1 && -n "$PUBLISH_CONTROL_PATH" &&
        -n "$PUBLISH_TOKEN" ]]; then
    if ! printf '%s\t%s\n' "$PUBLISH_TOKEN" "$wire_signal" >>"$PUBLISH_CONTROL_PATH"; then
      printf '%s\n' "error: could not write the owned publisher control channel" >&2
    fi
    if wait_publish_release; then :; else :; fi
  fi
  exit "$status"
}

expect_rejected() {
  local log_directory="$1"
  local label="$2"
  local expected="$3"
  shift 3
  local status
  : >"$log_directory/rejected.stdout"
  : >"$log_directory/rejected.stderr"
  if "$@" >"$log_directory/rejected.stdout" 2>"$log_directory/rejected.stderr"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -ne 2 ]]; then
    die "$label self-test expected status 2, got $status"
  fi
  if [[ -s "$log_directory/rejected.stdout" ]]; then
    die "$label self-test emitted stdout on rejection"
  fi
  if ! grep -F -q -- "$expected" "$log_directory/rejected.stderr"; then
    printf 'self-test diagnostic for %s:\n' "$label" >&2
    sed -n '1,30p' "$log_directory/rejected.stderr" >&2
    die "$label self-test did not report: $expected"
  fi
}

self_test() {
  local temp revision old_revision older_revision source_root release_root token output report prior_copy older_copy
  local repo snapshot_workspace snapshot revision_from_repo prior_identity current_identity previous_identity
  local publisher_pid sentinel_pid status started continue_file stdout_path
  local owner_directory owner_record supervision_directory
  revision="0123456789abcdef0123456789abcdef01234567"
  old_revision="89abcdef0123456789abcdef0123456789abcdef"
  older_revision="fedcba9876543210fedcba9876543210fedcba98"
  temp="$(mktemp -d "${TMPDIR:-/tmp}/loom-build-release-self-test.XXXXXX")"
  temp="$(cd -P -- "$temp" && pwd -P)"
  trap 'rm -rf -- "$temp"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  source_root="$temp/success-source"
  release_root="$temp/success-release"
  make_publish_fixture "$source_root" "$revision"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  make_fake_binary "$release_root/.lake/release/.loom.previous" "$older_revision"
  prior_copy="$temp/prior-copy"
  older_copy="$temp/older-copy"
  cp "$release_root/.lake/release/loom" "$prior_copy"
  cp "$release_root/.lake/release/.loom.previous" "$older_copy"
  prior_identity="$(file_identity "$release_root/.lake/release/loom")"
  token="$(new_token)"
  report="$temp/success-report.json"
  output="$(publish_release "$source_root" "$release_root" "$revision" "$token" none "$report" \
    2>"$temp/success.stderr")"
  "$NODE_BIN" - "$output" "$report" \
    "$source_root/.lake/build/bin/loom" "$release_root/.lake/release/loom" "$temp/success.stderr" <<'NODE'
const fs = require("node:fs");
const { createHash } = require("node:crypto");
const [stdout, reportPath, sourcePath, finalPath, stderrPath] = process.argv.slice(2);
const identity = JSON.parse(stdout);
if (stdout !== JSON.stringify(identity)) throw new Error("success stdout is not one canonical JSON object");
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const hash = (entry) => createHash("sha256").update(fs.readFileSync(entry)).digest("hex");
const size = (entry) => fs.statSync(entry).size.toString();
for (const key of ["source", "staged", "ready", "final"]) {
  if (report[key].sha256 !== report.source.sha256 || report[key].size !== report.source.size) {
    throw new Error(`source/stage/final byte record mismatch at ${key}`);
  }
}
if (report.source.sha256 !== hash(sourcePath) || report.final.sha256 !== hash(finalPath) ||
    report.source.size !== size(sourcePath) || report.final.size !== size(finalPath)) {
  throw new Error("reported digest/size does not match source/final bytes");
}
const stderr = fs.readFileSync(stderrPath, "utf8");
const stderrDigest = stderr.match(/^release sha256: ([0-9a-f]{64})$/m)?.[1];
const stderrSize = stderr.match(/^release size: ([0-9]+) bytes$/m)?.[1];
if (stderrDigest !== report.final.sha256 || stderrSize !== report.final.size) {
  throw new Error("stderr digest/size does not match the verified final record");
}
if (report.staged.dev !== report.final.dev || report.staged.ino !== report.final.ino ||
    (report.source.dev === report.final.dev && report.source.ino === report.final.ino)) {
  throw new Error("stage/final inode continuity or source/stage separation failed");
}
NODE
  cmp -s "$source_root/.lake/build/bin/loom" "$release_root/.lake/release/loom" || \
    die "successful publication final bytes differ from source"
  cmp -s "$prior_copy" "$release_root/.lake/release/.loom.previous" || \
    die "successful publication did not preserve the distinct prior generation"
  previous_identity="$(file_identity "$release_root/.lake/release/.loom.previous")"
  [[ "$previous_identity" == "$prior_identity" ]] || \
    die "successful publication did not preserve the prior inode during rotation"
  cmp -s "$older_copy" "$release_root/.lake/release/.loom.previous" && \
    die "successful publication retained the superseded older previous bytes"
  cmp -s "$prior_copy" "$release_root/.lake/release/loom" && \
    die "successful publication did not replace the prior bytes"
  grep -F -q -- "release binary: $release_root/.lake/release/loom" "$temp/success.stderr" || \
    die "successful publication did not report its path on stderr"
  grep -E -q -- '^release sha256: [0-9a-f]{64}$' "$temp/success.stderr" || \
    die "successful publication did not report SHA-256 on stderr"
  grep -E -q -- '^release size: [1-9][0-9]* bytes$' "$temp/success.stderr" || \
    die "successful publication did not report size on stderr"
  [[ -z "$(find "$release_root/.lake/release" -maxdepth 1 \
    \( -name '.loom.stage*' -o -name '.loom.rollback*' -o -name '.loom.previous-hold*' \
       -o -name '.loom.transaction*' \) -print)" ]] || \
    die "successful publication left transactional state"

  source_root="$temp/new-directory-source"
  release_root="$temp/new-directory-release"
  make_publish_fixture "$source_root" "$revision"
  mkdir -p -- "$release_root"
  token="$(new_token)"
  output="$(publish_release "$source_root" "$release_root" "$revision" "$token" none - \
    2>"$temp/new-directory.stderr")"
  "$NODE_BIN" -e 'const value=JSON.parse(process.argv[1]); if (JSON.stringify(value)!==process.argv[1]) process.exit(2)' \
    "$output"
  cmp -s "$source_root/.lake/build/bin/loom" "$release_root/.lake/release/loom" || \
    die "new-directory publication did not install exact source bytes"
  [[ ! -e "$release_root/.lake/release/.loom.previous" ]] || \
    die "new-directory publication created a previous generation without a prior release"
  validate_release_paths "$release_root"

  source_root="$temp/rollback-source"
  release_root="$temp/rollback-release"
  make_publish_fixture "$source_root" "$revision"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  cp "$release_root/.lake/release/loom" "$temp/rollback-prior"
  token="$(new_token)"
  expect_rejected "$temp" "post-rename rollback" "injected post-rename verification failure" \
    publish_release "$source_root" "$release_root" "$revision" "$token" fail-after-rename -
  cmp -s "$temp/rollback-prior" "$release_root/.lake/release/loom" || \
    die "post-rename failure did not restore exact prior bytes"
  [[ -z "$(find "$release_root/.lake/release" -maxdepth 1 \
    \( -name '.loom.stage*' -o -name '.loom.rollback*' -o -name '.loom.previous-hold*' \
       -o -name '.loom.transaction*' \) -print)" ]] || \
    die "successful rollback left transactional state"

  source_root="$temp/backup-rollback-source"
  release_root="$temp/backup-rollback-release"
  make_publish_fixture "$source_root" "$revision"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  cp "$release_root/.lake/release/loom" "$temp/backup-rollback-prior"
  token="$(new_token)"
  expect_rejected "$temp" "pre-rename backup rollback" "injected pre-rename backup failure" \
    publish_release "$source_root" "$release_root" "$revision" "$token" fail-after-backup -
  cmp -s "$temp/backup-rollback-prior" "$release_root/.lake/release/loom" || \
    die "pre-rename backup failure changed the prior release"
  [[ -z "$(find "$release_root/.lake/release" -maxdepth 1 \
    \( -name '.loom.stage*' -o -name '.loom.rollback*' -o -name '.loom.previous-hold*' \
       -o -name '.loom.transaction*' \) -print)" ]] || \
    die "pre-rename backup rollback left transactional state"

  source_root="$temp/rotation-rollback-source"
  release_root="$temp/rotation-rollback-release"
  make_publish_fixture "$source_root" "$revision"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  make_fake_binary "$release_root/.lake/release/.loom.previous" "$older_revision"
  cp "$release_root/.lake/release/loom" "$temp/rotation-current"
  cp "$release_root/.lake/release/.loom.previous" "$temp/rotation-previous"
  prior_identity="$(file_identity "$release_root/.lake/release/loom")"
  previous_identity="$(file_identity "$release_root/.lake/release/.loom.previous")"
  token="$(new_token)"
  expect_rejected "$temp" "post-rotation rollback" "injected post-rotation precommit failure" \
    publish_release "$source_root" "$release_root" "$revision" "$token" fail-after-rotation -
  cmp -s "$temp/rotation-current" "$release_root/.lake/release/loom" || \
    die "post-rotation failure did not restore current release bytes"
  cmp -s "$temp/rotation-previous" "$release_root/.lake/release/.loom.previous" || \
    die "post-rotation failure did not restore older previous bytes"
  current_identity="$(file_identity "$release_root/.lake/release/loom")"
  [[ "$current_identity" == "$prior_identity" ]] || \
    die "post-rotation failure did not restore the current release inode"
  current_identity="$(file_identity "$release_root/.lake/release/.loom.previous")"
  [[ "$current_identity" == "$previous_identity" ]] || \
    die "post-rotation failure did not restore the older previous inode"
  [[ -z "$(find "$release_root/.lake/release" -maxdepth 1 \
    \( -name '.loom.stage*' -o -name '.loom.rollback*' -o -name '.loom.previous-hold*' \
       -o -name '.loom.transaction*' \) -print)" ]] || \
    die "post-rotation rollback left transactional state"

  source_root="$temp/sigterm-source"
  release_root="$temp/sigterm-release"
  started="$temp/sigterm-started"
  stdout_path="$temp/sigterm.stdout"
  make_publish_fixture "$source_root" "$revision" lean no descendant-block "$started"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  cp "$release_root/.lake/release/loom" "$temp/sigterm-prior"
  prior_identity="$(file_identity "$release_root/.lake/release/loom")"
  token="$(new_token)"
  : >"$stdout_path"
  (
    PUBLISH_PID=""
    trap 'forward_publish_signal 129 HUP' HUP
    trap 'forward_publish_signal 130 INT' INT
    trap 'forward_publish_signal 143 TERM' TERM
    start_publish_release "$stdout_path" "$source_root" "$release_root" "$revision" "$token" none -
    if wait_publish_release; then exit 0; else exit $?; fi
  ) 2>"$temp/sigterm.stderr" &
  publisher_pid=$!
  wait_for_file "$started" "$publisher_pid" || \
    die "SIGTERM self-test publisher did not enter blocked staged identity"
  kill -TERM "$publisher_pid"
  if wait "$publisher_pid" 2>"$temp/sigterm-wait.stderr"; then status=0; else status=$?; fi
  [[ "$status" -eq 143 ]] || die "SIGTERM self-test expected status 143, got $status"
  [[ ! -s "$stdout_path" ]] || die "SIGTERM self-test emitted success stdout"
  assert_descendant_stopped "$started" "SIGTERM self-test"
  cmp -s "$temp/sigterm-prior" "$release_root/.lake/release/loom" || \
    die "SIGTERM self-test did not preserve prior release bytes"
  current_identity="$(file_identity "$release_root/.lake/release/loom")"
  [[ "$current_identity" == "$prior_identity" ]] || \
    die "SIGTERM self-test did not preserve the prior release inode"
  if ! grep -F -q -- "publication interrupted by SIGTERM" "$temp/sigterm.stderr"; then
    sed -n '1,40p' "$temp/sigterm.stderr" >&2
    die "SIGTERM self-test lacked an interruption diagnostic"
  fi
  grep -F -q -- "prior release was restored and reverified" "$temp/sigterm.stderr" || \
    die "SIGTERM self-test did not report prior re-verification"
  [[ -z "$(find "$release_root/.lake/release" -maxdepth 1 \
    \( -name '.loom.stage*' -o -name '.loom.rollback*' -o -name '.loom.previous-hold*' \
       -o -name '.loom.transaction*' \) -print)" ]] || \
    die "SIGTERM self-test left transactional state after rollback"

  source_root="$temp/sigkill-source"
  release_root="$temp/sigkill-release"
  started="$temp/sigkill-started"
  stdout_path="$temp/sigkill.stdout"
  make_publish_fixture "$source_root" "$revision" lean no descendant-block "$started"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  cp "$release_root/.lake/release/loom" "$temp/sigkill-prior"
  prior_identity="$(file_identity "$release_root/.lake/release/loom")"
  token="$(new_token)"
  : >"$stdout_path"
  start_publish_release "$stdout_path" "$source_root" "$release_root" "$revision" "$token" none - \
    2>"$temp/sigkill.stderr"
  publisher_pid="$PUBLISH_PID"
  wait_for_file "$started" "$publisher_pid" || \
    die "SIGKILL self-test publisher did not enter blocked staged identity"
  owner_directory="$PUBLISH_OWNER_DIRECTORY"
  supervision_directory="$PUBLISH_SUPERVISION_DIRECTORY"
  owner_record="$(find "$owner_directory" -maxdepth 1 -type f -name 'identity.*' -print)"
  [[ -n "$owner_record" && "$(printf '%s\n' "$owner_record" | wc -l | tr -d '[:space:]')" == "1" ]] || \
    die "SIGKILL self-test did not observe exactly one external identity owner"
  for _ in {1..200}; do
    grep -F -q -- '"state":"group-owned"' "$owner_record" && break
    sleep 0.01
  done
  "$NODE_BIN" - "$owner_record" <<'NODE'
const fs = require("node:fs");
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value.schema !== "loom.identity-owner.v1" || value.state !== "group-owned" ||
    !Number.isInteger(value.watchdogPid) || !Number.isInteger(value.runnerPid)) {
  throw new Error("SIGKILL identity owner did not record a verified watchdog/group");
}
NODE
  kill -KILL "$publisher_pid"
  if wait_publish_release 2>"$temp/sigkill-wait.stderr"; then status=0; else status=$?; fi
  [[ "$status" -eq 137 ]] || die "SIGKILL self-test expected status 137, got $status"
  [[ ! -s "$stdout_path" ]] || die "SIGKILL self-test emitted success stdout"
  assert_descendant_stopped "$started" "SIGKILL self-test"
  [[ ! -e "$supervision_directory" ]] || \
    die "SIGKILL self-test returned before external watchdog ownership retired"
  cmp -s "$temp/sigkill-prior" "$release_root/.lake/release/loom" || \
    die "SIGKILL self-test changed prior release bytes"
  current_identity="$(file_identity "$release_root/.lake/release/loom")"
  [[ "$current_identity" == "$prior_identity" ]] || \
    die "SIGKILL self-test changed the prior release inode"
  [[ -e "$release_root/.lake/release/.loom.stage.$token" && \
     -e "$release_root/.lake/release/.loom.transaction.$token" ]] || \
    die "SIGKILL self-test did not leave explicit quarantined transaction state"
  "$NODE_BIN" - "$release_root/.lake/release/.loom.transaction.$token" "$token" \
    "$release_root/.lake/release/.loom.stage.$token" <<'NODE'
const fs = require("node:fs");
const [marker, token, stage] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(marker, "utf8"));
if (value.schema !== "loom.release-transaction.v1" || value.phase !== "stage-copied" ||
    value.token !== token || value.stage !== stage) {
  throw new Error("SIGKILL marker does not describe the quarantined staged transaction");
}
NODE
  expect_rejected "$temp" "SIGKILL quarantine" "interrupted release state requires inspection/recovery" \
    validate_release_paths "$release_root"

  token="$(new_token)"
  (
    trap 'printf "%s\n" signaled >"$temp/reused-pid-signaled"; exit 99' TERM
    sleep 0.5
    printf '%s\n' completed >"$temp/reused-pid-completed"
  ) &
  sentinel_pid=$!
  if (
    create_publish_supervision "$token"
    PUBLISH_PID="$sentinel_pid"
    PUBLISH_CHILD_OWNED=1
    forward_publish_signal 143 TERM
  ) 2>"$temp/reused-pid.stderr"; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 143 ]] || die "late-signal self-test expected status 143, got $status"
  if wait "$sentinel_pid"; then status=0; else status=$?; fi
  [[ "$status" -eq 0 && -s "$temp/reused-pid-completed" &&
     ! -e "$temp/reused-pid-signaled" ]] || \
    die "late-signal self-test signaled a process represented by a stale/reused PID"

  source_root="$temp/replacement-source"
  release_root="$temp/replacement-release"
  started="$temp/replacement-started"
  continue_file="$temp/replacement-continue"
  stdout_path="$temp/replacement.stdout"
  make_publish_fixture "$source_root" "$revision" lean no gate "$started" "$continue_file"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  cp "$release_root/.lake/release/loom" "$temp/replacement-prior"
  prior_identity="$(file_identity "$release_root/.lake/release/loom")"
  token="$(new_token)"
  : >"$stdout_path"
  start_publish_release "$stdout_path" "$source_root" "$release_root" "$revision" "$token" none - \
    2>"$temp/replacement.stderr"
  publisher_pid="$PUBLISH_PID"
  wait_for_file "$started" "$publisher_pid" || \
    die "replacement-inode self-test did not enter staged identity"
  rm -f -- "$release_root/.lake/release/.loom.stage.$token"
  cp "$source_root/.lake/build/bin/loom" "$release_root/.lake/release/.loom.stage.$token"
  chmod 755 "$release_root/.lake/release/.loom.stage.$token"
  : >"$continue_file"
  if wait_publish_release; then status=0; else status=$?; fi
  [[ "$status" -eq 2 ]] || die "replacement-inode self-test expected status 2, got $status"
  [[ ! -s "$stdout_path" ]] || die "replacement-inode self-test emitted success stdout"
  grep -F -q -- "no longer names the owned regular inode" "$temp/replacement.stderr" || \
    die "replacement-inode self-test lacked the owned-inode rejection"
  cmp -s "$temp/replacement-prior" "$release_root/.lake/release/loom" || \
    die "replacement-inode rejection changed the prior release"
  current_identity="$(file_identity "$release_root/.lake/release/loom")"
  [[ "$current_identity" == "$prior_identity" ]] || \
    die "replacement-inode rejection changed the prior release inode"
  [[ -e "$release_root/.lake/release/.loom.stage.$token" ]] || \
    die "replacement-inode rejection deleted an unowned staging path"
  [[ -e "$release_root/.lake/release/.loom.transaction.$token" ]] || \
    die "replacement-inode rejection did not leave explicit fail-closed transaction state"

  source_root="$temp/parent-replacement-source"
  release_root="$temp/parent-replacement-release"
  make_publish_fixture "$source_root" "$revision"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  cp "$release_root/.lake/release/loom" "$temp/parent-replacement-prior"
  token="$(new_token)"
  expect_rejected "$temp" "release parent replacement" \
    "release directory changed identity at a path boundary" \
    publish_release "$source_root" "$release_root" "$revision" "$token" \
      replace-release-parent-before-rename -
  [[ ! -e "$release_root/.lake/release/loom" ]] || \
    die "parent-replacement self-test unexpectedly wrote through the replacement directory"
  cmp -s "$temp/parent-replacement-prior" \
    "$release_root/.lake/release.selftest-moved.$token/loom" || \
    die "parent-replacement self-test changed prior bytes in the displaced owned directory"
  [[ -e "$release_root/.lake/release.selftest-moved.$token/.loom.stage.$token" && \
     -e "$release_root/.lake/release.selftest-moved.$token/.loom.transaction.$token" ]] || \
    die "parent-replacement self-test did not preserve explicit state in the displaced directory"

  source_root="$temp/duplicate-source"
  release_root="$temp/duplicate-release"
  make_publish_fixture "$source_root" "$revision" lean yes
  mkdir -p -- "$release_root"
  token="$(new_token)"
  expect_rejected "$temp" "duplicate identity key" "duplicate JSON object key" \
    publish_release "$source_root" "$release_root" "$revision" "$token" none -

  release_root="$temp/lake-symlink"
  mkdir -p -- "$release_root" "$temp/outside-lake"
  ln -s "$temp/outside-lake" "$release_root/.lake"
  expect_rejected "$temp" ".lake symlink" ".lake must be a real directory" \
    validate_release_paths "$release_root"

  release_root="$temp/release-symlink"
  mkdir -p -- "$release_root/.lake" "$temp/outside-release"
  ln -s "$temp/outside-release" "$release_root/.lake/release"
  expect_rejected "$temp" "release-directory symlink" "release directory must be a real directory" \
    validate_release_paths "$release_root"

  release_root="$temp/destination-symlink"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$temp/outside-destination" "$old_revision"
  ln -s "$temp/outside-destination" "$release_root/.lake/release/loom"
  expect_rejected "$temp" "destination symlink" "release destination must not be a symbolic link" \
    validate_release_paths "$release_root"

  release_root="$temp/stale-transaction"
  mkdir -p -- "$release_root/.lake/release"
  : >"$release_root/.lake/release/.loom.transaction.stale"
  expect_rejected "$temp" "stale transaction" "interrupted release state requires inspection/recovery" \
    validate_release_paths "$release_root"

  release_root="$temp/stale-previous-hold"
  mkdir -p -- "$release_root/.lake/release"
  : >"$release_root/.lake/release/.loom.previous-hold.stale"
  expect_rejected "$temp" "stale previous hold" "interrupted release state requires inspection/recovery" \
    validate_release_paths "$release_root"

  release_root="$temp/stale-stage-symlink"
  mkdir -p -- "$release_root/.lake/release"
  ln -s "$temp/outside-lake" "$release_root/.lake/release/.loom.stage.stale"
  expect_rejected "$temp" "stale staging symlink" "interrupted release state requires inspection/recovery" \
    validate_release_paths "$release_root"

  release_root="$temp/nonregular-destination"
  mkdir -p -- "$release_root/.lake/release/loom"
  expect_rejected "$temp" "non-regular destination" "release destination must be a regular file" \
    validate_release_paths "$release_root"

  release_root="$temp/hardlinked-destination"
  mkdir -p -- "$release_root/.lake/release"
  make_fake_binary "$release_root/.lake/release/loom" "$old_revision"
  ln "$release_root/.lake/release/loom" "$release_root/release-alias"
  expect_rejected "$temp" "hard-linked destination" "release destination must have exactly one hard link" \
    validate_release_paths "$release_root"

  source_root="$temp/source-symlink"
  release_root="$temp/source-symlink-release"
  make_fake_binary "$temp/external-build" "$revision"
  mkdir -p -- "$source_root/.lake/build/bin" "$release_root"
  ln -s "$temp/external-build" "$source_root/.lake/build/bin/loom"
  token="$(new_token)"
  expect_rejected "$temp" "build-binary symlink" "built core must be a singly-linked regular non-symlink file" \
    publish_release "$source_root" "$release_root" "$revision" "$token" none -

  source_root="$temp/source-hardlink"
  release_root="$temp/source-hardlink-release"
  make_publish_fixture "$source_root" "$revision"
  mkdir -p -- "$release_root"
  ln "$source_root/.lake/build/bin/loom" "$source_root/build-alias"
  token="$(new_token)"
  expect_rejected "$temp" "hard-linked build source" "built core must be a singly-linked regular non-symlink file" \
    publish_release "$source_root" "$release_root" "$revision" "$token" none -

  source_root="$temp/source-parent-symlink"
  release_root="$temp/source-parent-symlink-release"
  mkdir -p -- "$source_root/.lake" "$temp/outside-build-parent/bin" "$release_root"
  make_fake_binary "$temp/outside-build-parent/bin/loom" "$revision"
  ln -s "$temp/outside-build-parent" "$source_root/.lake/build"
  token="$(new_token)"
  expect_rejected "$temp" "build-parent symlink" "private build directory must be a real directory" \
    publish_release "$source_root" "$release_root" "$revision" "$token" none -

  repo="$temp/snapshot-repo"
  mkdir -p -- "$repo/spec/loom"
  "$GIT_BIN" -C "$repo" init -q
  printf 'committed bytes\n' >"$repo/spec/loom/marker.txt"
  printf 'import Lake\n' >"$repo/spec/loom/lakefile.lean"
  printf 'leanprover/lean4:v4.28.0\n' >"$repo/spec/loom/lean-toolchain"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/spec/loom/tool.sh"
  chmod 755 "$repo/spec/loom/tool.sh"
  "$GIT_BIN" -C "$repo" add spec/loom
  "$GIT_BIN" -C "$repo" -c user.name=SelfTest -c user.email=self-test@example.invalid \
    commit -q -m snapshot
  revision_from_repo="$("$GIT_BIN" -C "$repo" rev-parse --verify 'HEAD^{commit}')"
  printf 'dirty worktree bytes\n' >"$repo/spec/loom/marker.txt"
  mkdir -p -- "$repo/spec/loom/.lake/build"
  printf 'cached build\n' >"$repo/spec/loom/.lake/build/cached"
  snapshot_workspace="$temp/snapshot-workspace"
  mkdir -m 700 -- "$snapshot_workspace"
  snapshot="$(export_committed_snapshot "$repo" spec/loom "$revision_from_repo" "$snapshot_workspace")"
  [[ "$(<"$snapshot/marker.txt")" == "committed bytes" ]] || \
    die "committed-tree snapshot used dirty worktree bytes"
  [[ ! -e "$snapshot/.lake" && -x "$snapshot/tool.sh" ]] || \
    die "committed-tree snapshot inherited .lake or lost executable mode"
  verify_committed_snapshot "$repo" spec/loom "$revision_from_repo" "$snapshot" exact

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' '[[ "$#" -eq 6 ]] || { printf "wrong Lake argc: %s\n" "$#" >&2; exit 65; }'
    printf '%s\n' '[[ "$1" == "-R" ]] || exit 66'
    printf '%s\n' '[[ "$2" == "-H" ]] || exit 67'
    printf '%s\n' '[[ "$3" == "--no-cache" ]] || exit 68'
    printf '%s\n' '[[ "$4" == "-KcoreRevision=$SELF_TEST_LAKE_REVISION" ]] || exit 69'
    printf '%s\n' '[[ "$5" == "build" && "$6" == "loom" ]] || exit 70'
    printf '%s\n' '[[ "$(pwd -P)" == "$SELF_TEST_LAKE_ROOT" ]] || exit 71'
    printf '%s\n' '[[ ! -e .lake ]] || exit 72'
    printf '%s\n' '[[ "$(<marker.txt)" == "committed bytes" ]] || exit 73'
    printf '%s\n' 'printf "%s\n" invoked >"$SELF_TEST_LAKE_MARKER"'
  } >"$temp/fake-lake"
  chmod 755 "$temp/fake-lake"
  export SELF_TEST_LAKE_REVISION="$revision_from_repo"
  export SELF_TEST_LAKE_ROOT="$snapshot"
  export SELF_TEST_LAKE_MARKER="$temp/fake-lake-invoked"
  if ! run_private_lake_build "$snapshot" "$revision_from_repo" "$temp/fake-lake" \
    2>"$temp/fake-lake.stderr"; then
    sed -n '1,30p' "$temp/fake-lake.stderr" >&2
    die "private Lake invocation self-test failed"
  fi
  unset SELF_TEST_LAKE_REVISION SELF_TEST_LAKE_ROOT SELF_TEST_LAKE_MARKER
  [[ "$(<"$temp/fake-lake-invoked")" == "invoked" ]] || \
    die "private Lake invocation self-test did not execute the strict fixture"

  rm -rf -- "$temp"
  trap - EXIT HUP INT TERM
  printf '%s\n' "build-release self-test: ok"
}

case "${1:-}" in
  --self-test)
    [[ "$#" -eq 1 ]] || { usage; exit 2; }
    self_test
    exit 0
    ;;
  "")
    [[ "$#" -eq 0 ]] || { usage; exit 2; }
    ;;
  *)
    usage
    exit 2
    ;;
esac

validate_release_paths "$LOOM_ROOT"

repo_root=""
if ! repo_root="$("$GIT_BIN" -C "$LOOM_ROOT" rev-parse --show-toplevel)"; then
  die "could not discover the repository containing the Loom root"
fi
repo_root="$(cd -P -- "$repo_root" && pwd -P)"
git_prefix=""
if ! git_prefix="$("$GIT_BIN" -C "$LOOM_ROOT" rev-parse --show-prefix)"; then
  die "could not determine the Git path of the Loom root"
fi
git_path="${git_prefix%/}"
validate_repository_mapping "$repo_root" "$LOOM_ROOT" "$git_path"

object_format="$("$GIT_BIN" -C "$repo_root" rev-parse --show-object-format)"
[[ "$object_format" == "sha1" ]] || die "release stamping requires a SHA-1 Git repository for exact 40-hex commits; found $object_format"
revision=""
if ! revision="$("$GIT_BIN" -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"; then
  die "could not resolve checkout HEAD to a commit"
fi
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || \
  die "checkout HEAD must be exactly 40 lowercase hexadecimal characters: $revision"
if [[ -n "${LOOM_CORE_REVISION:-}" && "$LOOM_CORE_REVISION" != "$revision" ]]; then
  die "LOOM_CORE_REVISION must equal the clean checkout HEAD ($revision)"
fi
tree_type="$("$GIT_BIN" -C "$repo_root" cat-file -t "$revision:$git_path")"
[[ "$tree_type" == "tree" ]] || die "committed Loom source path is not a Git tree: $revision:$git_path"
source_tree="$("$GIT_BIN" -C "$repo_root" rev-parse --verify "$revision:$git_path")"
[[ "$source_tree" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve the committed Loom source tree"

tracked_status=""
if ! tracked_status="$("$GIT_BIN" -C "$repo_root" status --porcelain=v1 --untracked-files=no -- "$git_path")"; then
  die "could not inspect tracked Loom source state"
fi
if [[ -n "$tracked_status" ]]; then
  printf 'error: tracked Loom sources are dirty; commit or restore them before release building:\n%s\n' \
    "$tracked_status" >&2
  exit 2
fi

workspace="$(mktemp -d "${TMPDIR:-/tmp}/loom-release-build.XXXXXX")"
workspace="$(cd -P -- "$workspace" && pwd -P)"
chmod 700 "$workspace"
IFS=$'\t' read -r workspace_dev workspace_ino <<<"$(workspace_identity "$workspace")"
IFS=$'\n\t'
workspace_active=1

cleanup_build_workspace() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$workspace_active" -eq 1 ]]; then
    if ! cleanup_owned_workspace "$workspace" "$workspace_dev" "$workspace_ino"; then
      [[ "$status" -ne 0 ]] || status=2
    fi
  fi
  exit "$status"
}
trap cleanup_build_workspace EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

build_root="$(export_committed_snapshot "$repo_root" "$git_path" "$revision" "$workspace")"
LAKE_BIN="$(command -v lake || true)"
[[ -n "$LAKE_BIN" ]] || die "required command not found: lake"
run_private_lake_build "$build_root" "$revision" "$LAKE_BIN"
verify_committed_snapshot "$repo_root" "$git_path" "$revision" "$build_root" built

post_build_head="$("$GIT_BIN" -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
[[ "$post_build_head" == "$revision" ]] || \
  die "checkout HEAD changed during the private build ($revision -> $post_build_head); rerun from a stable checkout"
if ! tracked_status="$("$GIT_BIN" -C "$repo_root" status --porcelain=v1 --untracked-files=no -- "$git_path")"; then
  die "could not recheck tracked Loom source state after the private build"
fi
if [[ -n "$tracked_status" ]]; then
  printf 'error: tracked Loom sources changed during the private build; refusing publication:\n%s\n' \
    "$tracked_status" >&2
  exit 2
fi

token="$(new_token)"
identity_json=""
publication_stdout="$workspace/release-identity.json"
trap 'forward_publish_signal 129 HUP' HUP
trap 'forward_publish_signal 130 INT' INT
trap 'forward_publish_signal 143 TERM' TERM
start_publish_release "$publication_stdout" "$build_root" "$LOOM_ROOT" "$revision" "$token"
if wait_publish_release; then
  publish_status=0
else
  publish_status=$?
fi
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[[ "$publish_status" -eq 0 ]] || exit "$publish_status"
[[ -s "$publication_stdout" ]] || die "publisher succeeded without one canonical identity JSON object"
identity_json="$(<"$publication_stdout")"

cleanup_owned_workspace "$workspace" "$workspace_dev" "$workspace_ino"
workspace_active=0
trap - EXIT HUP INT TERM
printf '%s\n' "$identity_json"
