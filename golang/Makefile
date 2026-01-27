# ipv6perftest Makefile
#
# Build the Go application with compile-time configuration
#
# Usage:
#   make                          # Build with no embedded defaults
#   make build                    # Same as above
#   make build-configured         # Build with your defaults (edit variables below)
#   make build-all                # Cross-compile for all platforms
#   make install                  # Install to /usr/local/bin
#
# Build with custom defaults:
#   make build API_TOKEN=your-token GH_REPO=user/repo
#

# Application info
APP_NAME := ipv6perftest
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_TIME := $(shell date -u '+%Y-%m-%dT%H:%M:%SZ')

# Go build settings
GO := go
GOFLAGS := -trimpath
CGO_ENABLED := 0

# Output directory
BUILD_DIR := build

# Compile-time defaults (override on command line or edit here)
API_TOKEN ?=
API_URL ?=
GH_TOKEN ?=
GH_REPO ?=
GH_METHOD ?=
GIT_REPO ?=
GIT_BRANCH ?=
LOCATION ?=
LOCAL_TEST ?=

# Build ldflags
LDFLAGS := -s -w
LDFLAGS += -X main.version=$(VERSION)
LDFLAGS += -X main.buildTime=$(BUILD_TIME)

# Add configured values if provided
ifneq ($(API_TOKEN),)
	LDFLAGS += -X main.defaultAPIToken=$(API_TOKEN)
endif
ifneq ($(API_URL),)
	LDFLAGS += -X main.defaultAPIURL=$(API_URL)
endif
ifneq ($(GH_TOKEN),)
	LDFLAGS += -X main.defaultGHToken=$(GH_TOKEN)
endif
ifneq ($(GH_REPO),)
	LDFLAGS += -X main.defaultGHRepo=$(GH_REPO)
endif
ifneq ($(GH_METHOD),)
	LDFLAGS += -X main.defaultGHMethod=$(GH_METHOD)
endif
ifneq ($(GIT_REPO),)
	LDFLAGS += -X main.defaultGitRepo=$(GIT_REPO)
endif
ifneq ($(GIT_BRANCH),)
	LDFLAGS += -X main.defaultGitBranch=$(GIT_BRANCH)
endif
ifneq ($(LOCATION),)
	LDFLAGS += -X main.defaultLocation=$(LOCATION)
endif
ifneq ($(LOCAL_TEST),)
	LDFLAGS += -X main.defaultLocalTest=$(LOCAL_TEST)
endif

# Platforms for cross-compilation
PLATFORMS := \
	linux/amd64 \
	linux/arm64 \
	linux/arm \
	darwin/amd64 \
	darwin/arm64 \
	freebsd/amd64 \
	windows/amd64

.PHONY: all build build-configured build-all clean install uninstall test lint help

# Default target
all: build

# Build for current platform
build:
	@echo "Building $(APP_NAME) $(VERSION)..."
	$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(APP_NAME) .
	@echo "Built: ./$(APP_NAME)"

# Build with example configuration (edit the variables above)
build-configured:
	@echo "Building $(APP_NAME) with compiled defaults..."
	@echo "  API_TOKEN: $(if $(API_TOKEN),<set>,<not set>)"
	@echo "  GH_REPO:   $(if $(GH_REPO),$(GH_REPO),<not set>)"
	@echo "  GH_TOKEN:  $(if $(GH_TOKEN),<set>,<not set>)"
	@echo "  LOCATION:  $(if $(LOCATION),$(LOCATION),<not set>)"
	$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(APP_NAME) .
	@echo "Built: ./$(APP_NAME)"

# Cross-compile for all platforms
build-all: clean
	@echo "Cross-compiling $(APP_NAME) $(VERSION) for all platforms..."
	@mkdir -p $(BUILD_DIR)
	@for platform in $(PLATFORMS); do \
		GOOS=$${platform%/*}; \
		GOARCH=$${platform#*/}; \
		output=$(BUILD_DIR)/$(APP_NAME)-$${GOOS}-$${GOARCH}; \
		if [ "$${GOOS}" = "windows" ]; then output="$${output}.exe"; fi; \
		echo "  Building $${output}..."; \
		GOOS=$${GOOS} GOARCH=$${GOARCH} CGO_ENABLED=$(CGO_ENABLED) \
			$(GO) build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $${output} . || exit 1; \
	done
	@echo "All binaries built in $(BUILD_DIR)/"
	@ls -la $(BUILD_DIR)/

# Generate checksums for releases
checksums:
	@echo "Generating checksums..."
	@cd $(BUILD_DIR) && sha256sum * > checksums.txt
	@cat $(BUILD_DIR)/checksums.txt

# Install to system
install: build
	@echo "Installing $(APP_NAME) to /usr/local/bin..."
	sudo install -m 755 $(APP_NAME) /usr/local/bin/$(APP_NAME)
	@echo "Installed: /usr/local/bin/$(APP_NAME)"

# Uninstall from system
uninstall:
	@echo "Removing $(APP_NAME) from /usr/local/bin..."
	sudo rm -f /usr/local/bin/$(APP_NAME)
	@echo "Uninstalled"

# Run tests
test:
	$(GO) test -v ./...

# Run linter
lint:
	@which golangci-lint > /dev/null || (echo "Installing golangci-lint..." && go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest)
	golangci-lint run

# Format code
fmt:
	$(GO) fmt ./...

# Clean build artifacts
clean:
	@echo "Cleaning..."
	rm -f $(APP_NAME)
	rm -rf $(BUILD_DIR)
	@echo "Clean complete"

# Show help
help:
	@echo "ipv6perftest Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  build            Build for current platform (default)"
	@echo "  build-configured Build with compiled defaults"
	@echo "  build-all        Cross-compile for all platforms"
	@echo "  install          Install to /usr/local/bin"
	@echo "  uninstall        Remove from /usr/local/bin"
	@echo "  test             Run tests"
	@echo "  lint             Run linter"
	@echo "  fmt              Format code"
	@echo "  clean            Remove build artifacts"
	@echo "  checksums        Generate SHA256 checksums"
	@echo ""
	@echo "Variables (set on command line or edit Makefile):"
	@echo "  LOCAL_TEST       Set to 'true' to make local tests default"
	@echo "  API_TOKEN        ipv6.army API token"
	@echo "  API_URL          Override API endpoint"
	@echo "  GH_TOKEN         GitHub PAT for API submission"
	@echo "  GH_REPO          GitHub repo (owner/repo)"
	@echo "  GH_METHOD        GitHub CLI method (issue/pr)"
	@echo "  GIT_REPO         Git repository URL"
	@echo "  GIT_BRANCH       Git branch (default: main)"
	@echo "  LOCATION         Default location"
	@echo ""
	@echo "Examples:"
	@echo "  make build"
	@echo "  make build LOCAL_TEST=true LOCATION='NYC,US'"
	@echo "  make build API_TOKEN=xxx GH_REPO=myuser/results"
	@echo "  make install"
