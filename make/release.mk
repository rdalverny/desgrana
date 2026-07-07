
# ── Tag & push ───────────────────────────────────────────────────────
tag:
	@TAG=v$(VERSION); \
	 git diff --quiet && git diff --cached --quiet \
	   || { echo "Uncommitted changes — aborting."; exit 1; }; \
	 git fetch --quiet origin; \
	 git diff --quiet HEAD origin/main \
	   || { echo "main is not in sync with origin/main — push or pull first."; exit 1; }; \
	 git rev-parse "$$TAG" >/dev/null 2>&1 \
	   && { echo "Tag $$TAG already exists."; exit 1; } || true; \
	 git tag "$$TAG"; \
	 git push origin main "$$TAG"; \
	 open "https://github.com/$(GITHUB_REPO)/actions"; \
	 echo "Tagged and pushed $$TAG — opening Actions."

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


fetch-artifacts:
	mkdir -p dist
	RUN_ID=$$(gh run list --repo $(GITHUB_REPO) \
		--workflow build.yml --status success \
		--limit 1 --json databaseId -q '.[0].databaseId'); \
	echo "Fetching from run $$RUN_ID…"; \
	gh run download $$RUN_ID --repo $(GITHUB_REPO) \
		--pattern "desgrana-*-linux-*" \
		--pattern "desgrana-*-windows-setup" \
		--dir dist/.tmp
	find dist/.tmp -type f \( \( -name "*.deb" ! -name "*dbgsym*" \) -o -name "*.rpm" -o -name "*-setup.exe" \) \
		-exec mv {} dist/ \;
	rm -rf dist/.tmp
	@echo "CI artifacts → $(DIST)"
	@ls -lh $(DIST)

update-cask:
	bash packaging/macos/update-cask.sh \
		"$(VERSION)" \
		"$(DIST)/Desgrana-$(VERSION).dmg"

# update-cask
shasums: #fetch-artifacts
	cd $(DIST) && shasum -a 256 *.dmg *.deb *.rpm *.exe 2>/dev/null > SHA256SUMS
	@echo "SHA256SUMS → $(DIST)/SHA256SUMS"

release: shasums verify-dmg
	gh release create "v$(VERSION)" \
		--draft \
		$(DIST)/Desgrana-$(VERSION).dmg \
		$(DIST)/*.deb \
		$(DIST)/*.rpm \
		$(DIST)/*-setup.exe \
		$(DIST)/SHA256SUMS \
		--title "Desgrana $(VERSION)" \
		--notes-file CHANGELOG.md

# ── Windows testing pre-release ──────────────────────────────────────────────
# Publish the experimental Windows installer for testers. Flow:
#   git tag v$(VERSION)-$(PRERELEASE) && git push origin v$(VERSION)-$(PRERELEASE)
#   # wait for the CI build to finish, then:
#   make prerelease
# Creates a DRAFT pre-release (review the notes / fix the issue link, then
# publish from the GitHub UI). VERSION stays clean; the tag carries the suffix.
# Override the suffix with e.g. PRERELEASE=beta2 or PRERELEASE=rc1.
PRERELEASE       ?= beta
PRERELEASE_NOTES ?= packaging/win/prerelease-notes.md

prerelease: fetch-artifacts
	gh release create "v$(VERSION)-$(PRERELEASE)" \
		--draft \
		--prerelease \
		--title "Desgrana $(VERSION)-$(PRERELEASE)" \
		--notes-file $(PRERELEASE_NOTES) \
		$(DIST)/*-setup.exe

shipit: release
	# sed -i '' \
	# 	-e 's|href="[^"]*Desgrana-[0-9.]*\.dmg"|href="$(GITHUB_BASE)/v$(VERSION)/Desgrana-$(VERSION).dmg"|' \
	# 	-e 's|Download Desgrana [0-9.]* ([^)]*)|Download Desgrana $(VERSION) ($(DATE))|' \
	# 	web/index.html
	# @echo "web/index.html → $(VERSION) ($(DATE))"

	python3 -c "import json; f='web/version.json'; d=json.load(open(f)); d['version']='$(VERSION)'; d['url']='https://github.com/$(GITHUB_REPO)/releases/tag/v$(VERSION)'; json.dump(d, open(f,'w'), indent=2); open(f,'a').write('\n')"
	@echo "web/version.json → $(VERSION)"

	@echo "dist/ contains: $$(ls $(DIST))"


# Requires network. Tests the live version endpoint: shape, reachability,
# and numeric comparison against an old, equal, and future version.
test-update-check:
	python3 desgrana/Tests/test_update_check.py


# ── Web ──────────────────────────────────────────────────────────
# Build the deployable site into web/dist/ (gitignored) from web/template.html.j2
# + web/i18n/*.toml: en -> web/dist/index.html, fr -> web/dist/fr/index.html, plus
# a copy of every asset (demo.mp4, poster, version.json, icon…). Deploy = upload
# web/dist/. Update version/dates in web/i18n/common.toml on each release.
web:
	uv run scripts/build_web.py


FADE := 0.4

web/demo.mp4: web/demo.mov
	@dur=$$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $<); \
	st_out=$$(awk "BEGIN{print $$dur - $(FADE)}"); \
	ffmpeg -i $< \
		-vf "scale=trunc(iw/4)*2:trunc(ih/4)*2,fade=t=in:st=0:d=$(FADE):color=fafaf8,fade=t=out:st=$$st_out:d=$(FADE):color=fafaf8" \
		-c:v libx264 \
		-crf 22 \
		-pix_fmt yuv420p \
		-movflags +faststart \
		$@

web/demo.jpg: web/demo.mp4
	ffmpeg -ss 6.0 -i $< -frames:v 1 -q:v 2 $@
