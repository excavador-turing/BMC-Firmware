# Pinned by digest: this is the image the 2026-09-06 CI runs resolved
# (run 34054948922, step "Run docker/build-push-action"). The tag moves;
# the digest does not, so two builds of the same commit get the same host
# compiler and the ccache stays valid across runs.
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:456e33716a8570448b7deca1ffd98fc337adc7b446aceeadb8beaf8d660345b4

# cmake and lzip: Buildroot builds its own host-cmake (526 s of the 2026-09-06
# CI build, and ccache is a cmake package so it is always needed) and
# host-lzip (129 s) whenever the host lacks them
# (support/dependencies/check-host-{cmake,lzip}.mk). Noble ships cmake 3.28.3,
# the exact version Buildroot 2024.05.1 would otherwise compile from source.
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y \
    build-essential \
    subversion \
    git-core \
    libncurses5-dev \
    zlib1g-dev \
    gawk \
    bc \
    cpio \
    file \
    flex \
    quilt \
    libssl-dev \
    xsltproc \
    libxml-parser-perl \
    mercurial \
    bzr \
    ecj \
    cvs \
    unzip \
    zlib1g-dev \
    libncurses-dev \
    u-boot-tools \
    mkbootimg \
    xxd \
    shellcheck \
    cmake \
    lzip \
    && rm -rf /var/lib/apt/ \
    && rm -rf /var/cache/apt/

# hadolint. Nothing in the build or CI runs it; it serves the exiasr.hadolint
# editor extension both devcontainer.json files install, so it stays -- but
# checked against the .sha256 hadolint publishes beside each release binary,
# and chosen per architecture: an arm64 devcontainer used to get an x86_64
# binary it could not run. Bumping the version means bumping both sums.
ARG HADOLINT_VERSION=v2.12.0
RUN set -eu; \
    case "$(uname -m)" in \
      x86_64)  arch=x86_64; sum=56de6d5e5ec427e17b74fa48d51271c7fc0d61244bf5c90e828aab8362d55010 ;; \
      aarch64) arch=arm64;  sum=5798551bf19f33951881f15eb238f90aef023f11e7ec7e9f4c37961cb87c5df6 ;; \
      *) echo "hadolint: no release binary for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    wget -q -O /usr/bin/hadolint "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-${arch}"; \
    echo "${sum}  /usr/bin/hadolint" | sha256sum -c -; \
    chmod 755 /usr/bin/hadolint

# Persists command history
ENV HISTFILE=/work/.devcontainer/.bash_history
ENV PROMPT_COMMAND="history -a"
