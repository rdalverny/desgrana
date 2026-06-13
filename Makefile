-include Makefile.local

VERSION        := $(shell cat VERSION)
DATE           := $(shell date +"%B %-d %Y")
GITHUB_REPO    := rdalverny/desgrana
GITHUB_BASE    := https://github.com/$(GITHUB_REPO)/releases/download
TEAM_ID        ?=
SIGN_IDENTITY  ?= Developer ID Application: $(TEAM_ID)
NOTARY_PROFILE ?=
ENTITLEMENTS   := desgrana/Sources/App/Desgrana.entitlements
APP            := Desgrana.app
BUILD          := var/build
DIST           := dist
APP_BUILD      := $(BUILD)/$(APP)
PLIST          := $(APP_BUILD)/Contents/Info.plist

DOCKER         ?= docker
BUILDX_BUILDER = multi

SPM_NATIVE_DIR := desgrana/.build/release
SPM_UNIV_DIR   := desgrana/.build/apple/Products/Release

.PHONY: cli cli-universal app app-universal bundle bundle-universal build build-universal \
        test test-generate package shipit release sign notarize icon \
        patch minor clean lint lint-fix format format-check package-debian test-image test-debian

# ── Build ─────────────────────────────────────────────────────────

cli:
	cd desgrana && swift build -c release --product desgrana
	mkdir -p $(BUILD)
	cp $(SPM_NATIVE_DIR)/desgrana $(BUILD)/desgrana
	strip -S $(BUILD)/desgrana
	@echo "CLI → $(BUILD)/desgrana"

cli-universal:
	cd desgrana && swift build -c release --product desgrana --arch arm64 --arch x86_64
	mkdir -p $(BUILD)
	cp $(SPM_UNIV_DIR)/desgrana $(BUILD)/desgrana
	strip -S $(BUILD)/desgrana
	@echo "CLI (universal) → $(BUILD)/desgrana"

app:
	cd desgrana && swift build -c release --product DesgranaApp

app-universal:
	cd desgrana && swift build -c release --product DesgranaApp --arch arm64 --arch x86_64

bundle: app
	rm -rf $(APP_BUILD)
	mkdir -p $(BUILD)
	cp -r app-template/ $(APP_BUILD)
	mkdir -p $(APP_BUILD)/Contents/MacOS
	cp $(SPM_NATIVE_DIR)/DesgranaApp $(APP_BUILD)/Contents/MacOS/
	strip -S $(APP_BUILD)/Contents/MacOS/DesgranaApp
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)"            $(PLIST)
	@echo "Built: $(APP_BUILD) ($(VERSION))"

bundle-universal: app-universal
	rm -rf $(APP_BUILD)
	mkdir -p $(BUILD)
	cp -r app-template/ $(APP_BUILD)
	mkdir -p $(APP_BUILD)/Contents/MacOS
	cp $(SPM_UNIV_DIR)/DesgranaApp $(APP_BUILD)/Contents/MacOS/
	strip -S $(APP_BUILD)/Contents/MacOS/DesgranaApp
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)"            $(PLIST)
	@echo "Built (universal): $(APP_BUILD) ($(VERSION))"

test-unit:
	cd desgrana && swift test

test: cli test-unit
	python3 desgrana/Tests/test_split.py $(BUILD)/desgrana

test-generate: cli
	python3 desgrana/Tests/test_split.py --generate $(BUILD)/desgrana

build: cli bundle
build-universal: cli-universal bundle-universal


# ── version ─────────────────────────────────────────────────────────
define bump-version
	@NEW=$$(cat VERSION); \
	 DATE=$$(date +"%Y-%m-%d"); \
	 RFC_DATE=$$(date -R); \
	 MAINT="Romain d'Alverny <rwx@romaindalverny.com>"; \
	 sed -i '' "s/^# Changelog$$/# Changelog\n\n## [$$NEW] — $$DATE\n/" CHANGELOG.md; \
	 { printf 'desgrana (%s-1) unstable; urgency=medium\n\n  * Release %s.\n\n -- %s  %s\n\n' \
	     "$$NEW" "$$NEW" "$$MAINT" "$$RFC_DATE"; \
	   cat packaging/linux/deb/debian/changelog; } > /tmp/_deb_changelog \
	 && mv /tmp/_deb_changelog packaging/linux/deb/debian/changelog; \
	 echo "Version → $$NEW  (CHANGELOG.md + debian/changelog updated)"
endef

patch:
	@python3 -c "v=open('VERSION').read().strip().split('.');v=v+['0'] if len(v)<3 else v;v[2]=str(int(v[2])+1);open('VERSION','w').write('.'.join(v))"
	$(bump-version)

minor:
	@python3 -c "v=open('VERSION').read().strip().split('.');v=v+['0'] if len(v)<3 else v;v[1]=str(int(v[1])+1);v[2]='0';open('VERSION','w').write('.'.join(v))"
	$(bump-version)

# ── Lint ─────────────────────────────────────────────────────────

lint:
	cd desgrana && swiftlint lint --strict

clean:
	rm -rf desgrana/.build var/ dist/ $(APP) Desgrana.zip \
	    Desgrana.iconset/ Desgrana.xcassets/

fmtdoc:
	prettier --prose-wrap preserve --print-width 78 --write "**/*.md"

# ── Linux ────────────────────────────────────────────────────────
#SWIFT_RUNTIME_DIR ?= /usr/lib/swift/linux
SWIFT_RUNTIME_DIR ?= $(shell d=$$(dirname "$$(realpath "$$(command -v swiftc)")")/../lib/swift/linux; \
	[ -e "$$d/libswiftCore.so" ] && cd "$$d" && pwd || echo /usr/lib/swift/linux)

ARCH ?= amd64

build-linux:
	cd desgrana && swift build -c release --product desgrana
	cd desgrana && swift build -c release --target DesgranaBridgeC
	cmake -S qt -B var/build/qt -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
		-DSWIFT_BUILD_DIR=$(PWD)/desgrana/.build/release \
		-DSWIFT_RUNTIME_DIR=$(SWIFT_RUNTIME_DIR) \
		-DDESGRANA_INSTALL_RPATH=/usr/lib/desgrana
	cmake --build var/build/qt


# brew install colima docker docker-buildx
#
# # 1. Recréer la VM
# colima start --vm-type=vz --vz-rosetta --cpu 4 --memory 6
#
# # 2. Recréer le builder buildx
# docker buildx create --name multi --driver docker-container --use
# docker buildx inspect --bootstrap
#
# # après, colima delete, colima stop
#
# colima list 2>&1
# du -sh ~/.colima/_lima/*/  2>/dev/null
# docker system df 2>&1
#

package-debian:
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
		--platform linux/amd64 \
		-t desgrana-tester \
		-f packaging/linux/deb/tester.dockerfile .

test-debian:
	$(DOCKER) run --rm \
		--platform linux/amd64 \
		-v "$(PWD)/dist":/pkgs:ro \
		-v "$(PWD)/desgrana/Tests":/tests:ro \
		desgrana-tester \
		bash -c "dpkg -i /pkgs/desgrana_*.deb && python3 /tests/test_split.py /usr/bin/desgrana"



icon:
	python3 scripts/make_icon.py
	iconutil -c icns Desgrana.iconset \
	    -o app-template/Contents/Resources/AppIcon.icns
	mkdir -p var/build/icon-assets
	xcrun actool \
	    --compile var/build/icon-assets \
	    --platform macosx \
	    --minimum-deployment-target 15.3 \
	    --app-icon AppIcon \
	    --output-partial-info-plist var/build/icon-assets/partial-info.plist \
	    --skip-app-store-deployment \
	    Desgrana.xcassets 2>/dev/null
	cp var/build/icon-assets/Assets.car \
	    app-template/Contents/Resources/Assets.car
	@echo "Icon generated: AppIcon.icns + Assets.car"
