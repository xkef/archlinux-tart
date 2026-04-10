VM_NAME         ?= archlinux-tart
BUILDER_VM      ?= archlinux-builder
BUILDER_BASE    ?= ghcr.io/cirruslabs/debian:latest
DISK_SIZE       ?= 50
CPU             ?= 4
MEMORY          ?= 8192
GHCR_IMAGE      ?= $(shell ./scripts/default-ghcr-image.sh)
INSTALL_VM_NAME ?= archlinux-base
INSTALL_TART_HOME ?= $(HOME)/.tart

.PHONY: help build push clean

help: ## Show available commands
	@rg '^[a-z][a-z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk -F ':.*## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build a local Tart VM with Arch Linux ARM for Tart
	TART_HOME=$(CURDIR)/.tart \
	VM_NAME=$(VM_NAME) BUILDER_VM=$(BUILDER_VM) BUILDER_BASE=$(BUILDER_BASE) \
	DISK_SIZE=$(DISK_SIZE) CPU=$(CPU) MEMORY=$(MEMORY) \
	./build.sh

push: ## Push the local Tart VM to GHCR using gh auth
	TART_HOME=$(CURDIR)/.tart \
	VM_NAME=$(VM_NAME) GHCR_IMAGE=$(GHCR_IMAGE) \
	INSTALL_VM_NAME=$(INSTALL_VM_NAME) INSTALL_TART_HOME=$(INSTALL_TART_HOME) \
	./scripts/push.sh

clean: ## Remove build artifacts
	rm -rf .build .tart
