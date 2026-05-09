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
	@echo "CLI → $(BUILD)/desgrana"

cli-universal:
	cd desgrana && swift build -c release --product desgrana --arch arm64 --arch x86_64
	mkdir -p $(BUILD)
	cp $(SPM_UNIV_DIR)/desgrana $(BUILD)/desgrana
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
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)"            $(PLIST)
	@echo "Built: $(APP_BUILD) ($(VERSION))"

bundle-universal: app-universal
	rm -rf $(APP_BUILD)
	mkdir -p $(BUILD)
	cp -r app-template/ $(APP_BUILD)
	mkdir -p $(APP_BUILD)/Contents/MacOS
	cp $(SPM_UNIV_DIR)/DesgranaApp $(APP_BUILD)/Contents/MacOS/
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)"            $(PLIST)
	@echo "Built (universal): $(APP_BUILD) ($(VERSION))"

test: cli
	python3 desgrana/Tests/test_split.py $(BUILD)/desgrana

test-generate: cli
	python3 desgrana/Tests/test_split.py --generate $(BUILD)/desgrana

build: cli bundle
build-universal: cli-universal bundle-universal


# ── signature, notarization
sign: build
	codesign --deep --force --options runtime \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(SIGN_IDENTITY)" \
		$(APP_BUILD)
	codesign --verify --verbose $(APP_BUILD)

	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" \
		$(BUILD)/desgrana
	codesign --verify --verbose $(BUILD)/desgrana
	@echo "Signed → $(APP_BUILD), $(BUILD)/desgrana"

package: sign
	mkdir -p $(DIST)
	bash packaging/macos/make-dmg.sh \
		"$(APP_BUILD)" \
		"$(BUILD)/desgrana" \
		"$(VERSION)" \
		"$(DIST)/Desgrana-$(VERSION).dmg"

notarize: package
	xcrun notarytool submit "$(DIST)/Desgrana-$(VERSION).dmg" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	xcrun stapler staple "$(DIST)/Desgrana-$(VERSION).dmg"
	@echo "Notarized → $(DIST)/Desgrana-$(VERSION).dmg"

release: notarize
	gh release create "v$(VERSION)" \
		--draft \
		"$(DIST)/Desgrana-$(VERSION).dmg" \
		--title "Desgrana $(VERSION)" \
		--notes-file CHANGELOG.md

shipit: release
	sed -i '' \
		-e 's|href="[^"]*Desgrana-[0-9.]*\.dmg"|href="$(GITHUB_BASE)/v$(VERSION)/Desgrana-$(VERSION).dmg"|' \
		-e 's|Download Desgrana [0-9.]* ([^)]*)|Download Desgrana $(VERSION) ($(DATE))|' \
		web/index.html
	@echo "web/index.html → $(VERSION) ($(DATE))"

	python3 -c "import json; f='web/version.json'; d=json.load(open(f)); d['version']='$(VERSION)'; d['url']='https://github.com/$(GITHUB_REPO)/releases/tag/v$(VERSION)'; json.dump(d, open(f,'w'), indent=2); open(f,'a').write('\n')"
	@echo "web/version.json → $(VERSION)"

	@echo "dist/ contains: $$(ls $(DIST))"

# ── version ─────────────────────────────────────────────────────────
patch:
	@python3 -c "v=open('VERSION').read().strip().split('.');v=v+['0'] if len(v)<3 else v;v[2]=str(int(v[2])+1);open('VERSION','w').write('.'.join(v))"
	@NEW=$$(cat VERSION); \
	 DATE=$$(date +"%Y-%m-%d"); \
	 sed -i '' "s/^# Changelog$$/# Changelog\n\n## [$$NEW] — $$DATE\n/" CHANGELOG.md; \
	 echo "Version → $$NEW  (CHANGELOG.md prepared, edit manually)"

minor:
	@python3 -c "v=open('VERSION').read().strip().split('.');v=v+['0'] if len(v)<3 else v;v[1]=str(int(v[1])+1);v[2]='0';open('VERSION','w').write('.'.join(v))"
	@NEW=$$(cat VERSION); \
	 DATE=$$(date +"%Y-%m-%d"); \
	 sed -i '' "s/^# Changelog$$/# Changelog\n\n## [$$NEW] — $$DATE\n/" CHANGELOG.md; \
	 echo "Version → $$NEW  (CHANGELOG.md prepared, edit manually)"

# ── Lint ─────────────────────────────────────────────────────────

lint:
	cd desgrana && swiftlint lint --strict

clean:
	rm -rf desgrana/.build var/ dist/ $(APP) Desgrana.zip

fmtdoc:
	prettier --prose-wrap always --print-width 78 --write "**/*.md"

# ── Linux ────────────────────────────────────────────────────────
SWIFT_RUNTIME_DIR ?= /usr/lib/swift/linux

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
