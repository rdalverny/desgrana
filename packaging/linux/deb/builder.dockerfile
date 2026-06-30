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
#
# Swift official images exist for linux/amd64 and linux/arm64.
# Docker Buildx selects the right one automatically for the target platform.
# dpkg --print-architecture reflects the target arch, so the .deb is named correctly.

ARG SWIFT_VERSION=6.0
ARG DEBIAN_CODENAME=bookworm

# ── 1. Build the CLI and GUI binaries ────────────────────────────────────────

FROM swift:${SWIFT_VERSION}-${DEBIAN_CODENAME} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake ninja-build qt6-base-dev libgl1-mesa-dev libxkbcommon-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY VERSION                              ./VERSION
COPY desgrana/                            ./desgrana/

# CLI (static stdlib + GNU build-id) then the shared bridge library consumed by the GUI.
# $ORIGIN rpath: the bridge .so resolves its sibling Swift runtime dylibs from its
# own install dir (/usr/lib/desgrana), since the GUI's RUNPATH won't cover them transitively.
RUN cd desgrana \
    && swift build -c release --product desgrana -Xswiftc -static-stdlib -Xlinker --build-id \
    && swift build -c release --product DesgranaBridge \
        -Xlinker --build-id -Xlinker -rpath -Xlinker '$ORIGIN'

COPY qt/                                   ./qt/
COPY packaging/linux/collect-swift-libs.sh ./collect-swift-libs.sh

# GUI: Qt6, RPATH baked to /usr/lib/desgrana (where the .deb will install Swift dylibs)
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

# Bundle the bridge library and the Swift dylibs it pulls, recursively. The GUI
# now reaches the Swift runtime through libDesgranaBridge.so, so we seed the
# collection from the bridge itself. System libs (libcurl, libQt6, …) are
# excluded — they become package dependencies.
RUN mkdir -p /src/swift-libs \
    && cp /src/desgrana/.build/release/libDesgranaBridge.so /src/swift-libs/ \
    && bash /src/collect-swift-libs.sh \
        /src/swift-libs/libDesgranaBridge.so \
        /usr/lib/swift/linux \
        /src/swift-libs

# ── 2. Package as .deb ────────────────────────────────────────────────────────

FROM debian:${DEBIAN_CODENAME}-slim AS packager
WORKDIR /build

# Qt6 libs needed for dh_shlibdeps to resolve GUI shared library dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        dpkg-dev fakeroot lintian debhelper \
        libqt6widgets6 libqt6gui6 libqt6core6 libqt6network6 libcurl4 \
    && rm -rf /var/lib/apt/lists/*

# Binaries and bundled Swift dylibs
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

# ── 3. Export raw binaries + Swift libs (--target binaries) ──────────────────

FROM scratch AS binaries
COPY --from=builder /src/desgrana/.build/release/desgrana /desgrana
COPY --from=builder /src/qt/build/desgrana-gui            /desgrana-gui
COPY --from=builder /src/swift-libs/                       /swift-libs/

# ── 4. Export .deb only (default stage) ──────────────────────────────────────

FROM scratch AS export
COPY --from=packager /build/*.deb /
