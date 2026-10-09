PREFIX ?= $(HOME)/.local

.PHONY: install update uninstall check test version

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
