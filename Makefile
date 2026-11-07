# Single entry point for local and CI builds. See README.md.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

APP_NAME := Tannlaus
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
SWIFT_FLAGS := -c release --arch arm64
ENTITLEMENTS := Resources/Tannlaus.entitlements

# The newest released version in CHANGELOG.md (0.0.0 if none); check-version reports malformed headings.
VERSION := $(shell scripts/version.sh CHANGELOG.md 2>/dev/null || echo invalid)
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
ZIP := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).zip
DMG := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg
CHECKSUMS := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).sha256

# "-" signs ad hoc for local use. Release builds pass a Developer ID identity.
CODESIGN_IDENTITY ?= -
TIMESTAMP := $(if $(filter -,$(CODESIGN_IDENTITY)),,--timestamp)

# notarytool reads the App Store Connect API key from the environment.
NOTARIZE := xcrun notarytool submit --key "$${ASC_API_KEY_PATH:?}" --key-id "$${ASC_API_KEY_ID:?}" --issuer "$${ASC_API_ISSUER_ID:?}" --wait

.PHONY: build test app version check-version clean notarize-app verify-app zip dmg notarize-dmg verify-dmg checksums release-notes

build: check-version
	swift build $(SWIFT_FLAGS)

test:
	swift test
	scripts/test-scripts.sh

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build $(SWIFT_FLAGS) --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/
	sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD_NUMBER)/' Resources/Info.plist > $(APP)/Contents/Info.plist
	plutil -lint -s $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns Resources/MenuBarIcon*.png $(APP)/Contents/Resources/
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(TIMESTAMP) --options runtime --entitlements $(ENTITLEMENTS) $(APP)
	codesign --verify --strict --verbose=1 $(APP)
	@echo "Built $(APP) $(VERSION) ($(BUILD_NUMBER))"

version: check-version
	@echo $(VERSION)

check-version:
	@scripts/version.sh CHANGELOG.md > /dev/null

clean:
	rm -rf .build $(BUILD_DIR)

# Release targets, used by .github/workflows/release.yml.

notarize-app:
	ditto -c -k --keepParent $(APP) $(BUILD_DIR)/notarize.zip
	$(NOTARIZE) $(BUILD_DIR)/notarize.zip
	rm $(BUILD_DIR)/notarize.zip
	xcrun stapler staple $(APP)

verify-app:
	spctl --assess --type execute --verbose $(APP)

zip: check-version
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)

dmg: check-version
	rm -rf $(BUILD_DIR)/dmg $(DMG)
	mkdir -p $(BUILD_DIR)/dmg
	ditto $(APP) $(BUILD_DIR)/dmg/$(APP_NAME).app
	ln -s /Applications $(BUILD_DIR)/dmg/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder $(BUILD_DIR)/dmg -ov -format UDZO $(DMG)
	rm -rf $(BUILD_DIR)/dmg
	codesign --force --sign "$(CODESIGN_IDENTITY)" $(TIMESTAMP) $(DMG)

notarize-dmg:
	$(NOTARIZE) $(DMG)
	xcrun stapler staple $(DMG)

verify-dmg:
	spctl --assess --type open --context context:primary-signature --verbose $(DMG)

checksums:
	cd $(BUILD_DIR) && shasum -a 256 $(notdir $(ZIP)) $(notdir $(DMG)) > $(notdir $(CHECKSUMS))

release-notes: check-version
	@scripts/changelog-section.sh $(VERSION) CHANGELOG.md
