PROJECT := clippy.xcodeproj
SCHEME := Clippy macOS
CONFIGURATION := Debug
DESTINATION := platform=macOS,arch=arm64
DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData/clippy-make
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Clippy.app

.PHONY: help build run clean open project list convert-agent

help:
	@echo "Targets:"
	@echo "  make build   - Build the app"
	@echo "  make run     - Build and launch the app"
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
	open "$(APP)"

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

list:
	xcodebuild -project "$(PROJECT)" -list

convert-agent:
	@if [ -z "$(AGENT_PATH)" ] || [ -z "$(NEW_NAME)" ]; then \
		echo "Usage: make convert-agent AGENT_PATH=/path/to/decompiled-agent NEW_NAME=clippy"; \
		exit 1; \
	fi
	./scripts/agent-convert.sh "$(AGENT_PATH)" "$(NEW_NAME)"
