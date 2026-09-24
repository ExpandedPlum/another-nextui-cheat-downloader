PAK_NAME := $(shell jq -r .name pak.json)
PAK_TYPE := $(shell jq -r .type pak.json)
PAK_FOLDER := $(shell echo $(PAK_TYPE) | cut -c1)$(shell echo $(PAK_TYPE) | tr '[:upper:]' '[:lower:]' | cut -c2-)s

PUSH_SDCARD_PATH ?= /mnt/SDCARD
PUSH_PLATFORM ?= tg5040

# Optional local libretro-database checkout for `make index`; cloned when unset
LIBRETRO_DATABASE ?=

SHELL_SOURCES := launch.sh lib/common.sh scripts/build-index.sh tests/run.sh tests/stubs/*

.PHONY: clean build index certs lint test release bump-version push

clean:
	rm -rf dist index certs

build:
	true

# Snapshot of the cheat index bundled in the pak for offline use
index:
	scripts/build-index.sh index $(LIBRETRO_DATABASE)

# CA certificates so the device can verify HTTPS without relying on firmware
certs:
	mkdir -p certs
	curl -fsSL -o certs/cacert.pem.tmp https://curl.se/ca/cacert.pem
	mv certs/cacert.pem.tmp certs/cacert.pem

lint:
	shellcheck -x $(SHELL_SOURCES)

test:
	sh tests/run.sh
	BUSYBOX=1 busybox sh tests/run.sh

release: build index certs
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
	$(MAKE) bump-version
	zip -r "dist/$(PAK_NAME).pak.zip" pak.json
	ls -lah dist

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

push: release
	rm -rf "dist/$(PAK_NAME).pak"
	cd dist && unzip "$(PAK_NAME).pak.zip" -d "$(PAK_NAME).pak"
	adb push "dist/$(PAK_NAME).pak/." "$(PUSH_SDCARD_PATH)/$(PAK_FOLDER)/$(PUSH_PLATFORM)/$(PAK_NAME).pak"
