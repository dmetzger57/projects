# projkit — common tasks. Run `make` (or `make help`) for the list.
#
# Device and simulator IDs can be overridden on the command line, e.g.
#   make install-iphone IPHONE=<udid>      make sim SIM="iPad Air 11-inch (M4)"

SHELL := /bin/bash
.DEFAULT_GOAL := help

VENV      := .venv
PY        := $(VENV)/bin/python
PROJ      := $(VENV)/bin/proj
IOS       := ios
XCPROJ    := $(IOS)/Proj.xcodeproj
BUNDLE_ID := com.dmetzger57.proj
BUILD     := $(IOS)/build
DEV_DD    := $(BUILD)/dev
SIM_DD    := $(BUILD)/sim
DEV_APP   := $(DEV_DD)/Build/Products/Debug-iphoneos/Proj.app
SIM_APP   := $(SIM_DD)/Build/Products/Debug-iphonesimulator/Proj.app

IPHONE    ?= 00008160-00064D8426E00036
IPAD      ?= 00008027-000971262178402E
SIM       ?= iPad Pro 13-inch (M5)
SIM_DATA  := $(BUILD)/simdata
TAB       ?=
PROJECT   ?=

AGENT     := gui/$(shell id -u)/com.dmetzger57.proj-serve
WEB_URL   := http://127.0.0.1:8765/

.PHONY: help setup test checks crosscheck check lint serve restart-web web-log xcodeproj \
        build-sim sim screenshot install install-iphone install-ipad signing-probe release clean

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- Python (CLI and web UI) -------------------------------------------------

setup: ## Create .venv and install projkit with dev extras
	test -d $(VENV) || python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -e '.[dev]'

test: ## Python tests
	$(PY) -m pytest -q

lint: ## proj lint on your real projects folder (read-only)
	$(PROJ) lint

serve: ## Run the web UI in the foreground (stop the launchd one first: it uses the same port)
	$(PROJ) serve

restart-web: ## Restart the launchd web UI and check it answers
	launchctl kickstart -k $(AGENT)
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
	  code=$$(curl -s -o /dev/null -w '%{http_code}' $(WEB_URL)); \
	  [ "$$code" = 200 ] && { echo "web UI up: $(WEB_URL)"; exit 0; }; sleep 0.5; \
	done; echo "web UI did not answer; see: make web-log" >&2; exit 1

web-log: ## Last lines of the web UI log
	tail -n 40 ~/Library/Logs/proj-serve.log

# ---- Swift core --------------------------------------------------------------

checks: ## Swift core checks (no Xcode needed)
	cd $(IOS)/ProjKit && swift run -q Checks 2> >(grep -v NSFileSandboxingRequestRelatedItemExtension >&2) | tail -1

crosscheck: ## Swift edits a temp copy of your projects; Python verifies it
	sh $(IOS)/crosscheck.sh

check: test checks crosscheck ## Everything: Python tests, Swift checks, cross-check

# ---- iPhone / iPad app -------------------------------------------------------

xcodeproj: ## Regenerate Proj.xcodeproj (only needed to change build settings)
	python3 $(IOS)/make_xcodeproj.py

build-sim: ## Build the app for the simulator
	xcodebuild -project $(XCPROJ) -scheme Proj -configuration Debug \
	  -destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(SIM_DD) \
	  CODE_SIGNING_ALLOWED=NO -quiet build

sim: build-sim ## Run in the simulator on a COPY of your projects (TAB=projects PROJECT="name" optional)
	@udid=$$(xcrun simctl list devices available | grep -F "$(SIM) (" | head -1 | grep -oE '[0-9A-F-]{36}'); \
	[ -n "$$udid" ] || { echo "No simulator named '$(SIM)'" >&2; exit 1; }; \
	rm -rf $(SIM_DATA) && mkdir -p $(SIM_DATA) && ditto "$${PROJ_ROOT:-$$HOME/Documents/Projects}" $(SIM_DATA)/Projects; \
	xcrun simctl boot $$udid 2>/dev/null; xcrun simctl bootstatus $$udid -b >/dev/null; open -a Simulator; \
	xcrun simctl install $$udid $(SIM_APP); \
	SIMCTL_CHILD_PROJ_DEBUG_ROOT="$(abspath $(SIM_DATA))/Projects" \
	SIMCTL_CHILD_PROJ_DEBUG_TAB="$(TAB)" SIMCTL_CHILD_PROJ_DEBUG_OPEN="$(PROJECT)" \
	  xcrun simctl launch --terminate-running-process $$udid $(BUNDLE_ID) >/dev/null; \
	echo "running on $(SIM) with a copy of your projects in $(SIM_DATA)"

screenshot: sim ## `make sim`, then save a screenshot to ios/build/screenshot.png
	@sleep 4; udid=$$(xcrun simctl list devices available | grep -F "$(SIM) (" | head -1 | grep -oE '[0-9A-F-]{36}'); \
	xcrun simctl io $$udid screenshot $(BUILD)/screenshot.png >/dev/null 2>&1 && echo "saved $(BUILD)/screenshot.png"

signing-probe: ## Check codesign can use your key without a keychain prompt
	@id=$$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $$2; exit}'); \
	[ -n "$$id" ] || { echo "No 'Apple Development' signing identity found." >&2; exit 1; }; \
	tmp=$$(mktemp -d); cp /usr/bin/true $$tmp/probe; \
	if timeout 15 codesign --force --sign "$$id" --timestamp=none $$tmp/probe 2>/dev/null; then rm -rf $$tmp; \
	else rm -rf $$tmp; \
	  echo "codesign can't use your key. In a separate Terminal window run:" >&2; \
	  echo "  security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2; exit 1; fi

# install-device UDID NAME: clean build (a half-signed leftover breaks the signature), verify, install, launch
define install-device
	@xcrun devicectl list devices 2>/dev/null | grep -F "$(1)" | grep -q available || \
	  { echo "$(2) is not available: connect it, unlock it, and turn on Developer Mode." >&2; exit 1; }
	rm -rf $(DEV_APP)
	xcodebuild -project $(XCPROJ) -scheme Proj -configuration Debug -destination 'id=$(1)' \
	  -derivedDataPath $(DEV_DD) -allowProvisioningUpdates -quiet build
	codesign -v $(DEV_APP)
	xcrun devicectl device install app --device $(1) $(DEV_APP) | grep -E 'installed|rror' || true
	@xcrun devicectl device process launch --terminate-existing --device $(1) $(BUNDLE_ID) 2>&1 \
	  | grep -qi 'launched' && echo "$(2): installed and launched" || \
	  echo "$(2): installed; open Proj on it (it was locked, or the developer isn't trusted yet: Settings › General › VPN & Device Management)"
endef

install-iphone: signing-probe ## Build, install and launch on the iPhone
	$(call install-device,$(IPHONE),iPhone)

install-ipad: signing-probe ## Build, install and launch on the iPad
	$(call install-device,$(IPAD),iPad)

install: ## Install on every connected device (iPhone, iPad)
	@ok=0; for t in install-iphone install-ipad; do $(MAKE) --no-print-directory $$t && ok=1; done; [ $$ok = 1 ]

release: ## Checks, archive and upload to TestFlight (paid team only; see ios/README.md)
	sh $(IOS)/release.sh

# ---- housekeeping ------------------------------------------------------------

clean: ## Remove iOS build output and the simulator data copy
	rm -rf $(BUILD) $(IOS)/ProjKit/.build
