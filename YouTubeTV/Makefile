# Makefile for building, running and deploying YouTube TV.
# Ported from the hand-warmer repo's iOS targets, retargeted at tvOS.
#
# Everything runs from this directory (YouTubeTV/), which is where the Xcode
# project, the lint configs and the sources live.
#
# Config knobs — override on the command line, e.g.
#   make run TV_SIMULATOR="Apple TV B"
#   make deploy TV_DEVICE=<name-or-udid>

.PHONY: help generate build run test deploy screenshot remote \
	testflight testflight-validate archive \
	format lint check clean

SCHEME        = YouTubeTV
# Built product name (<APP_NAME>.app). Keep it in sync with SCHEME's target
# PRODUCT_NAME if you override the scheme.
APP_NAME      = YouTubeTV
BUNDLE_ID     = dk.delectosoft.metube
PROJECT       = YouTubeTV.xcodeproj
TV_SIMULATOR ?= Apple TV A
# Concrete simulator destination, used where something has to actually run
# (run, test). `build` uses a generic one instead, so a plain compile never
# depends on which Apple TV simulator is installed.
TV_DESTINATION ?= platform=tvOS Simulator,name=$(TV_SIMULATOR)
DERIVED        = build
DERIVED_DEVICE = build-device

# The Apple Developer team used for device signing comes from
# DEVELOPMENT_TEAM in Config/Secrets.xcconfig (gitignored) — see README.

# Prettifier for xcodebuild output. Optional: `brew install xcbeautify` to get
# readable logs; without it the raw xcodebuild output passes straight through.
BEAUTIFY := $(shell command -v xcbeautify >/dev/null 2>&1 && echo xcbeautify || echo cat)

help:
	@echo "Targets:"
	@echo "  generate    Regenerate YouTubeTV.xcodeproj from project.yml"
	@echo "  build       Compile for the tvOS simulator (no signing, no device needed)"
	@echo "  run         Build, install and launch on the Apple TV simulator"
	@echo "  test        Run the UI tests on the Apple TV simulator"
	@echo "  deploy      Build, install and launch on a paired Apple TV"
	@echo "  testflight  Archive and upload to TestFlight (see README)"
	@echo "  screenshot  Capture the target simulator (OUT=<path> to choose the file)"
	@echo "  remote      Drive the simulator remote, e.g. make remote ARGS='right 2 --shot'"
	@echo "  format      Reformat Swift sources in place with swift-format"
	@echo "  lint        SwiftLint --strict"
	@echo "  check       What CI gates on: SwiftLint + swift-format lint"
	@echo "  clean       Remove build/ and build-device/"

# Regenerate the (gitignored) Xcode project from project.yml.
# Requires `brew install xcodegen`.
generate:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "xcodegen not found. Install it with: brew install xcodegen"; exit 1; }
	@test -f Config/Secrets.xcconfig || { \
		echo "Config/Secrets.xcconfig missing — see the Setup section of README.md."; exit 1; }
	xcodegen generate

# Compile for the simulator without running anything. A generic destination
# needs no bootable device, and CODE_SIGNING_ALLOWED=NO needs no developer
# account — this is exactly what CI does. Don't use it to produce something to
# install: that flag strips the entitlements the Top Shelf extension needs (see
# README), which is why `run` builds separately.
build: generate
	set -o pipefail; xcodebuild build -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination 'generic/platform=tvOS Simulator' -derivedDataPath "$(DERIVED)" \
		CODE_SIGNING_ALLOWED=NO | $(BEAUTIFY)

# Build, install and launch on the Apple TV simulator. Boots the target
# simulator and opens Simulator.app if it isn't already running.
# Pass ARGS to forward launch arguments.
run: generate
	xcrun simctl boot "$(TV_SIMULATOR)" 2>/dev/null || true
	open -a Simulator
	set -o pipefail; xcodebuild build -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination '$(TV_DESTINATION)' -derivedDataPath "$(DERIVED)" | $(BEAUTIFY)
	@# By name, not `booted`: with a second simulator up — an Apple TV A left running
	@# beside the B this was asked for — `booted` is ambiguous, and simctl picks one of
	@# them. That installs the build onto a simulator nobody is looking at, which reads
	@# as the change simply not being there.
	xcrun simctl install "$(TV_SIMULATOR)" "$(DERIVED)/Build/Products/Debug-appletvsimulator/$(APP_NAME).app"
	xcrun simctl terminate "$(TV_SIMULATOR)" "$(BUNDLE_ID)" 2>/dev/null || true
	xcrun simctl launch "$(TV_SIMULATOR)" "$(BUNDLE_ID)" $(ARGS)

# Run the UI tests (UITests/, driven through XCUIRemote) on the simulator.
test: generate
	set -o pipefail; xcodebuild test -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination '$(TV_DESTINATION)' -derivedDataPath "$(DERIVED)" | $(BEAUTIFY)

# Build a Debug build, then install + launch on a paired Apple TV. The device is
# auto-detected; override with TV_DEVICE=<name-or-udid>. Pairing is a one-time
# step in Xcode — see the "Run on a real Apple TV" section of README.md.
# Signing needs DEVELOPMENT_TEAM in Config/Secrets.xcconfig.
deploy: generate
	@DEVICE="$(TV_DEVICE)"; \
	if [ -z "$$DEVICE" ]; then \
		DEVICE=$$(xcrun devicectl list devices 2>/dev/null | awk '/AppleTV/ { for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]/) { print $$i; exit } }'); \
	fi; \
	if [ -z "$$DEVICE" ]; then \
		echo "No Apple TV found. Pair one (README: Run on a real Apple TV), or pass TV_DEVICE=<name-or-udid>."; \
		exit 1; \
	fi; \
	echo "Deploying to device: $$DEVICE"; \
	set -o pipefail; xcodebuild build -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-sdk appletvos -destination "id=$$DEVICE" -derivedDataPath "$(DERIVED_DEVICE)" \
		-allowProvisioningUpdates | $(BEAUTIFY) && \
	xcrun devicectl device install app --device "$$DEVICE" \
		"$(DERIVED_DEVICE)/Build/Products/Debug-appletvos/$(APP_NAME).app" && \
	xcrun devicectl device process launch --device "$$DEVICE" "$(BUNDLE_ID)"

# Archive for the App Store and upload to TestFlight. Prefer this over `deploy`
# for anything you want to keep using: a development build stops launching when
# its provisioning profile expires, a TestFlight build lasts 90 days and is
# replaced by uploading again.
#
# One-time setup (App Store Connect API key + app record) is in README.md.
# The build number comes from the commit count; override with BUILD_NUMBER=<n>.
testflight:
	@./Scripts/testflight.sh

# Same pipeline, stopping at App Store Connect's validation — use it to check a
# change signs and passes the automated checks without burning a build number.
testflight-validate:
	@./Scripts/testflight.sh --validate

# Just produce the signed .ipa in build-archive/, without uploading it. Still
# needs the distribution signing assets, so run it after the one-time setup.
archive:
	@./Scripts/testflight.sh --archive

# Screenshot the target simulator (TV_SIMULATOR, as everything else here). tvOS
# has two displays and simctl picks the TVOut one on its own. Override the
# destination with OUT=<path>.
OUT ?= /tmp/youtubetv-screenshot.png
screenshot:
	xcrun simctl io "$(TV_SIMULATOR)" screenshot "$(OUT)"

# Drive the Siri Remote in the simulator — see Scripts/tvremote and the
# "Drive the simulator remote" section of README.md.
#   make remote ARGS="right 2 --shot"
remote:
	@test -n "$(ARGS)" || { echo "Usage: make remote ARGS=\"right 2 --shot\""; exit 1; }
	./Scripts/tvremote $(ARGS)

# Format Swift sources in place with Apple's swift-format (bundled with Xcode).
# Style comes from .swift-format in this directory.
format:
	@if xcrun --find swift-format >/dev/null 2>&1; then \
		xcrun swift-format format --in-place --recursive Sources UITests TopShelf; \
	else \
		echo "Skipping format (swift-format not found — needs macOS + Xcode)"; \
	fi

# SwiftLint owns the semantic rules (naming, complexity, line length); config is
# .swiftlint.yml. --strict promotes warnings to errors so nothing merges dirty.
lint:
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint not found. Install it with: brew install swiftlint"; exit 1; }
	swiftlint lint --quiet --strict

# Run SwiftLint (via the prerequisite above), then lint formatting without
# changing anything. This is what CI gates on.
check: lint
	@if xcrun --find swift-format >/dev/null 2>&1; then \
		xcrun swift-format lint --strict --recursive Sources UITests TopShelf; \
	else \
		echo "Skipping swift-format lint (not found — needs macOS + Xcode)"; \
	fi

clean:
	rm -rf "$(DERIVED)" "$(DERIVED_DEVICE)" build-archive
