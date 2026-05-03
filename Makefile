-include Makefile.local

VERSION        := $(shell cat VERSION)
DATE           := $(shell date +"%B %-d %Y")
GITHUB_REPO    := rdalverny/desgrana
GITHUB_BASE    := https://github.com/$(GITHUB_REPO)/releases/download
TEAM_ID        ?=
SIGN_IDENTITY  ?= Developer ID Application: $(TEAM_ID)
NOTARY_PROFILE ?=
DOCKER         ?= docker
ENTITLEMENTS   := desgrana/Sources/App/Desgrana.entitlements
APP            := Desgrana.app
BUILD          := var/build
SHIPIT         := var/shipit
APP_BUILD      := $(BUILD)/$(APP)
PLIST          := $(APP_BUILD)/Contents/Info.plist

.PHONY: cli cli-linux app bundle build test test-generate package shipit release sign notarize icon \
       patch minor clean lint lint-fix format format-check package-debian

# ── Build ─────────────────────────────────────────────────────────

cli:
	cd desgrana && \
		swift build -c release --product desgrana
	mkdir -p $(SHIPIT)
	cp desgrana/.build/release/desgrana $(SHIPIT)/desgrana
	@echo "CLI → $(SHIPIT)/desgrana"

app:
	cd desgrana && \
		swift build -c release --product DesgranaApp

bundle: app
	rm -rf $(APP_BUILD)
	mkdir -p $(BUILD)
	cp -r app-template/ $(APP_BUILD)
	mkdir -p $(APP_BUILD)/Contents/MacOS
	cp desgrana/.build/release/DesgranaApp $(APP_BUILD)/Contents/MacOS/
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)"            $(PLIST)
	@echo "Built: $(APP_BUILD) ($(VERSION))"

cli-linux:
	cd desgrana && \
		swift build -c release --product desgrana
	@echo "CLI Linux → desgrana/.build/release/desgrana"

test: cli
	python3 desgrana/Tests/test_split.py $(SHIPIT)/desgrana

test-generate: cli
	python3 desgrana/Tests/test_split.py --generate $(SHIPIT)/desgrana

build: cli bundle


# ── signature, notarization
sign: build
	codesign --deep --force --options runtime \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(SIGN_IDENTITY)" \
		$(APP_BUILD)
	codesign --verify --verbose $(APP_BUILD)

	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" \
		$(SHIPIT)/desgrana
	codesign --verify --verbose $(SHIPIT)/desgrana

	mkdir -p $(SHIPIT)
	rm -rf $(SHIPIT)/$(APP)
	cp -r $(APP_BUILD) $(SHIPIT)/$(APP)
	@echo "Signed → $(SHIPIT)/$(APP), $(SHIPIT)/desgrana"

package: sign
	bash packaging/macos/make-dmg.sh \
		"$(SHIPIT)/$(APP)" \
		"$(SHIPIT)/desgrana" \
		"$(VERSION)" \
		"$(SHIPIT)/Desgrana-$(VERSION).dmg"

notarize: package
	xcrun notarytool submit "$(SHIPIT)/Desgrana-$(VERSION).dmg" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait
	xcrun stapler staple "$(SHIPIT)/Desgrana-$(VERSION).dmg"
	@echo "Notarized → $(SHIPIT)/Desgrana-$(VERSION).dmg"

release: notarize
	gh release create "v$(VERSION)" \
		--draft \
		"$(SHIPIT)/Desgrana-$(VERSION).dmg" \
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

	@echo "var/shipit/ contains: $$(ls $(SHIPIT))"

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
	rm -rf desgrana/.build var/ $(APP) Desgrana.zip dist/

fmtdoc:
	prettier --prose-wrap always --print-width 78 --write "**/*.md"

# ── Linux ────────────────────────────────────────────────────────

package-debian:
	rm -rf dist/
	$(DOCKER) buildx build \
		--progress=plain \
		--platform linux/amd64 \
		-f packaging/linux/deb/builder.dockerfile \
		--output type=local,dest=dist \
		.
	cd dist && shasum -a 256 *.deb > SHA256SUMS
	@echo "Package in dist/"
	@ls -lh dist/*.deb
	@cat dist/SHA256SUMS
