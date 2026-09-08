# Turing Pi BMC firmware — `excavador` fork

> **This is a fork of [turing-machines/BMC-Firmware](https://github.com/turing-machines/BMC-Firmware).**
> `main` tracks upstream. **`hive` is the branch that gets built and flashed**;
> everything below the fold is upstream's own README, unchanged.
>
> Upstream is dormant and its mirror `firmware.turingpi.com` stops at v2.0.5,
> so following the documented update path would *downgrade* a board that runs
> anything newer. This fork exists to have a firmware that builds, releases and
> installs from a pipeline we can see.

## Running now: `v2.4.0`

The first **stable** release of this fork. Everything before it was a
`v2.2.0-unstable-hive.N` pre-release; those tags and their releases have been
removed, and their content is here. Everything in this section was measured on
the board after the flash, not inferred from a build.

| verified | evidence |
|---|---|
| **A bad image undoes itself.** Promotion waits until bmcd answers on `https://127.0.0.1/` and every compute node's switch port exists; otherwise the board reboots, which lands on the previous image because nothing was renamed and `nextboot` is one-shot | Its own log, across **nine consecutive over-the-air promotions**: `bmcd answered after 3s`, `switch ports present: node1 node2 node3 node4`, then promoted. Six branches were exercised beforehand against a stubbed copy on the board's own busybox, including both failure paths |
| **The rollback note survives the rollback.** The gate writes to `/mnt/overlay/postupdate.log` | `/var/log` is a symlink into a tmpfs; `/mnt/overlay` is the UBI volume *both* images mount. Read back off the board after each flash |
| **The board has a temperature.** The T113s thermal sensor is described in the board DTS — mainline has no THS node for this SoC, so the driver was built but never probed | `allwinner,sun20i-d1-ths` bound to `2009400.thermal-sensor`; `/sys/class/thermal/thermal_zone0` reads **52405** millidegrees, and the About page shows 52.0 °C |
| **The fan is driven by the kernel, from that sensor**, through a thermal zone with trips at 20/45/60/70 °C and a floor at state 3 — the sensor is the BMC SoC but the fan cools the modules | It stepped **6/6 → 4/6** on its own and held there; module temperatures were unchanged at 51–56 °C across the change |
| **The fan is shown as the seven discrete states the device tree defines**, not as a percentage | `cooling-levels = <0 16 32 64 102 170 254>` read from the board's own device tree; the UI renders a segmented gauge and reports `4 of 6` |
| **A firmware update no longer touches running nodes.** bmcd reads the live rail state on start and adopts it instead of re-applying what `bmcd.bin` persisted; a cold boot still restores the persisted state | Nine flashes and daemon restarts with four nodes powered: every rail stayed on, every `/proc/uptime` monotonic, no node dropped a ping. Fixes upstream [bmcd#90](https://github.com/turing-machines/bmcd/issues/90) |
| **`power_on_time` is per node and is a duration.** Upstream inferred it from a single shared bit, so the read could only ever agree for node 1, and the UI rendered `now - value` against a value that was already elapsed seconds | It reported `powered on 20703 d 2 h ago`; it now reports the duration the API actually returns, and the enable lines are read back per node |
| **The switch panel shows real link state** | `ge1` displayed as down — the first time this fork could show a port that was not up. Port-to-node mapping was confirmed by correlating a 45-second traffic delta per port against each module's own NIC: all four tracked within 2–5 %, same ordering |
| **There is a `/metrics` endpoint**, authenticated, carrying node power and uptime, fan state, SoC temperature and switch per-port counters | `curl` without credentials returns **401**; with them, Prometheus text. The board was the only thing in this estate reporting nothing |
| **HTTP/2 is refused, not downgraded after the parser has already run** | `curl --http2` negotiates **HTTP/1.1** and gets 401. It previously answered `HTTP/2 401` — the request had been parsed by the h2 stack before authentication rejected it |
| **A serial console per module, in the browser.** A browser cannot set `Authorization` on a websocket handshake, so the token rides the subprotocol — the pattern Kubernetes uses — and the server echoes back the non-bearer entry | Live on `/console`; xterm is a lazy chunk the main bundle never loads |
| **Linux 6.12.109 LTS on Buildroot 2025.02.17 LTS**, both pinned, five out-of-tree patches re-ported | `uname -r` on the board. Upstream builds on Buildroot 2024.05.1 (EOL) and a 6.8 kernel that is not a longterm release |
| **Built with Rust 1.98.1**, up from 1.85.0, which had been holding back a bmcd dependency update that closes an advisory | `rustc --version` in the build container; the vendored archive is pinned by sha256 against that toolchain |
| **The image is 78 % of its UBI slot** — 36,990,976 of 46,981,120 bytes — and the build **fails at 90 %** | Down from 37,326,848 while *gaining* a serial console, four new panels and a newer toolchain |
| **A tagged release builds in ~23 minutes**, every input pinned by sha256 (bmcd, tpi, bmc_installer, bmc-ui, the Rust toolchain) and every action pinned by commit | Release history in this repo |
| **`tpi info` reports the release tag**, and `tpi firmware` completes in ~23 s | It used to report the Buildroot version, so a flashed board could not say what was on it |
| **The About page reports the Linux kernel.** Nothing in the daemon read it before, so `uname -r` over SSH was the only way to confirm which kernel had actually booted after a bump | The live page: `Linux kernel 6.12.109`, matching `/proc/sys/kernel/osrelease` on the board |
| **The Firmware Upgrade page names the version that is staged**, not merely that something is. The staging volume is static and never mounted, so its version cannot be read on a running system; the stager records the tag, checksum and time to `/mnt/overlay/staged-firmware` instead, and the promotion script removes it once it has decided | Proven by mutation, not by reading the code: with no note the API reports `staged: null`; with one it reports every field; with the note removed it returns to `null`. The page renders `Staged version v2.5.0 · tpi-selfupdate`. The writer and the clearer are both present in the running image |

### Known, on this version

- **`power_on_time` still reads high for nodes 2–4** until they are genuinely
  power-cycled. The value is now read correctly; what is stale is the board's
  own record, and only dropping the rail clears it. The web UI's `RESTART`
  sends `type=reset`, which does not.
- **An image that hangs *before* `S99postupdate` runs is still not covered.**
  The gate only helps an image that boots far enough to be judged; anything
  earlier still needs power cut, which hard-cuts the compute modules.
- The login page is served with an **RSA self-signed certificate** minted at
  boot, so every browser calls it insecure.
- **Flashing a module over USB is built but not exercised on hardware.** The
  `rockusb` module loads; the operation is untested on this kernel.

## Plan

Nothing in this section is running on the board.

### Written and tested, waiting on a build and a flash

*Nothing is currently in this state — everything that was here shipped in
hive.6 and moved up to "Running now" with its evidence.*

### Not implemented

| planned | why |
|---|---|
| **Hardware watchdog + boot counter** so a tentative image that *hangs* rolls back by itself | The health gate above only helps an image that boots far enough to run it. An image that hangs earlier still means a trip to the rack. Must be proven from an SD boot with a console before it ships in a `.tpu` |
| **Node-aware USB flashing** | `tpi flash -n N` writes to whichever module enumerates first; with more than one in maskrom it reports success while writing nothing, or writes the wrong module |
| **Remote syslog and an audit line per mutating API call** | Logs live in tmpfs and die at reboot, and a power-off from the web UI, from `tpi`, and over the API all look identical |
| **Key-only SSH and a forced password change** | The board ships with a vendor default password and password authentication enabled |
| **An EC P-384 certificate for bmcd, and a way to install a trusted one** | The current one is RSA-4096, minted at every boot, and there is no path to install a real certificate except `scp` and a restart |
| **VLAN filtering and STP on the switch** | `br0` bridges all six ports flat: the management plane shares layer 2 with node traffic, and plugging both uplinks into a switch would loop |
| **Persistent per-node serial capture**, and honour `uart_baud` | A module that panics at 03:00 leaves nothing behind: the daemon keeps a 16 KiB RAM ring that dies with it |
| **Node heartbeat with opt-in power-cycle** | Nothing recovers a module that wedges below the OS |
| **Upstream the switch driver's I2C transport** | The interface split above makes this a series that could go to netdev, so each future kernel bump shrinks the patch instead of repeating it |
| **Repoint the UI's update check** at this fork's releases | It reads a mirror that stops at v2.0.5, so followed literally it would downgrade the board. `tpi-selfupdate` covers the command line; the web interface still points at the mirror |
| **Hardware-less contract tests** against the stubbed HAL, and reproducible builds | CI builds an image and never exercises the API |

One thing is built but **not exercised on hardware**: flashing a module over
USB — the `rockusb` module loads, but the operation is untested on this
kernel. Switch port state is no longer in that category: the Network tab
reads real per-port link state, and showed `ge1` down.

### A trap when a package's file set shrinks

Buildroot's target directory is not cleaned between incremental builds, so a
package that stops shipping files leaves the old ones behind. Repointing
`bmc-ui` at our fork — which drops 21 `.woff` files and fifteen non-Latin
`.woff2` subsets — produced a local image carrying **48 font files instead of
6**: upstream's 42 plus ours. The rootfs read 81 % of the slot rather than the
real 78 %.

CI is unaffected because it builds from an empty tree, and that is exactly why
it is worth writing down: the contaminated build is the one you get locally,
so a local size figure can be quietly wrong in the direction that matters.

```sh
rm -rf buildroot/output/target/srv/bmcd/www \
       buildroot/output/per-package/bmc-ui/target/srv/bmcd/www
just build     # NOT a bare `make`: post_build.sh needs BUILD_VERSION, and
               # without it target-finalize dies on `git describe`
```

## Updating a board

Upstream's "Install firmware" section below the fold points at
`firmware.turingpi.com`, which stops at v2.0.5. Following it downgrades any
board running this fork. Use one of these instead.

**From the board itself**, once it is running hive.6 or later:

```sh
tpi-selfupdate --check --channel edge   # what would happen, downloads nothing
tpi-selfupdate --channel edge           # fetch, verify, stage
reboot
```

`stable` follows the release GitHub marks "Latest"; `edge` follows the most
recently published release, pre-releases included. **Every release in this
repository so far is a pre-release**, so `stable` currently resolves to an
older tag than the board is running and refuses to install it. That refusal is
the feature: a target that does not sort after the running version needs
`--allow-downgrade`.

**Over the network**, with the image already on the workstation:

```sh
scp firmware.tpu root@BMC:/mnt/sdcard/
ssh root@BMC "tpi firmware --file /mnt/sdcard/firmware.tpu --sha256 HASH"
```

**By hand**, which is what to use when the daemon is the thing you distrust —
for example when installing a version whose *purpose* is to fix the upload
path:

```sh
ssh root@BMC "/sbin/osupdate /mnt/sdcard/firmware.tpu"   # writes, arms nextboot
ssh root@BMC reboot
```

Verify a downloaded image against `SHA256SUMS` from the release, not against
the per-file `.sha256` asset: the latter records the absolute path it was
generated from inside the build container, so `sha256sum -c` on it fails to
*open* a file rather than reporting a mismatch — an error that reads like a
pass to anything grepping for `FAILED`.

### What happens on the next boot

The first boot after an update is **tentative**. `S99postupdate` checks that
bmcd answers on `https://127.0.0.1/` and that every compute node's switch port
exists, and only then renames the UBI volumes to make the new image permanent.

If the check fails the board reboots, and that alone is the rollback: u-boot
boots the volume named `rootfs`, which is still the previous image because
nothing has been renamed, and the `nextboot` variable that steered the
tentative boot is one-shot and already consumed. The boot after that carries no
`postupdate` in its command line, so the script does nothing and there is no
loop.

Either way it leaves its reasoning in `/mnt/overlay/postupdate.log`. That path
is deliberate: `/var/log` is a symlink into a tmpfs, while `/mnt/overlay` is
the UBI volume **both** images mount, so the note explaining a rollback
survives the reboot that performed it.

```sh
ssh root@BMC "cat /mnt/overlay/postupdate.log"
ssh root@BMC "sed -n 's/^VERSION=//p' /etc/os-release"   # what is running now
```

To cancel a staged update before rebooting, clear the pending boot:

```sh
ssh root@BMC "fw_setenv nextboot"
```

### When the board is genuinely stuck

A tentative image that *hangs* before reaching `S99postupdate` is not covered
by the gate — that is what the watchdog in the Plan section is for. Cut power:
promotion never happened, so the board comes back on the previous image. Note
that this hard-cuts the compute modules, which a normal firmware update does
not.

Failing that, write a released `-sdcard-*.img` to an SD card, insert it,
power-cycle to let it reinstall, then remove the card and power-cycle again.

The Turing Pi is a compact AI & edge computing cluster purposed to run cloud
stacks and AI inference at the edge. Find out more on our
[website](https://turingpi.com).

The firmware is based on a Linux 5.4 kernel and hosts a web interface with a
REST API to control and manage the board. The packages
[bmcd](https://www.github.com/turing-machines/bmcd),
[tpi](https://github.com/turing-machines/tpi) and
[bmc-ui](https://github.com/turing-machines/BMC-UI) are part of the firmware and
facilitate most of this functionality.

## Table of Contents

- [Table of Contents](#table-of-contents)
- [Reporting issues \& requesting features](#reporting-issues--requesting-features)
- [BMC chip specs](#bmc-chip-specs)
- [Install firmware](#install-firmware)
- [Build / Development](#build--development)
- [Quickstart](#quickstart)
- [Start DevContainer](#start-devcontainer)
- [macOS / Darwin](#macos--darwin)
  - [macOS / Darwin Build Performance](#macos--darwin-build-performance)
- [Windows](#windows)
  - [Build Performance](#build-performance)
- [Scripts](#scripts)
- [Commands](#commands)
- [Building](#building)
  - [Linux / Windows](#linux--windows)
  - [OSX](#osx)
  - [Manual](#manual)
  - [Native](#native)
- [Output](#output)
- [Development](#development)

## Reporting issues & requesting features

It is recommended to use the issue tracker of the current BMC-Firmware repository
to request features or submit bug reports. We are open to all feedback and
improvements. We scan the dependent repositories regularly for activity, but for
visibility reasons, we will mainly use the issue tracker of this repository.

## BMC chip specs

- CPU Allwinner T113-S3 (ARM Cortex-A7)
- 128 MB DDR3 RAM
- 128 MB SPI NAND flash (MX35LF1GE4AB)
- EEPROM (24C02C)
- 3 port Gigabit Ethernet Switch (RTL8370MB)
- Ethernet PHYceiver (RTL8201F-VB-CG)
- SD card slot

## Install firmware

>**Note: If you are running a firmware version lower than < v2.0.0, you must do
>a one-time-only SD card upgrade to version v2.0.0.**
>
>**Note 2: Prior to v2.0.0 a third-party tool 'PhoenixSuit' was required to
>flash firmware. This tool is obsoleted, and only the methods described on our
>website can be used to flash your board.**

The latest firmware images can be found on the [release page](https://github.com/turing-machines/BMC-firmware/releases).

On our
[website](https://docs.turingpi.com/docs/turing-pi2-bmc-firmware-upgrade)
you can find more information on installing firmware.

## Build / Development

If you want to build the BMC firmware yourself, there is some preparation
needed, which depends on your working environment.

The build process uses [Buildroot](https://buildroot.org/) for further documentation
can be found [here](https://buildroot.org/downloads/manual/manual.html).
Buildroot is not included in this repository and needs to be downloaded once
before building.

This repository uses a `devcontainer` for a uniform development environment. The
devcontainer is available in a linux and darwin version. Windows users are recommended
to use WSL or Docker-Desktop.

There are several scripts available within the `scripts` directory to facilitate
easy development and building of the firmware. See the section [Scripts](#scripts) for
more information. Furthermore, there are several special `git` commands available to
ease development and the building process. More information about the commands are
available in the [Commands](#commands) section.

> **IMPORTANT**
>
> Before starting a build the `configure.sh` script must be run, this script must also be
> rerun everything buildroot is updated.

## Quickstart

1. Clone repository
2. Open in VSCode or any other editor that natively supports devcontainers
3. Start devcontainer for your platform, `Windows` users should use the `Linux` devcontainer
4. The `devcontainer` will auto-configure the repository `git` commands
5. Run `git configure`
6. Run `git build`
7. Firmware artifacts will appear in the `dist` directory

## Start DevContainer

If no popup appears to notify you of starting the devcontainer you can so so by searching for the
`devcontainer` commands in the VSCode `Command Pallete` which can be opened on Windows and Linux with
`CTRL + Shift + P` and on macOS with `Shift + Command + P`.

Choose `Rebuild and Reopen in Container` to start the devcontainer, after which you can select which OS
version you want to start.

![devcontainer Rebuild and Reopen in Container](docs/devc-rebuild-and-open.png?raw=true "Rebuild and Reopen in Container")
![devcontainer select OS](docs/devc-select-os.png?raw=true "Select OS")

## macOS / Darwin

Builds on OSX are different, and there is a devcontainer configuration specifically
available for darwin. The difference is that for builds on darwin the building process
takes place within a volume. The reason is APFS, the default APFS of macOS is
case-insensitive. Only on a darwin machine that uses the special APFS+Case-Sensitive
the default linux devcontainer can be used.

### macOS / Darwin Build Performance

For the best performance on macOS Docker-Desktop is recommended with the use of
the currently `BETA` feature of `Docker VMM` as Virtual Machine.
The `Apple Virtualization Framework` can cause Docker-Desktop to crash during a build.

## Windows

For building on Windows, both devcontainers can be used either the linux or darwin container.
Before starting the container under Windows, you might have an issue regarding the End-Of-Line
of the files.

The best way to handle this is to normalize the repository to `LF` line endings.
Run the following command before starting the devcontainer.

```shell
git config --local include.path ../.gitconfig
git config --global core.eol lf
git config --global core.autocrlf input
```

Now after this you can normalize the repository.

```shell
git rm -rf --cached .
git reset --hard HEAD
```

This will force all the files to have the correct line endings.

### Build Performance

When building on Windows with Anti-Virus software present, it is important to understand that
this can severly impact build speed as each file will be scanned during the build process.
Furthermore, the on-access scanner of Anti-Virus software can cause build compiliation corruption.
In order to bypass this, Windows users can use the macOS / darwin devcontainer, this will build
according to the same build process in a volume and the developer can use the `git sync` command
or `./scripts/sync.sh` to sync files between the host and the devcontainer.

## Scripts

The repository provides several scripts to facilitate easy development. All scripts are located in
the scripts directory.

| Script       | Description                                                                                                                     |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| build.sh     | Script to build the firmware, firmware artifacts are placed in the `dist` directory, configure.sh must be run first             |
| clean.sh     | Cleanup repository removes the `buildroot` and `dist` directories                                                               |
| configure.sh | Configure the repository with the buildroot, this script must be run everytime is buildroot is updated or on a clean repository |
| init.sh      | This is the devcontainer initialization script, only used by the devcontainer on startup                                        |
| sync.sh      | Only for macOS / darwin, synchronize changes to the host                                                                        |

> **NOTE**
>
> If an additional script is added then some extra steps are required. The provided gitconfig turns off `filemode` this is due to the fact that development
> takes place on multiple platforms. However, we want to be able to execute the scripts after we have committed them, so when writing the script giving
> it `chmod +x` and then commiting is not sufficient. In order to commit the execute bit to the repsoitory the following command must be given
> to commit the execute bit to the git repository.
>
> `git update-index --chmod=+x <FILE>`
>
> This will stage the execute bit to the git staging, after which it can be commited with a message `chore: update file permissions`.

## Commands

When using the devcontainer the git repository is automatically configured to extend
the git commands to include the additional aliases for development.

If you are building on a native host you need to configure this manually.
This can be done by running the following command.

```shell
git config --local include.path ../.gitconfig
```

This command will extend the git config of the repository with the .gitconfig from the
repository.

All these commands are added as subcommands of the `git` command.
Example to run the `root` command you run `git root`.

If you want to build the firmware, run `git build`.

| Git Command | Description                                                                                  |
| ----------- | -------------------------------------------------------------------------------------------- |
| root        | Display root path of repository                                                              |
| sha1        | This will print the 8 char short sha of the current commit                                   |
| configure   | Configure the repository by setting up buildroot, must be run everytime buildroot is updated |
| build       | Build the firmware                                                                           |
| cleanup     | Cleanup the repository                                                                       |
| sync        | Used by macOS / darwin users to sync the changes between the container and the host          |

## Building

The recommended way is to build using the provided devcontainer, manual builds are
also possible. All devcontainers or manual builds use the same `Dockerfile` in the
root directory of this repository. It has all the dependencies needed to build the firmware.

> The build process needs approx. 5GB to 16GB disk space. On OSX you need that
> amount of space reserved and free in the the Virutal Machine of Docker or Rancher
> Desktop.

### Linux / Windows

Start the devcontainer, after the workspace is up and running you can start your development or
build the firmware using either the scripts from the script directory or the provided `git`
aliases. Because Linux and Windows have a case-sensitive filesystem the build can actually take
place on the host filesystem through the devcontainer mounted repository host directory.

The workspace directory `/work` in the devcontainer is the repository directory on the host.

### OSX

Start the devcontainer, after the workspace is up and running you can start your development or
build the firmware using either the scripts from the script directory or the provided `git`
aliases. MacOS uses APFS which is a case-insensitive filesystem, this causes build problems.
For this reason the workspace directory `/work` of the devcontainer is a docker volume which
bypasses the filesystem restriction. The repository on the host is mounted in the devcontainer
in the `/mnt` directory.

In order to sync changes back and forth between the host and container if needed the command
`git sync` can be used. However the devcontainer `/work` workspace is a full working git
repository. The log of the syncing between host and container can be viewed in the container
log file `/tmp/sync.log`.

> **IMPORTANT**
>
> The .git directory is **NOT** synced between the host and the devcontainer when a sync is initiated.
> This is to avoid corruption of the git repository.

### Manual

We would recommend that you go through the official docker documentation for
further details. If you want to quickly build and run it, execute the following
commands in the root of your repository:

```shell
# On the host: build the docker image
docker build . -t bmc-firmware

# On the host: enter the container
docker run -it --rm -v $PWD:/src -w /src -u $(id -u):$(id -g) bmc-firmware
# NOTE: the shell prompt might be a bit garbled, this is fine
#       the -u $(id -u):$(id -g) parameter ensures that the generated files
#       are owned by your user

# inside of the container: prepare buildroot
./scripts/configure.sh

# Build the firmware
./scripts/build.sh
```

## Coder

This repository has support for being used within a [Coder](https://coder.com) environment. Self-Hosted coder is supported.

After starting your container/environment, you can auto-configure this repository by running `.coder/bootstrap.sh` which will configure your environment automatically. You can detect for this script in a module and run it while you boot-up your environment.

### Native

Currently, only X86 Linux build hosts are supported. They are
required to have the following packages installed:

Instead of manually configuring the environment you can choose to run `.coder/boostrap.sh` which will autoconfigure your environment.

> **Commands**
>
> If you want the `git` aliases to work check the section [Commands](#commands) and run the
> command to activate the repository gitconfig.

```shell
# install packages needed for build
sudo apt-get -y install \
  build-essential subversion git-core \
  libncurses5-dev zlib1g-dev gawk flex quilt libssl-dev xsltproc \
  libxml-parser-perl mercurial bzr ecj cvs unzip zlib1g-dev \
  libstdc++6 libncurses-dev u-boot-tools mkbootimg

# prepare buildroot
./scripts/configure.sh

# build
./scripts/build.sh
```

## Output

After the build is completed the OTA image and the SDCard image are
copied to the `dist` directory, and SHA256 hashes are generated.

The RAW images are located in the `buildroot/output/images` directory.

- `rootfs.erofs`: OTA image
- `tp2-bmc-firmware-sdcard.img`: SDCard image

The SHA256 checksums are generated in using the `binary` format of the
`sha256sum` command. This can be identified by opening the `*.sha256` file,
when there is an asterisks `*` in front of the filename, this identifies that
the checksum requires binary validation. Using the default `sha256sum` text mode
as is default for the `sha256sum` command the generated sha is identical however
we do not want to generate a text sha of a binary file.

The build script automatically corrects the filename when copying the images to
the `dist` directory. However, this is for aesthetics only, and to ensure that
the Web UI accepts the generated OTA image.

## Development

If you require an additional buildroot directory you can run the configure script and
set the target directory or install dir where to put the buildroot.

For configure run:

```shell
git configure --help
```

The build script also provides additional arguments.

```shell
git build --help
```

The .gitignore allows for two workign directories while developing.

- tmp
- wip
