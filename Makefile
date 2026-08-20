APP        := AudioPriorityBar
BUNDLE     := dist/$(APP).app
BINARY     := $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES    := $(shell find $(APP) -name '*.swift')
PLIST      := $(APP)/Info.plist
ICONSET    := $(APP)/Assets.xcassets/AppIcon.appiconset
ICNS       := build/AppIcon.icns

BUNDLE_ID  := app.audioprioritybar
DEPLOY     := 13.0
ARCHS      := arm64 x86_64
SLICES     := $(foreach a,$(ARCHS),build/$(APP)-$(a))

SWIFTFLAGS := -O -swift-version 5 -module-cache-path build/ModuleCache

all: $(BUNDLE)

# One slice per architecture, lipo'd into a universal binary below.
build/$(APP)-%: $(SOURCES)
	@mkdir -p build
	swiftc $(SWIFTFLAGS) -target $*-apple-macos$(DEPLOY) $(SOURCES) -o $@

# The appiconset carries extra sizes (64x64, 1024x1024) that iconutil rejects,
# so copy only the names Contents.json actually declares.
$(ICNS): $(wildcard $(ICONSET)/*.png) $(ICONSET)/Contents.json
	@rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	@for f in $$(sed -n 's/.*"filename" : "\(.*\)".*/\1/p' $(ICONSET)/Contents.json); do \
	  cp $(ICONSET)/$$f build/AppIcon.iconset/$$f; \
	done
	iconutil -c icns build/AppIcon.iconset -o $@

$(BUNDLE): $(SLICES) $(ICNS) $(PLIST)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	lipo -create $(SLICES) -output $(BINARY)
	cp $(ICNS) $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp $(PLIST) $(BUNDLE)/Contents/Info.plist
	@# Info.plist is written for Xcode, which expands these at build time.
	/usr/libexec/PlistBuddy \
	  -c 'Set :CFBundleIdentifier $(BUNDLE_ID)' \
	  -c 'Set :CFBundleExecutable $(APP)' \
	  -c 'Set :LSMinimumSystemVersion $(DEPLOY)' \
	  -c 'Add :CFBundleIconFile string AppIcon' \
	  $(BUNDLE)/Contents/Info.plist
	codesign --force --options runtime --sign - $(BUNDLE)
	@echo "Build complete: $(BUNDLE)"

run: all
	open $(BUNDLE)

install: all
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	@echo "Installed to /Applications/$(APP).app"

# Rebuild, swap the installed app, and relaunch. Preferences and login-item
# registration are preserved.
reinstall: all
	-pkill -x $(APP)
	$(MAKE) install
	open /Applications/$(APP).app

uninstall:
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	-defaults delete $(BUNDLE_ID)

clean:
	rm -rf build dist

.PHONY: all run install reinstall uninstall clean
