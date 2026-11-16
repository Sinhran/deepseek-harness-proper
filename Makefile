APP := DSH.app

all: $(APP)

.build/release/dsh: Package.swift $(shell find Sources -name '*.swift')
	swift build -c release

$(APP): .build/release/dsh Resources/Info.plist Resources/DSH.entitlements Resources/AppIcon.icns $(shell find Resources/AgentProfiles -name '*.patch.yml') LICENSE NOTICE THIRD_PARTY_NOTICES.md
	rm -rf $(APP)
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp .build/release/dsh "$(APP)/Contents/MacOS/dsh"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	rm -rf "$(APP)/Contents/Resources/AgentProfiles"
	cp -R Resources/AgentProfiles "$(APP)/Contents/Resources/AgentProfiles"
	# License notices travel with every built copy (MIT requires it for the
	# vendored DeepSeek Harness material compiled into the app).
	cp LICENSE NOTICE THIRD_PARTY_NOTICES.md "$(APP)/Contents/Resources/"
	codesign --force --options runtime --entitlements Resources/DSH.entitlements --sign - "$(APP)"
	@echo "Built $(APP):"
	@du -sh "$(APP)"

# The icon is a tracked artifact: regenerate it only on request
# (`make icon`). Depending on the debug binary made every source edit
# rebuild debug, launch the GUI, and rewrite this file on plain `make`.
icon:
	swift build
	rm -rf /tmp/dsh.iconset && mkdir -p /tmp/dsh.iconset
	.build/debug/dsh --render-icon /tmp/dsh-1024.png
	for s in 16 32 64 128 256 512; do sips -z $$s $$s /tmp/dsh-1024.png --out /tmp/dsh.iconset/icon_$${s}x$${s}.png >/dev/null; done
	sips -z 32 32 /tmp/dsh-1024.png --out /tmp/dsh.iconset/icon_16x16@2x.png >/dev/null
	sips -z 64 64 /tmp/dsh-1024.png --out /tmp/dsh.iconset/icon_32x32@2x.png >/dev/null
	sips -z 256 256 /tmp/dsh-1024.png --out /tmp/dsh.iconset/icon_128x128@2x.png >/dev/null
	sips -z 512 512 /tmp/dsh-1024.png --out /tmp/dsh.iconset/icon_256x256@2x.png >/dev/null
	cp /tmp/dsh-1024.png /tmp/dsh.iconset/icon_512x512@2x.png
	iconutil -c icns /tmp/dsh.iconset -o Resources/AppIcon.icns

.build/debug/dsh: Package.swift $(shell find Sources -name '*.swift')
	swift build

run: $(APP)
	open "$(APP)"

debug:
	swift build && .build/debug/dsh

# XCTest ships only with full Xcode. When xcode-select points at the
# CommandLineTools, borrow the first installed Xcode for the test run.
smoke:
	@dev="$$DEVELOPER_DIR"; \
	if [ -z "$$dev" ] && xcode-select -p | grep -q CommandLineTools; then \
		dev=$$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | head -1); \
		if [ -z "$$dev" ]; then echo "swift test needs full Xcode (XCTest); none found in /Applications" >&2; exit 1; fi; \
	fi; \
	if [ -n "$$dev" ]; then export DEVELOPER_DIR="$$dev"; fi; \
	swift test

clean:
	rm -rf .build $(APP)

.PHONY: all run debug smoke clean icon
