SHELL := /bin/sh

.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

APP_NAME := alertmanager-ntfy
CMD := ./cmd/alertmanager-ntfy
BUILD_DIR := build
DIST_DIR := dist
export S3_TARGETS

VERSION ?= 0.1.0
VERSION_TAG ?= v$(VERSION)
GOOS ?= linux
GOARCH ?= amd64
CGO_ENABLED ?= 0

BINARY := $(APP_NAME)-$(GOOS)-$(GOARCH)
BINARY_PATH := $(DIST_DIR)/$(BINARY)

.PHONY: help clean test build checksum release publish-s3-local

help:
	@echo "alertmanager-ntfy fork build targets"
	@echo ""
	@echo "Build:"
	@echo "  make test                         Run Go tests"
	@echo "  make build VERSION=0.1.0          Build linux/amd64 binary"
	@echo "  make release VERSION=0.1.0        Build binary and checksums"
	@echo ""
	@echo "Publish:"
	@echo "  make publish-s3-local VERSION=0.1.0 S3_TARGETS='[...]'"
	@echo ""
	@echo "Variables:"
	@echo "  VERSION=$(VERSION) VERSION_TAG=$(VERSION_TAG)"
	@echo "  GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED)"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR) dist-local

test:
	go test ./...

build:
	mkdir -p $(DIST_DIR)
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) \
		go build -trimpath -ldflags "-s -w" -o $(BINARY_PATH) $(CMD)
	chmod +x $(BINARY_PATH)
	@echo "Built $(BINARY_PATH)"

checksum: build
	cd $(DIST_DIR) && sha256sum $(BINARY) > checksums.txt
	@echo "Built $(DIST_DIR)/checksums.txt"

release: checksum
	@ls -lh $(BINARY_PATH) $(DIST_DIR)/checksums.txt

publish-s3-local: release
	VERSION_TAG="$(VERSION_TAG)" \
	VERSION_NAME="$(VERSION)" \
	ARTIFACT_DIR="$(DIST_DIR)" \
	PATH_PREFIX="$${PATH_PREFIX:-third_party}" \
	PLATFORM_ARCH="$(GOARCH)" \
		bash scripts/upload-s3.sh