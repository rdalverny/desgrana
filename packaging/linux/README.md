# Dev setup for Linux

```shell
sudo apt install binutils libcurl4 libxml2 libz3-dev

# Go to https://www.swift.org/install/linux/
# and follow instructions to install Swift for your system
# then, install requested dependencies, then

# Install those build dependencies
sudo apt install cmake ninja-build qt6-base-dev libgl1-mesa-dev libxkbcommon-dev git

# Code & build
git clone <repo> desgrana-repo && cd desgrana-repo

# CLI + bridge
cd desgrana && swift build -c release --product desgrana
cd desgrana && swift build -c release --target DesgranaBridgeC

# then GUI
cmake -S qt -B qt/build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DSWIFT_BUILD_DIR=$(PWD)/desgrana/.build/release \
  -DSWIFT_RUNTIME_DIR=$(SWIFT_RUNTIME_DIR) \
  -DDESGRANA_INSTALL_RPATH=/usr/lib/desgrana
cmake --build qt/build

./linux/build/desgrana-linux
```
