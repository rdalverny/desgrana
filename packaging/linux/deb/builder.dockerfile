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
COPY VERSION   ./VERSION
COPY desgrana/ ./desgrana/
COPY qt/       ./qt/

# CLI (static stdlib + GNU build-id) then bridge library
RUN cd desgrana \
    && swift build -c release --product desgrana -Xswiftc -static-stdlib -Xlinker --build-id \
    && swift build -c release --target DesgranaBridgeC

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

# Collect Swift dylibs actually referenced by desgrana-gui.
# ldd is unusable here because CMAKE_BUILD_WITH_INSTALL_RPATH=ON bakes /usr/lib/desgrana
# as the RPATH, so ldd reports "not found" for every Swift lib at build time.
# readelf -d reads the ELF NEEDED entries directly, independent of RPATH resolution.
RUN mkdir -p /src/swift-libs \
    && readelf -d /src/qt/build/desgrana-linux \
       | grep 'NEEDED' \
       | sed 's/.*\[//;s/\]//' \
       | grep -E 'swift|Foundation|dispatch|BlocksRuntime' \
       | xargs -I{} cp /usr/lib/swift/linux/{} /src/swift-libs/ \
    && ls /src/swift-libs/ \
    && [ -n "$(ls /src/swift-libs/)" ]

# ── 2. Package as .deb ────────────────────────────────────────────────────────

FROM debian:${DEBIAN_CODENAME}-slim AS packager
WORKDIR /build

# Qt6 libs needed for dh_shlibdeps to resolve GUI shared library dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        dpkg-dev fakeroot lintian debhelper \
        libqt6widgets6 libqt6gui6 libqt6core6 \
    && rm -rf /var/lib/apt/lists/*

# Binaries and bundled Swift dylibs
COPY --from=builder /src/desgrana/.build/release/desgrana ./src/desgrana
COPY --from=builder /src/qt/build/desgrana-linux        ./src/desgrana-gui
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

# ── 3. Export raw binaries (--target binaries) ────────────────────────────────

FROM scratch AS binaries
COPY --from=builder /src/desgrana/.build/release/desgrana /desgrana
COPY --from=builder /src/qt/build/desgrana-linux       /desgrana-gui

# ── 4. Export .deb only (default stage) ──────────────────────────────────────

FROM scratch AS export
COPY --from=packager /build/*.deb /
