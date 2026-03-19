PREFIX     ?= /usr/local
DESTDIR    ?=
CRYSTAL    ?= crystal
SHARDS     ?= shards

BUILD_DIR  := build
SRC_DIR    := src
DIST_DIR   := dist

BINARIES   := litin-init litind litinctl \
              rc-service rc-update rc-status \
              systemctl \
              sv runsvdir chpst \
              dinitctl

CRYSTAL_FLAGS ?= --release --no-debug
DEBUG_FLAGS   := --debug
STATIC_FLAGS  := --release --no-debug --static

# ---------------------------------------------------------------------------
.PHONY: all debug static clean install uninstall spec spec-unit spec-integration \
        fmt check dist help

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------

all: $(addprefix $(BUILD_DIR)/,$(BINARIES))

debug: CRYSTAL_FLAGS = $(DEBUG_FLAGS)
debug: all

static: CRYSTAL_FLAGS = $(STATIC_FLAGS)
static: all

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/litin-init: $(BUILD_DIR) src/litin_init.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/litin_init.cr

$(BUILD_DIR)/litind: $(BUILD_DIR) src/litind.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/litind.cr

$(BUILD_DIR)/litinctl: $(BUILD_DIR) src/litinctl.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/litinctl.cr

$(BUILD_DIR)/rc-service: $(BUILD_DIR) src/compat/rc_service_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/rc_service_bin.cr

$(BUILD_DIR)/rc-update: $(BUILD_DIR) src/compat/rc_update_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/rc_update_bin.cr

$(BUILD_DIR)/rc-status: $(BUILD_DIR) src/compat/rc_status_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/rc_status_bin.cr

$(BUILD_DIR)/systemctl: $(BUILD_DIR) src/compat/systemctl_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/systemctl_bin.cr

$(BUILD_DIR)/sv: $(BUILD_DIR) src/compat/sv_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/sv_bin.cr

$(BUILD_DIR)/runsvdir: $(BUILD_DIR) src/compat/runsvdir_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/runsvdir_bin.cr

$(BUILD_DIR)/chpst: $(BUILD_DIR) src/compat/chpst_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/chpst_bin.cr

$(BUILD_DIR)/dinitctl: $(BUILD_DIR) src/compat/dinitctl_bin.cr src/**/*.cr
	$(CRYSTAL) build $(CRYSTAL_FLAGS) -o $@ src/compat/dinitctl_bin.cr

# ---------------------------------------------------------------------------
# Testing
# ---------------------------------------------------------------------------

# Run all specs (unit + integration).
# Integration specs are skipped automatically when build/litind is absent.
spec: spec-unit

spec-unit:
	$(CRYSTAL) spec spec/**/*_spec.cr spec/*_spec.cr --order random \
	  --exclude spec/integration

spec-integration: $(BUILD_DIR)/litind
	$(CRYSTAL) spec spec/integration --order random

# Run a single spec file: make spec-file FILE=spec/core/ipc_spec.cr
spec-file:
	$(CRYSTAL) spec $(FILE) --order random

# ---------------------------------------------------------------------------
# Code quality
# ---------------------------------------------------------------------------

# Format all source files in-place.
fmt:
	$(CRYSTAL) tool format src spec

# Format check (does not modify files — suitable for CI).
fmt-check:
	$(CRYSTAL) tool format --check src spec

# Run the Crystal type checker without producing a binary.
check:
	$(CRYSTAL) build --no-codegen src/litind.cr
	$(CRYSTAL) build --no-codegen src/litinctl.cr
	$(CRYSTAL) build --no-codegen src/litin_init.cr

# ---------------------------------------------------------------------------
# Install / Uninstall
# ---------------------------------------------------------------------------

install: all
	install -d $(DESTDIR)$(PREFIX)/sbin
	install -d $(DESTDIR)$(PREFIX)/bin
	install -d $(DESTDIR)/etc/litin/services
	install -d $(DESTDIR)/etc/litin/targets
	install -d $(DESTDIR)/etc/litin/sockets
	install -d $(DESTDIR)/etc/litin/timers
	install -d $(DESTDIR)/etc/litin/masks
	install -d $(DESTDIR)/etc/litin/env
	install -d $(DESTDIR)/var/log/litin
	install -d $(DESTDIR)/run/litin
	install -m 0755 $(BUILD_DIR)/litin-init  $(DESTDIR)$(PREFIX)/sbin/litin-init
	install -m 0755 $(BUILD_DIR)/litind       $(DESTDIR)$(PREFIX)/sbin/litind
	install -m 0755 $(BUILD_DIR)/litinctl     $(DESTDIR)$(PREFIX)/bin/litinctl
	install -m 0755 $(BUILD_DIR)/rc-service   $(DESTDIR)$(PREFIX)/bin/rc-service
	install -m 0755 $(BUILD_DIR)/rc-update    $(DESTDIR)$(PREFIX)/bin/rc-update
	install -m 0755 $(BUILD_DIR)/rc-status    $(DESTDIR)$(PREFIX)/bin/rc-status
	install -m 0755 $(BUILD_DIR)/systemctl    $(DESTDIR)$(PREFIX)/bin/systemctl
	install -m 0755 $(BUILD_DIR)/sv           $(DESTDIR)$(PREFIX)/bin/sv
	install -m 0755 $(BUILD_DIR)/runsvdir     $(DESTDIR)$(PREFIX)/bin/runsvdir
	install -m 0755 $(BUILD_DIR)/chpst        $(DESTDIR)$(PREFIX)/bin/chpst
	install -m 0755 $(BUILD_DIR)/dinitctl     $(DESTDIR)$(PREFIX)/bin/dinitctl
	install -m 0644 examples/litin.conf       $(DESTDIR)/etc/litin/litin.conf
	@echo "Litin installed to $(DESTDIR)$(PREFIX)"

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/sbin/litin-init
	rm -f $(DESTDIR)$(PREFIX)/sbin/litind
	rm -f $(DESTDIR)$(PREFIX)/bin/litinctl
	rm -f $(DESTDIR)$(PREFIX)/bin/rc-service
	rm -f $(DESTDIR)$(PREFIX)/bin/rc-update
	rm -f $(DESTDIR)$(PREFIX)/bin/rc-status
	rm -f $(DESTDIR)$(PREFIX)/bin/systemctl
	rm -f $(DESTDIR)$(PREFIX)/bin/sv
	rm -f $(DESTDIR)$(PREFIX)/bin/runsvdir
	rm -f $(DESTDIR)$(PREFIX)/bin/chpst
	rm -f $(DESTDIR)$(PREFIX)/bin/dinitctl
	@echo "Litin uninstalled from $(DESTDIR)$(PREFIX)"

# ---------------------------------------------------------------------------
# Source distribution
# ---------------------------------------------------------------------------

VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")

dist: clean
	mkdir -p $(DIST_DIR)
	tar czf $(DIST_DIR)/litin-$(VERSION).tar.gz \
	  --exclude='.git' \
	  --exclude='$(BUILD_DIR)' \
	  --exclude='$(DIST_DIR)' \
	  --transform 's|^|litin-$(VERSION)/|' \
	  .
	@echo "Created $(DIST_DIR)/litin-$(VERSION).tar.gz"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

help:
	@echo "Litin build system"
	@echo ""
	@echo "Targets:"
	@echo "  all              Build all binaries (release)"
	@echo "  debug            Build with debug info"
	@echo "  static           Build statically linked binaries"
	@echo "  spec             Run unit test suite"
	@echo "  spec-integration Run integration tests (requires built litind)"
	@echo "  spec-file FILE=  Run a single spec file"
	@echo "  fmt              Format source files in-place"
	@echo "  fmt-check        Check formatting (CI-safe, no modifications)"
	@echo "  check            Type-check without producing binaries"
	@echo "  install          Install to PREFIX (default /usr/local)"
	@echo "  uninstall        Remove installed files"
	@echo "  dist             Create source tarball"
	@echo "  clean            Remove build artefacts"
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX=          Install prefix (default: /usr/local)"
	@echo "  DESTDIR=         DESTDIR for packaging"
	@echo "  CRYSTAL=         Crystal compiler path"
	@echo "  VERSION=         Version tag for dist target"