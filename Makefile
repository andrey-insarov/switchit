APP      = Switchit
VERSION ?= $(shell cat VERSION)
BUILD_NO ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
GIT_SHA  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
PLIST_SUBST = -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD_NO)/' -e 's/__SHA__/$(GIT_SHA)/' -e 's/__DATE__/$(BUILD_DATE)/'
# Universal (arm64 + x86_64) for distribution builds; single-arch for quick ad-hoc builds.
UNIVERSAL ?= $(if $(filter -,$(SIGN_ID)),0,1)
ifeq ($(UNIVERSAL),1)
ARCH_FLAGS = --arch arm64 --arch x86_64
else
ARCH_FLAGS =
endif
BUILD    = $(shell swift build -c release $(ARCH_FLAGS) --show-bin-path 2>/dev/null)
BUNDLE   = $(APP).app
CONTENTS = $(BUNDLE)/Contents
# Ad-hoc signature by default. For distribution: SIGN_ID="Developer ID Application: Name (TEAMID)"
# adds hardened runtime + timestamp (stage 5 brings the entitlements, profile and notarization).
SIGN_ID ?= -
ifeq ($(SIGN_ID),-)
SIGN_FLAGS =
else
SIGN_FLAGS = --options runtime --timestamp
endif

.PHONY: build test app run install clean

build:
	swift build -c release $(ARCH_FLAGS)

test:
	swift test

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BUILD)/$(APP) $(CONTENTS)/MacOS/$(APP)
	sed $(PLIST_SUBST) Resources/Info.plist > $(CONTENTS)/Info.plist
	echo -n 'APPL????' > $(CONTENTS)/PkgInfo
	xattr -cr $(BUNDLE)
	codesign --force $(if $(filter -,$(SIGN_ID)),--deep,) $(SIGN_FLAGS) --sign "$(SIGN_ID)" $(BUNDLE)
	codesign --verify --strict --deep --verbose=2 $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: app
	open $(BUNDLE)

install: app
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	@echo "Installed to /Applications/$(BUNDLE)"

clean:
	rm -rf .build $(BUNDLE) $(APP)-*.zip $(APP)-*.dmg
