# Linux binaries + .deb/.rpm packaging, built in Docker (via colima on macOS).
# Included by the top-level Makefile, which defines the shared variables this
# fragment relies on (BUILDINFO target, etc.).

DOCKER         ?= docker
BUILDX_BUILDER = multi
COLIMA_CPU     ?= 4
COLIMA_MEMORY  ?= 6

#SWIFT_RUNTIME_DIR ?= /usr/lib/swift/linux
SWIFT_RUNTIME_DIR ?= $(shell d=$$(dirname "$$(realpath "$$(command -v swiftc)")")/../lib/swift/linux; \
	[ -e "$$d/libswiftCore.so" ] && cd "$$d" && pwd || echo /usr/lib/swift/linux)

ARCH ?= amd64

.PHONY: build-linux docker-up docker-down docker-clean \
        package-debian package-debian-all package-linux-native test-image test-debian rpm


# Docker engine for the Linux .deb/.rpm builds, via colima (macOS).
# Prerequisites: brew install colima docker docker-buildx
#
# Start colima + a docker-container buildx builder (needed for --output type=local).
# Idempotent: safe to re-run; reuses the VM and builder if already there.
# --vz-rosetta gives linux/amd64 emulation; arm64 builds run natively.
docker-up:
	colima start --vm-type=vz --vz-rosetta --cpu $(COLIMA_CPU) --memory $(COLIMA_MEMORY)
	$(DOCKER) buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 \
		|| $(DOCKER) buildx create --name $(BUILDX_BUILDER) --driver docker-container
	$(DOCKER) buildx use $(BUILDX_BUILDER)
	$(DOCKER) buildx inspect --bootstrap

# Stop the VM (and the builder running inside it). Fast restart, nothing lost.
docker-down:
	colima stop

# Remove the builder and delete the VM entirely (reclaims disk).
docker-clean:
	-$(DOCKER) buildx rm $(BUILDX_BUILDER)
	colima delete --force

# buildinfo regenerates desgrana/Sources/Core/BuildInfo.swift on the host before
# the Docker build COPYs desgrana/ in — otherwise the binary bakes a stale version
# (the dockerfile does not generate it; CI runs `make buildinfo` as a prior step).
package-debian: buildinfo
	# --progress=plain
	$(DOCKER) buildx build \
		--platform linux/$(ARCH) \
		-f packaging/linux/deb/builder.dockerfile \
		--output type=local,dest=dist \
		.

package-debian-all:
	$(MAKE) package-debian ARCH=amd64
	$(MAKE) package-debian ARCH=arm64
	cd dist && shasum -a 256 *.deb > SHA256SUMS
	@echo "Package in dist/"
	@ls -lh dist/*.deb
	@cat dist/SHA256SUMS

test-image:
	$(DOCKER) build \
		--load \
		--platform linux/$(ARCH) \
		-t desgrana-tester \
		-f packaging/linux/deb/tester.dockerfile .

# Installs the exact arch+version package (not a glob) so a polluted dist/ with
# old versions or other arches can't be picked up by mistake. Checks, in order:
# the CLI split tests, that every GUI dynamic dep resolves (the real test of the
# bridge's $ORIGIN rpath reaching the bundled Swift runtime), and that the GUI
# binary starts without a loader/init crash.
test-debian:
	$(DOCKER) run --rm \
		--platform linux/$(ARCH) \
		-e DESGRANA_VERSION=$(VERSION) \
		-v "$(PWD)/dist":/pkgs:ro \
		-v "$(PWD)/desgrana/Tests":/tests:ro \
		desgrana-tester \
		bash -c 'set -e; \
			dpkg -i /pkgs/desgrana_$(VERSION)-1_$(ARCH).deb; \
			python3 /tests/test_split.py /usr/bin/desgrana; \
			missing=$$(ldd /usr/bin/desgrana-gui | grep "not found" || true); \
			[ -z "$$missing" ] || { echo "GUI has unresolved libraries:"; echo "$$missing"; exit 1; }; \
			if QT_QPA_PLATFORM=offscreen timeout 5 desgrana-gui; then rc=0; else rc=$$?; fi; \
			case $$rc in 0|124) echo "GUI: all libraries resolved, starts cleanly." ;; \
				*) echo "GUI failed to start (exit $$rc)"; exit 1 ;; esac'

# Build the Linux CLI + Qt GUI as package-ready binaries: static-stdlib CLI, GNU
# build-id, and the install rpath (/usr/lib/desgrana) baked in. Single source of
# truth for the Linux build — package-linux-native just wraps it with packaging.
# Note: because the rpath is the install path, the GUI won't run straight from
# var/build/qt without LD_LIBRARY_PATH — test it via the installed .deb.
build-linux: buildinfo
	cd desgrana \
		&& swift build -c release --product desgrana -Xswiftc -static-stdlib -Xlinker --build-id \
		&& swift build -c release --product DesgranaBridge \
			-Xlinker --build-id -Xlinker -rpath -Xlinker '$$ORIGIN'
	cmake -S qt -B var/build/qt -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DSWIFT_BUILD_DIR=$(PWD)/desgrana/.build/release \
		-DSWIFT_RUNTIME_DIR=$(SWIFT_RUNTIME_DIR) \
		-DDESGRANA_INSTALL_RPATH=/usr/lib/desgrana \
		-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
	cmake --build var/build/qt

# Package directly on the current Debian/Ubuntu host (no Docker). Reuses
# build-linux for the binaries, then assembles and builds the .deb.
# One-time setup:
#   sudo apt-get install cmake ninja-build qt6-base-dev libgl1-mesa-dev libxkbcommon-dev \
#                        dpkg-dev fakeroot debhelper lintian \
#                        libqt6widgets6 libqt6gui6 libqt6core6
# Output: dist/desgrana_<version>_<arch>.deb
package-linux-native: build-linux
	mkdir -p dist var/swift-libs
	# Copy all Swift runtime dylibs needed at runtime. Using a glob rather than
	# readelf to avoid chasing transitive deps across Swift toolchain versions.
	cp $(SWIFT_RUNTIME_DIR)/libswift*.so \
	   $(SWIFT_RUNTIME_DIR)/libFoundation*.so \
	   $(SWIFT_RUNTIME_DIR)/lib_Foundation*.so \
	   $(SWIFT_RUNTIME_DIR)/libdispatch.so \
	   $(SWIFT_RUNTIME_DIR)/libBlocksRuntime.so \
	   var/swift-libs/ 2>/dev/null || true
	# The shared bridge library itself, shipped to /usr/lib/desgrana next to the
	# runtime it resolves via its $$ORIGIN rpath.
	cp desgrana/.build/release/libDesgranaBridge.so var/swift-libs/
	mkdir -p var/pkg-src
	cp desgrana/.build/release/desgrana  var/pkg-src/desgrana
	cp var/build/qt/desgrana-gui         var/pkg-src/desgrana-gui
	cp -r var/swift-libs                 var/pkg-src/swift-libs
	cp -r packaging/linux/deb/debian     var/pkg-src/debian
	cp    packaging/linux/desgrana-gui.desktop var/pkg-src/desgrana-gui.desktop
	cp -r packaging/linux/icons          var/pkg-src/icons
	cd var/pkg-src && LC_ALL=C dpkg-buildpackage -rfakeroot -us -uc -b -d
	cp var/*.deb dist/
	@echo "Package in dist/"
	@ls -lh dist/*.deb
