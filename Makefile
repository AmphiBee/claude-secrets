PREFIX ?= $(HOME)/.local

.PHONY: install update uninstall check test version screenshots deb appimage packages mac mac-test

install:
	@./install.sh

update:
	@git pull --ff-only
	@./install.sh

uninstall:
	@./uninstall.sh

test:
	@/usr/bin/python3 tests/run.py

check:
	@/usr/bin/python3 -m py_compile claude-secrets && echo "syntaxe OK"
	@/usr/bin/python3 claude-secrets doctor

version:
	@/usr/bin/python3 claude-secrets version

screenshots:
	@/usr/bin/python3 docs/make-screenshots.py

deb:
	@./packaging/build-deb.sh

appimage:
	@./packaging/build-appimage.sh

packages: deb appimage

# Application macOS (Command Line Tools seulement) : voir macos/ et docs/macos/
mac:
	@./macos/Tools/build-app.sh release

mac-test:
	@cd macos && swift run core-tests && python3 Tools/contrast.py
