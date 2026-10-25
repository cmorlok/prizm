# Prizm devcontainer

Prizm is a macOS app, so it **cannot be built or tested in a Linux container**. The split is:

| Where | What | Entry point |
|---|---|---|
| Container (`prizm-dev`) | Claude Code, OpenSpec, GSD, spec validation, shell/plist/scheme checks, workflow lint, Linux type-check of the Foundation-only Domain layer, optional swift-format | `scripts/container/checks.sh` |
| Mac host | `xcodebuild` build, unit tests, UI tests, signed Release build | `scripts/host/xcode.sh` |
| Mac host or container, both in order | container checks, then Xcode (from the container through the build daemon) | `scripts/build.sh` |
| Mac host, left running | runs Xcode builds requested from the container | `scripts/host/build-daemon.sh` |
| Container → Mac | one Xcode command on the Mac, output streamed back | `scripts/container/host-build.sh` |
| Mac host terminal → container | run `claude` inside the container | `scripts/claude.sh` |

## Prerequisites (on the Mac)

- A Docker runtime: Docker Desktop, OrbStack or Colima.
- VS Code with the Dev Containers extension, **or** the Dev Containers CLI
  (`npm install -g @devcontainers/cli`). The scripts use the CLI to create the container if it
  does not exist yet.
- Xcode, plus `Prizm/LocalConfig.xcconfig` with your `DEVELOPMENT_TEAM` (see `DEVELOPMENT.md`).
  Needed only for the host part.

## First start

1. Open the repo in VS Code and choose **Dev Containers: Reopen in Container**, or run
   `devcontainer up --workspace-folder .`. The first build takes several minutes, mostly for
   the Swift toolchain image.
2. `post-create.sh` then generates the OpenSpec `/opsx:*` commands and installs GSD into this
   project's `.claude/`. All of it is git-ignored. GSD's `.planning/` is excluded locally via
   `.git/info/exclude`. The script fails if setup modified any tracked file.
3. Run `claude` once (in the VS Code terminal, or `scripts/claude.sh` from the Mac) and log in.
   The login is stored in `~/.claude` in the container, which lives in the `prizm-dev-home`
   volume, separate from your Mac's `~/.claude`, and survives container rebuilds.

## Mounts and paths

- **Only the repo is mounted from the Mac**, always at `/workspaces/prizm`, whatever the clone
  is called or wherever it lives on the Mac. Paths printed inside the container (by Claude,
  linters, the compiler) therefore start with `/workspaces/prizm/`. On the Mac, read that prefix
  as your repo root.
- `scripts/claude.sh` maps your current directory into the container: run from
  `<repo>/Prizm/Domain` on the Mac, Claude starts in `/workspaces/prizm/Prizm/Domain`. Outside
  the repo it starts at `/workspaces/prizm`.
- **The container user's home, `/home/developer`, is the named volume `prizm-dev-home`.** It holds
  the Claude Code binary and login, OpenSpec's global config, shell history and anything else
  written to `~`, and survives rebuilds of the container and the image. Your Mac's home is not
  visible in the container.

### Container home volume

Docker seeds an empty named volume from the image's `/home/developer` **once**, the first time it
is mounted. After that the volume wins: later image changes under `/home/developer` (for example a
newer Claude Code installed at image build) do not reach an existing volume. Claude Code updates
itself inside the volume, so this rarely matters.

To start from a clean home, remove the container and the volume, then reopen the devcontainer:
```bash
docker rm -f prizm-dev && docker volume rm prizm-dev-home
```
This also deletes the container's Claude Code login.

## Building from inside the container

Xcode runs only on the Mac, but Claude Code runs in the container. The host build daemon connects
the two:

1. In a Mac terminal, in the repo, start the daemon and leave it running:
   ```bash
   scripts/host/build-daemon.sh
   ```
2. In the container, build and test as usual:
   ```bash
   scripts/build.sh                         # container checks, then build + unit tests on the Mac
   scripts/container/host-build.sh test     # only the Xcode part: build, test, test-ui, test-all, release, ci, clean
   ```
   The output streams back into the container, and the command exits with the build's exit code.
   Ctrl-C cancels the build on the Mac.

How it works: the client writes a request file into `build/host-bridge/` (git-ignored, inside the
mounted repo). The daemon polls that folder, runs `scripts/host/xcode.sh <command>`, writes the
output to `<id>.log` there, and writes `<id>.exit` when done. The protocol is described in
`scripts/lib/build-bridge.sh`.

- **Commands:** the daemon runs only the `xcode.sh` commands listed above, so the container cannot
  make the Mac run anything else.
- **Order:** one build at a time, in request order.
- **Daemon not running:** the client fails at once with a hint, based on a heartbeat file the
  daemon rewrites every second. If the daemon stops during a build, the client gets exit 125.
- **Logs:** kept in `build/host-bridge/` for 7 days.

## Pinned versions

All set in `devcontainer.json` → `build.args`:
- Swift 6.2 base image (tag + digest)
- Node.js
- OpenSpec
- GSD (`@opengsd/gsd-core`, the maintained continuation of the archived `get-shit-done-cc`)
- actionlint and ShellCheck

The policy is a release **at least two weeks old**, so a compromised or broken release has time
to be noticed and pulled before it reaches a container that has your home directory mounted.
Downloads are checksum-verified. Claude Code is not pinned: it updates itself.

To bump a version, change the build arg and rebuild the container. For ShellCheck, also update
the pinned SHA-256 values in the `Dockerfile`.

## Container checks: blocking vs. advisory

`scripts/container/checks.sh` explains each check in its header. The advisory ones are advisory
because of **existing upstream debt**, not because they are unimportant:
- most main specs fail `openspec validate` (missing `## Purpose` / `## Requirements`)
- the existing workflows have shellcheck findings in `run:` steps
- the Domain type-check on Linux is not yet proven on this codebase

`--strict` makes all of them blocking. Use it for anything you add.

## Status

Written and checked without Docker. Shell scripts pass ShellCheck 0.11.0, the check script was
run end to end in a Linux environment, and the OpenSpec and GSD installer flags were read from
their source. **The image itself has not been built yet.** The first build on the Mac is the
real test; report or fix anything that fails there.
