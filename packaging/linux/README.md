# Dev setup for Linux

## Prerequisites

```shell
sudo apt install binutils libcurl4 libxml2 libz3-dev

# Go to https://www.swift.org/install/linux/
# and follow instructions to install Swift for your system
# then, install requested dependencies, then

# Install those build dependencies
sudo apt install cmake ninja-build qt6-base-dev libgl1-mesa-dev libxkbcommon-dev git

# Code & build
git clone <repo> desgrana-repo && cd desgrana-repo
```

## Build

You may need to adjust SWIFT\_\* vars in Makefile

```sh
make build-linux
```

```sh
./linux/build/desgrana-gui
```

## Packaged build (Docker)

```sh
make package-debian        # amd64 .deb → dist/
make package-debian-arm64  # arm64 .deb → dist/
```

## Running tests

```sh
make test-image   # build the tester Docker image (once)
make test-debian  # install the .deb and run the CLI test suite
```
