# syntax=docker/dockerfile:1.6
#
# Package pre-built binaries into a .deb.
# Build context: repo root, with binaries/ populated from builder.dockerfile --target binaries.
#
# Usage (after extracting binaries to binaries/):
#   docker buildx build \
#     --platform linux/amd64 \
#     -f packaging/linux/deb/packager.dockerfile \
#     --output type=local,dest=dist \
#     .

ARG DEBIAN_CODENAME=bookworm

FROM debian:${DEBIAN_CODENAME}-slim AS packager

RUN apt-get update && apt-get install -y --no-install-recommends \
        dpkg-dev fakeroot lintian debhelper \
        libqt6widgets6 libqt6gui6 libqt6core6 libqt6network6 libcurl4 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/src

COPY binaries/desgrana                    ./desgrana
COPY binaries/desgrana-gui                ./desgrana-gui
COPY binaries/swift-libs/                 ./swift-libs/
COPY packaging/linux/deb/debian/          ./debian/
COPY packaging/linux/desgrana-gui.desktop ./desgrana-gui.desktop
COPY packaging/linux/icons/               ./icons/

RUN LC_ALL=C dpkg-buildpackage -rfakeroot -us -uc -b -d

RUN pkg=$(dpkg-parsechangelog -S Source) && \
    ver=$(dpkg-parsechangelog -S Version) && \
    arch=$(dpkg --print-architecture) && \
    lintian ../${pkg}_${ver}_${arch}.deb || true

FROM scratch AS export
COPY --from=packager /build/desgrana_*.deb /
