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
ARG TARGET_ARCH=amd64

FROM debian:${DEBIAN_CODENAME}-slim AS packager

ARG TARGET_ARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        dpkg-dev fakeroot lintian debhelper devscripts \
        libqt6widgets6 libqt6gui6 libqt6core6 libqt6network6 libcurl4 \
    && if [ "${TARGET_ARCH}" != "$(dpkg --print-architecture)" ]; then \
        gnu_type=$(dpkg-architecture -A "${TARGET_ARCH}" -q DEB_HOST_GNU_TYPE) && \
        dpkg --add-architecture "${TARGET_ARCH}" && \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            "binutils-${gnu_type}" \
            "libqt6widgets6:${TARGET_ARCH}" \
            "libqt6gui6:${TARGET_ARCH}" \
            "libqt6core6:${TARGET_ARCH}" \
            "libqt6network6:${TARGET_ARCH}" \
            "libcurl4:${TARGET_ARCH}"; \
    fi \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/src

COPY VERSION                              ./VERSION
COPY binaries/desgrana                    ./desgrana
COPY binaries/desgrana-gui                ./desgrana-gui
COPY binaries/swift-libs/                 ./swift-libs/
COPY packaging/linux/deb/debian/          ./debian/
COPY packaging/linux/desgrana-gui.desktop ./desgrana-gui.desktop
COPY packaging/linux/icons/               ./icons/

RUN VERSION=$(cat VERSION) && \
    CHANGELOG_VER=$(dpkg-parsechangelog -S Version | sed 's/-[^-]*$//') && \
    if [ "$VERSION" != "$CHANGELOG_VER" ]; then \
        DEBEMAIL="rwx@romaindalverny.com" DEBFULLNAME="Romain d'Alverny" \
        dch --newversion "${VERSION}-1" --distribution unstable "Release ${VERSION}."; \
    fi

RUN LC_ALL=C dpkg-buildpackage -rfakeroot -us -uc -b -d --host-arch ${TARGET_ARCH}

RUN pkg=$(dpkg-parsechangelog -S Source) && \
    ver=$(dpkg-parsechangelog -S Version) && \
    lintian ../${pkg}_${ver}_${TARGET_ARCH}.deb || true

FROM scratch AS export
COPY --from=packager /build/desgrana_*.deb /
