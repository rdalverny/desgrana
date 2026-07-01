# macOS app: universal build, .app bundle, codesigning, notarization, DMG, icon.
# Included by the top-level Makefile, which defines the shared variables
# (NAME, VERSION, BUILD, DIST, CLI_BUILD…) this fragment relies on.

TEAM_ID        ?=
SIGN_IDENTITY  ?= Developer ID Application: $(TEAM_ID)
NOTARY_PROFILE ?=
ENTITLEMENTS   := desgrana/Sources/App/$(NAME).entitlements
APP            := $(NAME).app
APP_BUILD      := $(BUILD)/$(APP)
PLIST          := $(APP_BUILD)/Contents/Info.plist
SPM_UNIV_DIR    := desgrana/.build/apple/Products/Release
SPM_APP_PRODUCT := DesgranaApp
DMG             := $(DIST)/$(NAME)-$(VERSION).dmg

.PHONY: cli-universal app app-universal bundle bundle-universal build build-universal \
        run sign package shipit release notarize verify-dmg icon

cli-universal: buildinfo
	cd desgrana && swift build -c release --product desgrana --arch arm64 --arch x86_64
	mkdir -p $(BUILD)
	cp $(SPM_UNIV_DIR)/desgrana $(CLI_BUILD)
	strip -S $(CLI_BUILD)
	@echo "CLI (universal) → $(CLI_BUILD)"

app: buildinfo
	cd desgrana && swift build -c release --product $(SPM_APP_PRODUCT)

app-universal: buildinfo
	cd desgrana && swift build -c release --product $(SPM_APP_PRODUCT) --arch arm64 --arch x86_64

bundle: app
	rm -rf $(APP_BUILD)
	mkdir -p $(BUILD)
	cp -r app-template/ $(APP_BUILD)
	mkdir -p $(APP_BUILD)/Contents/MacOS
	cp $(SPM_NATIVE_DIR)/$(SPM_APP_PRODUCT) $(APP_BUILD)/Contents/MacOS/
	strip -S $(APP_BUILD)/Contents/MacOS/$(SPM_APP_PRODUCT)
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)"            $(PLIST)
	@echo "Built: $(APP_BUILD) ($(VERSION))"

bundle-universal: app-universal
	rm -rf $(APP_BUILD)
	mkdir -p $(BUILD)
	cp -r app-template/ $(APP_BUILD)
	mkdir -p $(APP_BUILD)/Contents/MacOS
	cp $(SPM_UNIV_DIR)/$(SPM_APP_PRODUCT) $(APP_BUILD)/Contents/MacOS/
	strip -S $(APP_BUILD)/Contents/MacOS/$(SPM_APP_PRODUCT)
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)"            $(PLIST)
	@echo "Built (universal): $(APP_BUILD) ($(VERSION))"

build: cli bundle
build-universal: cli-universal bundle-universal

run: build
	rm -rf /Applications/$(APP) && cp -r var/build/$(APP) /Applications/
	open -a $(NAME)

# ── signature, notarization
sign: build-universal
	codesign --deep --force --options runtime \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(SIGN_IDENTITY)" \
		$(APP_BUILD)
	codesign --verify --verbose $(APP_BUILD)

	codesign --force --options runtime \
		--sign "$(SIGN_IDENTITY)" \
		$(CLI_BUILD)
	codesign --verify --verbose $(CLI_BUILD)
	@echo "Signed → $(APP_BUILD), $(CLI_BUILD)"

package: sign
	mkdir -p $(DIST)
	bash packaging/macos/make-dmg.sh \
		"$(APP_BUILD)" \
		"$(CLI_BUILD)" \
		"$(VERSION)" \
		"$(DMG)"

notarize: package
	@set -eu; \
	trap 'st=$$?; if [ $$st -ne 0 ]; then \
		printf "\n\033[1;31m✗ NOTARIZATION FAILED\033[0m — removing %s so a broken build can never be shipped.\n" "$(DMG)"; \
		rm -f "$(DMG)"; \
	fi; exit $$st' EXIT; \
	echo "→ Submitting $(DMG) to Apple notary service..."; \
	out=$$(xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait 2>&1); \
	echo "$$out"; \
	echo "$$out" | grep -q "status: Accepted" \
		|| { echo "Notary service did not return status: Accepted."; exit 1; }; \
	xcrun stapler staple "$(DMG)"; \
	$(MAKE) --no-print-directory verify-dmg
	@printf "\033[1;32m✓ Notarized + verified\033[0m → $(DMG)\n"

# Counter-check: a built DMG is only valid if Gatekeeper accepts the app inside
# as notarized AND the ticket is stapled. Fails loudly otherwise.
verify-dmg:
	@set -eu; \
	[ -f "$(DMG)" ] || { echo "✗ $(DMG) does not exist."; exit 1; }; \
	echo "→ Verifying $(DMG)..."; \
	xcrun stapler validate "$(DMG)"; \
	mnt=$$(hdiutil attach "$(DMG)" -nobrowse -noautoopen -readonly \
		| sed -n 's|.*\(/Volumes/.*\)|\1|p' | head -1); \
	trap 'hdiutil detach "$$mnt" -quiet 2>/dev/null || true' EXIT; \
	assess=$$(spctl -a -t exec -vv "$$mnt/$(APP)" 2>&1); echo "$$assess"; \
	echo "$$assess" | grep -q "source=Notarized Developer ID" \
		|| { echo "✗ App is signed but NOT notarized."; exit 1; }; \
	codesign --verify --deep --strict --verbose=2 "$$mnt/$(APP)"; \
	printf "\033[1;32m✓ DMG verified\033[0m: stapled, notarized, Gatekeeper-approved.\n"

icon:
	python3 scripts/make_icon.py
	iconutil -c icns $(NAME).iconset \
	    -o app-template/Contents/Resources/AppIcon.icns
	mkdir -p var/build/icon-assets
	xcrun actool \
	    --compile var/build/icon-assets \
	    --platform macosx \
	    --minimum-deployment-target 15.3 \
	    --app-icon AppIcon \
	    --output-partial-info-plist var/build/icon-assets/partial-info.plist \
	    --skip-app-store-deployment \
	    $(NAME).xcassets 2>/dev/null
	cp var/build/icon-assets/Assets.car \
	    app-template/Contents/Resources/Assets.car
	@echo "Icon generated: AppIcon.icns + Assets.car"
