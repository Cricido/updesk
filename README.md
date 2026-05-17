<p align="center">
  <img src="res/logo-header.svg" alt="UptimeDesk - Your remote desktop"><br>
  <b>UpDesk</b> · Self-hosted remote desktop fork based on RustDesk<br>
  <a href="#raw-steps-to-build">Build</a> •
  <a href="#how-to-build-with-docker">Docker</a> •
  <a href="#updesk-specific-additions">UpDesk Additions</a> •
  <a href="#file-structure">Structure</a> •
  <a href="#snapshot">Snapshot</a><br>
  [<a href="docs/README-UA.md">Українська</a>] | [<a href="docs/README-CS.md">česky</a>] | [<a href="docs/README-ZH.md">中文</a>] | [<a href="docs/README-HU.md">Magyar</a>] | [<a href="docs/README-ES.md">Español</a>] | [<a href="docs/README-FA.md">فارسی</a>] | [<a href="docs/README-FR.md">Français</a>] | [<a href="docs/README-DE.md">Deutsch</a>] | [<a href="docs/README-PL.md">Polski</a>] | [<a href="docs/README-ID.md">Indonesian</a>] | [<a href="docs/README-FI.md">Suomi</a>] | [<a href="docs/README-ML.md">മലയാളം</a>] | [<a href="docs/README-JP.md">日本語</a>] | [<a href="docs/README-NL.md">Nederlands</a>] | [<a href="docs/README-IT.md">Italiano</a>] | [<a href="docs/README-RU.md">Русский</a>] | [<a href="docs/README-PTBR.md">Português (Brasil)</a>] | [<a href="docs/README-EO.md">Esperanto</a>] | [<a href="docs/README-KR.md">한국어</a>] | [<a href="docs/README-AR.md">العربي</a>] | [<a href="docs/README-VN.md">Tiếng Việt</a>] | [<a href="docs/README-DA.md">Dansk</a>] | [<a href="docs/README-GR.md">Ελληνικά</a>] | [<a href="docs/README-TR.md">Türkçe</a>] | [<a href="docs/README-NO.md">Norsk</a>] | [<a href="docs/README-RO.md">Română</a>]<br>
  <b>We welcome help translating this README and the <a href="https://github.com/Cricido/updesk/tree/main/src/lang">UpDesk UI</a>.</b>
</p>

> [!Caution]
> **Misuse Disclaimer:** <br>
> The developers of UptimeDesk do not condone or support any unethical or illegal use of this software. Misuse, such as unauthorized access, control or invasion of privacy, is strictly against our guidelines. The authors are not responsible for any misuse of the application.


Source repository: [github.com/Cricido/updesk](https://github.com/Cricido/updesk)

UpDesk is a self-hosted remote desktop fork based on RustDesk, focused on:
- custom branding and packaging
- relay compatibility hardening
- WebSocket / 443 fallback support
- self-hosted update manifests and updater flow

Useful project documents:
- [Relay compatibility on 443](docs/updesk-relay-compat.md)
- [Updater architecture and publish flow](docs/updesk-updater.md)
- [Fork modifications summary](docs/updesk-fork-modifications.md)

![image](https://user-images.githubusercontent.com/71636191/171661982-430285f0-2e12-4b1d-9957-4a58e375304d.png)

UptimeDesk welcomes contribution from everyone. See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for help getting started.

[**FAQ**](https://github.com/Cricido/updesk/wiki)

[**BINARY DOWNLOAD**](https://github.com/Cricido/updesk/releases)

[**SOURCE CODE**](https://github.com/Cricido/updesk)

[<img src="https://f-droid.org/badge/get-it-on.png"
    alt="Get it on F-Droid"
    height="80">](https://f-droid.org/en/packages/com.carriez.flutter_hbb)
[<img src="https://flathub.org/api/badge?svg&locale=en"
    alt="Get it on Flathub"
    height="80">](https://flathub.org/apps/com.rustdesk.UptimeDesk)

## Dependencies

Desktop versions use Flutter or Sciter (deprecated) for GUI, this tutorial is for Sciter only, since it is easier and more friendly to start. Check out our [CI](https://github.com/rustdesk/rustdesk/blob/master/.github/workflows/flutter-build.yml) for building Flutter version.

Please download Sciter dynamic library yourself.

[Windows](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.win/x64/sciter.dll) |
[Linux](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so) |
[macOS](https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.osx/libsciter.dylib)

## Raw Steps to build

- Prepare your Rust development env and C++ build env

- Install [vcpkg](https://github.com/microsoft/vcpkg), and set `VCPKG_ROOT` env variable correctly

  - Windows: vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
  - Linux/macOS: vcpkg install libvpx libyuv opus aom

- run `cargo run`

## [Build](https://rustdesk.com/docs/en/dev/build/)

## UpDesk Specific Additions

- WebSocket relay/rendezvous fallback on `443` through `updesk.uptimeservice.it`
- Compatibility bridge/proxy layer for `hbbs/hbbr 1.1.15`
- Self-hosted update channels:
  - `stable`
  - `recommended`
  - `beta`
- Separate Windows updater helper with SHA256 verification

Main files for the UpDesk-specific stack:
- `server/ws_hbbs_bridge.py`
- `server/hbbs_tcp_proxy.py`
- `server/relay_pair_proxy.py`
- `src/common.rs`
- `src/updater.rs`
- `src/bin/updesk_updater.rs`
- `flutter/lib/desktop/pages/desktop_setting_page.dart`
- `flutter/lib/mobile/pages/settings_page.dart`

## How to Build on Linux

### Ubuntu 18 (Debian 10)

```sh
sudo apt install -y zip g++ gcc git curl wget nasm yasm libgtk-3-dev clang libxcb-randr0-dev libxdo-dev \
        libxfixes-dev libxcb-shape0-dev libxcb-xfixes0-dev libasound2-dev libpulse-dev cmake make \
        libclang-dev ninja-build libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libpam0g-dev
```

### openSUSE Tumbleweed

```sh
sudo zypper install gcc-c++ git curl wget nasm yasm gcc gtk3-devel clang libxcb-devel libXfixes-devel cmake alsa-lib-devel gstreamer-devel gstreamer-plugins-base-devel xdotool-devel pam-devel
```

### Fedora 28 (CentOS 8)

```sh
sudo yum -y install gcc-c++ git curl wget nasm yasm gcc gtk3-devel clang libxcb-devel libxdo-devel libXfixes-devel pulseaudio-libs-devel cmake alsa-lib-devel gstreamer1-devel gstreamer1-plugins-base-devel pam-devel
```

### Arch (Manjaro)

```sh
sudo pacman -Syu --needed unzip git cmake gcc curl wget yasm nasm zip make pkg-config clang gtk3 xdotool libxcb libxfixes alsa-lib pipewire
```

### Install vcpkg

```sh
git clone https://github.com/microsoft/vcpkg
cd vcpkg
git checkout 2023.04.15
cd ..
vcpkg/bootstrap-vcpkg.sh
export VCPKG_ROOT=$HOME/vcpkg
vcpkg/vcpkg install libvpx libyuv opus aom
```

### Fix libvpx (For Fedora)

```sh
cd vcpkg/buildtrees/libvpx/src
cd *
./configure
sed -i 's/CFLAGS+=-I/CFLAGS+=-fPIC -I/g' Makefile
sed -i 's/CXXFLAGS+=-I/CXXFLAGS+=-fPIC -I/g' Makefile
make
cp libvpx.a $HOME/vcpkg/installed/x64-linux/lib/
cd
```

### Build

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
git clone --recurse-submodules https://github.com/rustdesk/rustdesk
cd uptimedesk
mkdir -p target/debug
wget https://raw.githubusercontent.com/c-smile/sciter-sdk/master/bin.lnx/x64/libsciter-gtk.so
mv libsciter-gtk.so target/debug
VCPKG_ROOT=$HOME/vcpkg cargo run
```

## How to build with Docker

Begin by cloning the repository and building the Docker container:

```sh
git clone https://github.com/Cricido/updesk
cd uptimedesk
docker build -t "uptimedesk-builder" .
```

Then, each time you need to build the application, run the following command:

```sh
docker run --rm -it -v $PWD:/home/user/rustdesk -v uptimedesk-git-cache:/home/user/.cargo/git -v uptimedesk-registry-cache:/home/user/.cargo/registry -e PUID="$(id -u)" -e PGID="$(id -g)" uptimedesk-builder
```

Note that the first build may take longer before dependencies are cached, subsequent builds will be faster. Additionally, if you need to specify different arguments to the build command, you may do so at the end of the command in the `<OPTIONAL-ARGS>` position. For instance, if you wanted to build an optimized release version, you would run the command above followed by `--release`. The resulting executable will be available in the target folder on your system, and can be run with:

```sh
target/debug/rustdesk
```

Or, if you're running a release executable:

```sh
target/release/rustdesk
```

Please ensure that you run these commands from the root of the UptimeDesk repository, or the application may not find the required resources. Also note that other cargo subcommands such as `install` or `run` are not currently supported via this method as they would install or run the program inside the container instead of the host.

## File Structure

- **[libs/hbb_common](https://github.com/Cricido/updesk/tree/main/libs/hbb_common)**: video codec, config, tcp/udp wrapper, protobuf, fs functions for file transfer, and utility functions
- **[libs/scrap](https://github.com/Cricido/updesk/tree/main/libs/scrap)**: screen capture
- **[libs/enigo](https://github.com/Cricido/updesk/tree/main/libs/enigo)**: platform specific keyboard/mouse control
- **[libs/clipboard](https://github.com/Cricido/updesk/tree/main/libs/clipboard)**: file copy and paste implementation for Windows, Linux, macOS
- **[src/ui](https://github.com/Cricido/updesk/tree/main/src/ui)**: obsolete Sciter UI (deprecated)
- **[src/server](https://github.com/Cricido/updesk/tree/main/src/server)**: audio/clipboard/input/video services, and network connections
- **[src/client.rs](https://github.com/Cricido/updesk/tree/main/src/client.rs)**: start a peer connection
- **[src/rendezvous_mediator.rs](https://github.com/Cricido/updesk/tree/main/src/rendezvous_mediator.rs)**: communicate with rendezvous / relay infrastructure and select direct or relayed connection
- **[src/platform](https://github.com/Cricido/updesk/tree/main/src/platform)**: platform specific code
- **[flutter](https://github.com/Cricido/updesk/tree/main/flutter)**: Flutter code for desktop and mobile
- **[server](https://github.com/Cricido/updesk/tree/main/server)**: UpDesk relay/update compatibility helpers and deployment assets

## Screenshots

![Connection Manager](https://github.com/rustdesk/rustdesk/assets/28412477/db82d4e7-c4bc-4823-8e6f-6af7eadf7651)

![Connected to a Windows PC](https://github.com/rustdesk/rustdesk/assets/28412477/9baa91e9-3362-4d06-aa1a-7518edcbd7ea)

![File Transfer](https://github.com/rustdesk/rustdesk/assets/28412477/39511ad3-aa9a-4f8c-8947-1cce286a46ad)

![TCP Tunneling](https://github.com/rustdesk/rustdesk/assets/28412477/78e8708f-e87e-4570-8373-1360033ea6c5)
