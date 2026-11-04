# AntiClick - build, install and package.
#
# Menu-bar app (recommended)
#   make app              build build/AntiClick.app (universal: Apple silicon + Intel)
#   make install-app      copy it to /Applications and open it (replaces the agent)
#   make dmg              build build/AntiClick-<version>.dmg to give to other people
#   make notarize         notarize + staple the DMG (needs a Developer ID; see README)
#
# Command-line agent (no UI)
#   make                  build build/anticlick
#   make install          install it as a login agent (options: ARGS="--match CODEC")
#   make uninstall        remove the login agent
#   make status | list | log

VERSION    := 1.1.0
BUILD_NUM  ?= 2
BUILD      := build
CFLAGS     ?= -Os -Wall -Wextra -Wno-unused-parameter
DEFS       := -DAC_VERSION=\"$(VERSION)\"
FRAMEWORKS := -framework CoreAudio -framework CoreFoundation -framework IOKit
ENGINE     := src/engine.c src/engine.h

# command-line agent
NAME       := anticlick
LABEL      := io.github.kevinwells22.anticlick.agent
BIN        := $(BUILD)/$(NAME)
MINOS      ?= 14.0
ARCHS      ?= arm64
ARGS       ?=

# menu-bar app
# App bundles can't be code-signed on network volumes (SMB adds Finder
# metadata codesign rejects), so the app is assembled and signed in a local
# folder. The finished DMG is copied into ./build.
LOCAL_BUILD ?= $(HOME)/Library/Caches/AntiClick-build
APP_NAME   := AntiClick
APP        := $(LOCAL_BUILD)/$(APP_NAME).app
APP_TMP    := $(LOCAL_BUILD)/tmp
APP_MINOS  ?= 13.0
# Apple silicon only by default. "arm64 x86_64" builds a universal app, but
# the Intel half is untested (this Mac has no Rosetta to run it).
APP_ARCHS  ?= arm64
BUNDLE_ID  ?= io.github.kevinwells22.anticlick
PUBLISHER  ?= Kevin Wells
SIGN_ID    ?= -
NOTARY_PROFILE ?= AntiClick
DMG_NAME   := $(APP_NAME)-$(VERSION).dmg
DMG        := $(LOCAL_BUILD)/$(DMG_NAME)

# "-" means ad-hoc signing, which can't carry a secure timestamp.
SIGN_FLAGS := --force --options runtime --sign "$(SIGN_ID)" $(if $(filter -,$(SIGN_ID)),,--timestamp)

.PHONY: all app install-app dmg notarize install uninstall status list log experiments clean

all: $(BIN)

# ---------------------------------------------------------------- agent

$(BIN): src/anticlick.c $(ENGINE) Makefile
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(DEFS) $(foreach a,$(ARCHS),-arch $(a)) -mmacosx-version-min=$(MINOS) \
	    -o $@ src/anticlick.c src/engine.c $(FRAMEWORKS) -Wl,-dead_strip
	strip -x $@
	codesign --force --sign - --identifier $(LABEL) $@
	@stat -f "built %N (%z bytes)" $@

install: $(BIN)
	/bin/bash scripts/install.sh $(ARGS)

uninstall:
	/bin/bash scripts/uninstall.sh

status:
	/bin/bash scripts/status.sh

list: $(BIN)
	$(BIN) --list $(ARGS)

log:
	tail -n 40 -F "$(HOME)/Library/Logs/AntiClick.log"

# ---------------------------------------------------------------- app

app: $(APP)

$(APP): app/AntiClick.swift app/Info.plist app/make-icon.swift $(ENGINE) Makefile
	@rm -rf $@ $(APP_TMP) && mkdir -p $(APP_TMP) $@/Contents/MacOS $@/Contents/Resources
	@for arch in $(APP_ARCHS); do \
	    echo "compiling for $$arch"; \
	    $(CC) $(CFLAGS) $(DEFS) -arch $$arch -mmacosx-version-min=$(APP_MINOS) \
	        -c src/engine.c -o $(APP_TMP)/engine-$$arch.o || exit 1; \
	    swiftc -O -swift-version 5 -target $$arch-apple-macos$(APP_MINOS) \
	        -import-objc-header src/engine.h app/AntiClick.swift $(APP_TMP)/engine-$$arch.o \
	        $(FRAMEWORKS) -o $(APP_TMP)/$(APP_NAME)-$$arch || exit 1; \
	done
	lipo -create $(foreach a,$(APP_ARCHS),$(APP_TMP)/$(APP_NAME)-$(a)) -output $@/Contents/MacOS/$(APP_NAME)
	sed -e 's|@VERSION@|$(VERSION)|; s|@BUILD@|$(BUILD_NUM)|; s|@BUNDLE_ID@|$(BUNDLE_ID)|' \
	    -e 's|@MINOS@|$(APP_MINOS)|; s|@PUBLISHER@|$(PUBLISHER)|' app/Info.plist > $@/Contents/Info.plist
	plutil -lint -s $@/Contents/Info.plist
	swiftc -O app/make-icon.swift -o $(APP_TMP)/make-icon
	$(APP_TMP)/make-icon $(APP_TMP)/AppIcon.iconset
	iconutil -c icns $(APP_TMP)/AppIcon.iconset -o $@/Contents/Resources/AppIcon.icns
	xattr -cr $@
	codesign $(SIGN_FLAGS) $@
	codesign --verify --strict --deep $@
	@echo "built $@ ($$(du -sh $@ | cut -f1)), signed with: $(SIGN_ID)"

install-app: $(APP)
	@if launchctl print gui/$$(id -u)/$(LABEL) >/dev/null 2>&1; then \
	    echo "removing the command-line agent (the app replaces it)"; /bin/bash scripts/uninstall.sh; fi
	@pkill -x $(APP_NAME) && sleep 1 || true
	rm -rf /Applications/$(APP_NAME).app
	ditto --norsrc --noextattr --noacl $(APP) /Applications/$(APP_NAME).app
	codesign --verify --strict --deep /Applications/$(APP_NAME).app
	open /Applications/$(APP_NAME).app
	@echo "installed /Applications/$(APP_NAME).app"

dmg: $(APP)
	@set -e; stage=$$(mktemp -d); \
	ditto --norsrc --noextattr --noacl $(APP) "$$stage/$(APP_NAME).app"; \
	ln -s /Applications "$$stage/Applications"; \
	rm -f $(DMG); \
	hdiutil create -quiet -volname "$(APP_NAME)" -srcfolder "$$stage" -ov -format UDZO $(DMG); \
	rm -rf "$$stage"
	$(if $(filter -,$(SIGN_ID)),,codesign --force --sign "$(SIGN_ID)" --timestamp $(DMG))
	@mkdir -p $(BUILD) && cp $(DMG) $(BUILD)/$(DMG_NAME)
	@echo "built $(BUILD)/$(DMG_NAME) ($$(du -h $(DMG) | cut -f1))"

notarize: dmg
	@if [ "$(SIGN_ID)" = "-" ]; then \
	    echo 'notarizing needs a Developer ID: make notarize SIGN_ID="Developer ID Application: Name (TEAMID)"'; exit 1; fi
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature -v $(DMG)
	cp $(DMG) $(BUILD)/$(DMG_NAME)

# ---------------------------------------------------------------- misc

experiments:
	$(MAKE) -C experiments

clean:
	rm -rf $(BUILD)
	$(MAKE) -C experiments clean
