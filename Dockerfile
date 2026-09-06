FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04

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
    && rm -rf /var/cache/apt/ \
    && wget -q -O /usr/bin/hadolint https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64 \
    && chmod 755 /usr/bin/hadolint

# Persists command history
ENV HISTFILE=/work/.devcontainer/.bash_history
ENV PROMPT_COMMAND="history -a"
