# Prizm devcontainer: everything that does not need macOS/Xcode.
#
# What runs here: Claude Code, OpenSpec, GSD, spec validation, shell/workflow/plist linting,
# swift-format, and a Linux type-check of the Foundation-only Domain layer.
# What cannot run here: xcodebuild (build, unit tests, UI tests, signing). Use
# scripts/host/xcode.sh on the Mac for that.
#
# Versions are pinned for reproducible rebuilds. The default policy is "a release at least two
# weeks old" for third-party tools, so a compromised or broken release has time to be noticed
# and pulled before it reaches this container. Bump them deliberately via the build args in
# devcontainer.json. Claude Code is not pinned: it updates itself, which is Anthropic's intended
# update path.

# Swift 6.2 matches CLAUDE.md ("Swift 6.2"). Tag plus digest, so a re-pushed tag cannot change
# the image silently.
FROM swift:6.2.4-noble@sha256:d6f8f6112e9a63da0a4a151d6b93acd16699d35c0b82531ac1a245f5af210197

ARG NODE_VERSION=24.21.0
ARG ACTIONLINT_VERSION=1.7.12
ARG SHELLCHECK_VERSION=0.11.0
ARG GH_VERSION=2.102.0
ARG OPENSPEC_VERSION=1.14.1
ARG GSD_VERSION=1.16.0
ARG USERNAME=developer
ARG USER_UID=1000
ARG USER_GID=1000

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq less libxml2-utils locales openssh-client \
      python3 ripgrep sudo xz-utils zsh \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Node.js from the official tarball, verified against the release's SHASUMS256.txt.
RUN case "$(dpkg --print-architecture)" in \
      amd64) NODE_ARCH=x64 ;; arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; esac \
 && cd /tmp \
 && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
 && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
 && grep " node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz\$" SHASUMS256.txt | sha256sum -c - \
 && tar -xJf "node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -C /usr/local --strip-components=1 --no-same-owner \
 && rm -f node-v*.tar.xz SHASUMS256.txt \
 && node --version && npm --version

# actionlint for .github/workflows, verified against the release's checksums file.
RUN ARCH="$(dpkg --print-architecture)" \
 && cd /tmp \
 && curl -fsSLO "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${ARCH}.tar.gz" \
 && curl -fsSLO "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_checksums.txt" \
 && grep " actionlint_${ACTIONLINT_VERSION}_linux_${ARCH}.tar.gz\$" "actionlint_${ACTIONLINT_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "actionlint_${ACTIONLINT_VERSION}_linux_${ARCH}.tar.gz" -C /usr/local/bin actionlint \
 && rm -f actionlint_* \
 && actionlint -version

# ShellCheck from the upstream release (Ubuntu ships an older version). Upstream publishes no
# checksum file, so the SHA-256 of each tarball is pinned here; recompute when bumping the version.
RUN case "$(dpkg --print-architecture)" in \
      amd64) SC_ARCH=x86_64;  SC_SHA=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;; \
      arm64) SC_ARCH=aarch64; SC_SHA=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; esac \
 && cd /tmp \
 && curl -fsSLO "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${SC_ARCH}.tar.xz" \
 && echo "${SC_SHA}  shellcheck-v${SHELLCHECK_VERSION}.linux.${SC_ARCH}.tar.xz" | sha256sum -c - \
 && tar -xJf "shellcheck-v${SHELLCHECK_VERSION}.linux.${SC_ARCH}.tar.xz" \
 && install -m 0755 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
 && rm -rf shellcheck-v* \
 && shellcheck --version

# GitHub CLI (gh) for branches, pull requests and CI results in a fork, verified against the
# release's checksums file. Its login lives in ~/.config/gh, which the home volume keeps across
# rebuilds.
RUN ARCH="$(dpkg --print-architecture)" \
 && cd /tmp \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
 && curl -fsSLO "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" \
 && grep " gh_${GH_VERSION}_linux_${ARCH}.tar.gz\$" "gh_${GH_VERSION}_checksums.txt" | sha256sum -c - \
 && tar -xzf "gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
 && install -m 0755 "gh_${GH_VERSION}_linux_${ARCH}/bin/gh" /usr/local/bin/gh \
 && rm -rf gh_* \
 && gh --version

# OpenSpec CLI, global and pinned. Its Claude commands are generated per project by post-create.sh.
RUN npm install -g --no-fund --no-audit "@fission-ai/openspec@${OPENSPEC_VERSION}" \
 && openspec --version

# Ubuntu 24.04 images ship an "ubuntu" user with UID 1000. Replace it with the devcontainer
# user "developer" (UID 1000), so files written in the workspace bind mount keep the host user's UID.
RUN if id ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
 && groupadd --gid "${USER_GID}" "${USERNAME}" \
 && useradd --uid "${USER_UID}" --gid "${USER_GID}" -m -s /bin/zsh "${USERNAME}" \
 && echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
 && chmod 0440 "/etc/sudoers.d/${USERNAME}"

USER ${USERNAME}
ENV HOME=/home/${USERNAME}

# Claude Code via Anthropic's native installer (installs to ~/.local/bin and updates itself).
# The whole home directory is persisted in the prizm-dev-home volume (devcontainer.json). Docker
# seeds that volume from this image content, with this owner, on first use only.
RUN mkdir -p "${HOME}/.claude" "${HOME}/.config" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && "${HOME}/.local/bin/claude" --version

# Exposed to post-create.sh and to `docker exec` sessions (the host wrapper), which do not go
# through VS Code's environment probing.
ENV PATH=/home/${USERNAME}/.local/bin:${PATH} \
    OPENSPEC_VERSION=${OPENSPEC_VERSION} \
    GSD_VERSION=${GSD_VERSION} \
    OPENSPEC_TELEMETRY=0
