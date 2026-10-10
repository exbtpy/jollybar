# Product names live in macos/identity.env. AppIdentity.swift must match.
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
IDENTITY := $(ROOT)/macos/identity.env

APP_PRODUCT_NAME := $(shell bash -c 'source "$(IDENTITY)" && printf %s "$$APP_PRODUCT_NAME"')
APP_DISPLAY_NAME := $(shell bash -c 'source "$(IDENTITY)" && printf %s "$$APP_DISPLAY_NAME"')
APP_BUNDLE_ID := $(shell bash -c 'source "$(IDENTITY)" && printf %s "$$APP_BUNDLE_ID"')
APP_EXECUTABLE_NAME := $(shell bash -c 'source "$(IDENTITY)" && printf %s "$$APP_EXECUTABLE_NAME"')
DMG_NAME := $(shell bash -c 'source "$(IDENTITY)" && printf %s "$$DMG_NAME"')
CONFIG_DIR_NAME := $(shell bash -c 'source "$(IDENTITY)" && printf %s "$$CONFIG_DIR_NAME"')

.PHONY: build app zip dmg release-artifacts verify-release install clean print-identity icon

print-identity:
	@echo "APP_PRODUCT_NAME=$(APP_PRODUCT_NAME)"
	@echo "APP_DISPLAY_NAME=$(APP_DISPLAY_NAME)"
	@echo "APP_BUNDLE_ID=$(APP_BUNDLE_ID)"
	@echo "APP_EXECUTABLE_NAME=$(APP_EXECUTABLE_NAME)"
	@echo "DMG_NAME=$(DMG_NAME)"
	@echo "CONFIG_DIR_NAME=$(CONFIG_DIR_NAME)"

# Regenerates AppIcon.icns, the asset catalog, and docs/images from design/logo.
# Requires cairosvg. make app uses the committed icons and does not run this.
icon:
	python3 design/logo/render_icon.py

build:
	cd macos && swift build -c release

app:
	bash macos/scripts/build.sh

zip:
	bash macos/scripts/build.sh --zip
	bash macos/scripts/verify-release.sh macos/$(APP_PRODUCT_NAME).zip

dmg:
	bash macos/scripts/build.sh --dmg
	bash macos/scripts/verify-release.sh macos/$(DMG_NAME).dmg

release-artifacts:
	UNIVERSAL=1 bash macos/scripts/build.sh --zip --dmg
	EXPECT_UNIVERSAL=1 bash macos/scripts/verify-release.sh macos/$(APP_PRODUCT_NAME).zip
	EXPECT_UNIVERSAL=1 bash macos/scripts/verify-release.sh macos/$(DMG_NAME).dmg

verify-release:
	bash macos/scripts/verify-release.sh macos/$(APP_PRODUCT_NAME).zip
	if [ -f macos/$(DMG_NAME).dmg ]; then bash macos/scripts/verify-release.sh macos/$(DMG_NAME).dmg; fi

install: app
	rm -rf "/Applications/$(APP_PRODUCT_NAME).app"
	cp -R "macos/$(APP_PRODUCT_NAME).app" /Applications/

clean:
	cd macos && swift package clean
	rm -rf "macos/$(APP_PRODUCT_NAME).app" "macos/$(APP_PRODUCT_NAME).zip" "macos/$(DMG_NAME).dmg"
