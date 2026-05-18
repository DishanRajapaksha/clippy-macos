PROJECT := clippy.xcodeproj
SCHEME := Clippy macOS
CONFIGURATION := Debug
DESTINATION := platform=macOS,arch=arm64
DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData/clippy-make
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Clippy.app
PACKAGE_APP := $(DERIVED_DATA)/Build/Products/Release/Clippy.app
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo local)
DIST_DIR := dist
ZIP := $(DIST_DIR)/Clippy-macOS-$(VERSION).zip

.PHONY: help build run package clean open project list convert-agent

help:
	@echo "Targets:"
	@echo "  make build   - Build the app"
	@echo "  make run     - Build and launch the app"
	@echo "  make package - Build a Release zip in dist/"
	@echo "  make clean   - Clean build artifacts"
	@echo "  make open    - Open the Xcode project"
	@echo "  make project - Print project settings"
	@echo "  make list    - List project targets/schemes"
	@echo "  make convert-agent AGENT_PATH=... NEW_NAME=... - Convert decompiled agent files"

build:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination '$(DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		build

run: build
	-pkill -f "$(APP)/Contents/MacOS/Clippy" || true
	sleep 0.4
	open "$(APP)" || (sleep 0.6 && open "$(APP)")

package:
	$(MAKE) build CONFIGURATION=Release
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)"
	ditto -c -k --norsrc --keepParent "$(PACKAGE_APP)" "$(ZIP)"
	shasum -a 256 "$(ZIP)" > "$(ZIP).sha256"
	@echo "Packaged $(ZIP)"

clean:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		clean

open:
	open "$(PROJECT)"

project:
	@echo "PROJECT=$(PROJECT)"
	@echo "SCHEME=$(SCHEME)"
	@echo "CONFIGURATION=$(CONFIGURATION)"
	@echo "DESTINATION=$(DESTINATION)"
	@echo "DERIVED_DATA=$(DERIVED_DATA)"
	@echo "APP=$(APP)"
	@echo "PACKAGE_APP=$(PACKAGE_APP)"

list:
	xcodebuild -project "$(PROJECT)" -list

convert-agent:
	@if [ -z "$(AGENT_PATH)" ] || [ -z "$(NEW_NAME)" ]; then \
		echo "Usage: make convert-agent AGENT_PATH=/path/to/decompiled-agent NEW_NAME=clippy"; \
		exit 1; \
	fi
	./scripts/agent-convert.sh "$(AGENT_PATH)" "$(NEW_NAME)"
