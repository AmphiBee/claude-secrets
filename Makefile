PREFIX ?= $(HOME)/.local

.PHONY: install update uninstall check test version screenshots deb appimage packages mac mac-test mac-install mac-identity mac-uninstall

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

# Installation propre dans /Applications ; mac-identity crée une identité de signature locale stable (une fois)
mac-install:
	@./macos/Tools/install-app.sh

mac-identity:
	@./macos/Tools/make-signing-identity.sh

mac-uninstall:
	@rm -rf "/Applications/Claude Secrets.app" && echo "Application retirée (le coffre et les réglages ne sont pas touchés)."
