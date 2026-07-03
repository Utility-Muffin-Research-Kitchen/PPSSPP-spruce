SHELL := /bin/bash
TOOLCHAIN_IMAGE ?= ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local
DOCKER ?= docker
MLP1_BUILD_PROFILE ?= perf

.DEFAULT_GOAL := help
.PHONY: help build-mlp1 package-mlp1 clean

help:
	@echo "PPSSPP-spruce UMRK commands:"
	@echo "  make build-mlp1     build PPSSPP with the UMRK MLP1 toolchain"
	@echo "  make package-mlp1   package the MLP1 PPSSPP standalone payload"
	@echo "  make clean          remove generated package output"

build-mlp1:
	$(DOCKER) run --rm \
		-v "$(CURDIR)":/src \
		-w /src \
		-e WORKDIR=/src/workdir/mlp1/build \
		-e OUTPUT_DIR=/src/output/mlp1/build \
		-e PPSSPP_VERSION \
		-e BUILD_JOBS \
		-e FORCE_CONFIGURE \
		-e MLP1_BUILD_PROFILE="$(MLP1_BUILD_PROFILE)" \
		"$(TOOLCHAIN_IMAGE)" \
		./build-mlp1.sh

package-mlp1: build-mlp1
	MLP1_BUILD_PROFILE="$(MLP1_BUILD_PROFILE)" ./package-mlp1.sh

clean:
	rm -rf output
