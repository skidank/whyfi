APP      := build/WhyFi.app
# First Apple Development identity in the keychain, else ad-hoc ("-"). Override with `make IDENTITY="..."`.
# A real identity keeps macOS from re-asking for Location access after every rebuild.
IDENTITY ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}'),-)
BIN      := $(shell swift build -c release --show-bin-path)

.PHONY: build run test clean icon
build:
	swift build -c release
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN)/WhyFiApp $(APP)/Contents/MacOS/WhyFi
	cp Support/Info.plist $(APP)/Contents/Info.plist
	cp Support/AppIcon.icns $(APP)/Contents/Resources/
	cp -R $(BIN)/WhyFi_WhyFiApp.bundle $(APP)/Contents/Resources/
	codesign --force --sign "$(IDENTITY)" --identifier com.skidank.WhyFi $(APP)

run: build
	open $(APP)

test:
	swift test

clean:
	rm -rf build .build

# Regenerate Support/AppIcon.icns (committed) from Support/Icon/make-icon.swift.
icon:
	rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	for s in 16 32 128 256 512; do \
		swift Support/Icon/make-icon.swift build/AppIcon.iconset/icon_$${s}x$${s}.png $$s; \
		swift Support/Icon/make-icon.swift build/AppIcon.iconset/icon_$${s}x$${s}@2x.png $$((s * 2)); \
	done
	iconutil -c icns build/AppIcon.iconset -o Support/AppIcon.icns
