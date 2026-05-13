# syntax=docker/dockerfile:1.6
#
# Package pre-built binaries into a .rpm.
# Build context: repo root, with binaries/ populated from builder.dockerfile --target binaries.
#
# Usage:
#   docker buildx build \
#     --platform linux/amd64 \
#     -f packaging/linux/rpm/packager.dockerfile \
#     --output type=local,dest=dist \
#     .

FROM fedora:41 AS packager

RUN dnf install -y rpm-build qt6-qtbase libcurl && dnf clean all

WORKDIR /build/src

COPY VERSION                              ./VERSION
COPY binaries/desgrana                    ./desgrana
COPY binaries/desgrana-gui                ./desgrana-gui
COPY binaries/swift-libs/                 ./swift-libs/
COPY packaging/linux/desgrana-gui.desktop ./desgrana-gui.desktop
COPY packaging/linux/icons/               ./icons/
COPY packaging/linux/rpm/desgrana.spec    ./desgrana.spec

RUN VERSION=$(cat VERSION) && \
    mkdir -p /build/rpmbuild/{BUILD,RPMS,SRPMS,SPECS,SOURCES} && \
    rpmbuild -bb \
        --define "_topdir /build/rpmbuild" \
        --define "_sourcedir /build/src" \
        --define "_pkg_version $VERSION" \
        /build/src/desgrana.spec

FROM scratch AS export
COPY --from=packager /build/rpmbuild/RPMS/*/*.rpm /
