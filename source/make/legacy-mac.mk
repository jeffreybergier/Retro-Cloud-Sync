# Shared legacy Mac OS X toolchain settings.

LEGACY_TOOLCHAIN ?= /osxcross/legacy/target
LEGACY_BIN := $(LEGACY_TOOLCHAIN)/bin
SDK := $(LEGACY_TOOLCHAIN)/SDK/MacOSX10.5.sdk

PPC_CC := $(LEGACY_BIN)/oppc32-gcc
I386_CC := $(LEGACY_BIN)/o32-gcc
LEGACY_AR := $(LEGACY_BIN)/i386-apple-darwin9-ar
LEGACY_RANLIB := $(LEGACY_BIN)/i386-apple-darwin9-ranlib
LIPO := $(LEGACY_BIN)/i386-apple-darwin9-lipo
ANALYZER ?= /usr/bin/clang

MACOSX_DEPLOYMENT_TARGET := 10.4
COMMON_FLAGS := -g -std=c99 -Wall -Wextra -fno-stack-protector \
	-fno-common -fno-zero-initialized-in-bss -I$(SOURCE_ROOT)/shared

CONFIG ?= release
ifeq ($(CONFIG),debug)
  OPT_FLAGS := -O0
else ifeq ($(CONFIG),release)
  OPT_FLAGS := -O3
else
  $(error Unsupported CONFIG "$(CONFIG)"; expected debug or release)
endif

validate-build:
	@if [ ! -x "$(PPC_CC)" ]; then \
		echo " [!] ERROR: Legacy PowerPC compiler missing: $(PPC_CC)"; \
		exit 1; \
	fi
	@if [ ! -x "$(I386_CC)" ]; then \
		echo " [!] ERROR: Legacy i386 compiler missing: $(I386_CC)"; \
		exit 1; \
	fi
	@if [ ! -x "$(LIPO)" ]; then \
		echo " [!] ERROR: Legacy lipo missing: $(LIPO)"; \
		exit 1; \
	fi
	@if [ ! -d "$(SDK)" ]; then \
		echo " [!] ERROR: Mac OS X 10.5 SDK missing: $(SDK)"; \
		exit 1; \
	fi

validate-analyzer:
	@if [ ! -d "$(SDK)" ]; then \
		echo " [!] ERROR: Mac OS X 10.5 SDK missing: $(SDK)"; \
		exit 1; \
	fi
	@if [ ! -x "$(ANALYZER)" ]; then \
		echo " [!] ERROR: Clang static analyzer missing: $(ANALYZER)"; \
		exit 1; \
	fi

.PHONY: validate-build validate-analyzer
