# syntax=docker/dockerfile:1.6
#
# Build context: repo root
#
# Produce a .deb (default):
#   docker buildx build --platform linux/amd64 \
#     -f packaging/linux/deb/builder.dockerfile \
#     --output type=local,dest=dist .
#
# Extract raw binaries (no packaging):
#   docker buildx build --platform linux/amd64 \
#     -f packaging/linux/deb/builder.dockerfile \
#     --target binaries \
#     --output type=local,dest=out .

ARG SWIFT_VERSION=6.0
ARG DEBIAN_CODENAME=bookworm

# Build
FROM swift:${SWIFT_VERSION}-${DEBIAN_CODENAME} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake ninja-build qt6-base-dev libgl1-mesa-dev libxkbcommon-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY VERSION                              ./VERSION
COPY desgrana/                            ./desgrana/

RUN cd desgrana \
    && swift build -c release --product desgrana -Xswiftc -static-stdlib -Xlinker --build-id \
    && swift build -c release --product DesgranaBridge \
        -Xlinker --build-id -Xlinker -rpath -Xlinker '$ORIGIN'

COPY qt/                                   ./qt/
COPY packaging/linux/collect-swift-libs.sh ./collect-swift-libs.sh

RUN cmake \
        -S qt \
        -B qt/build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DSWIFT_BUILD_DIR=/src/desgrana/.build/release \
        -DSWIFT_RUNTIME_DIR=/usr/lib/swift/linux \
        -DDESGRANA_INSTALL_RPATH=/usr/lib/desgrana \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    && cmake --build qt/build

RUN mkdir -p /src/swift-libs \
    && cp /src/desgrana/.build/release/libDesgranaBridge.so /src/swift-libs/ \
    && bash /src/collect-swift-libs.sh \
        /src/swift-libs/libDesgranaBridge.so \
        /usr/lib/swift/linux \
        /src/swift-libs


# Package
FROM debian:${DEBIAN_CODENAME}-slim AS packager
WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
        dpkg-dev fakeroot lintian debhelper \
        libqt6widgets6 libqt6gui6 libqt6core6 libqt6network6 libcurl4 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/desgrana/.build/release/desgrana ./src/desgrana
COPY --from=builder /src/qt/build/desgrana-gui          ./src/desgrana-gui
COPY --from=builder /src/swift-libs                        ./src/swift-libs
COPY packaging/linux/deb/debian                            ./src/debian
COPY packaging/linux/desgrana-gui.desktop                  ./src/desgrana-gui.desktop
COPY packaging/linux/icons                                 ./src/icons

WORKDIR /build/src
RUN dpkg-buildpackage -rfakeroot -us -uc -b -d

RUN pkg=$(dpkg-parsechangelog -S Source) && \
    ver=$(dpkg-parsechangelog -S Version) && \
    arch=$(dpkg --print-architecture) && \
    lintian ../${pkg}_${ver}_${arch}.deb || true


# Export
FROM scratch AS binaries
COPY --from=builder /src/desgrana/.build/release/desgrana /desgrana
COPY --from=builder /src/qt/build/desgrana-gui            /desgrana-gui
COPY --from=builder /src/swift-libs/                       /swift-libs/

# Export .deb
FROM scratch AS export
COPY --from=packager /build/*.deb /
