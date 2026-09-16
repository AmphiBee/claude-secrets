PREFIX ?= $(HOME)/.local

.PHONY: install uninstall check

install:
	@./install.sh

uninstall:
	@./uninstall.sh

check:
	@/usr/bin/python3 -m py_compile claude-secrets && echo "syntaxe OK"
	@/usr/bin/python3 claude-secrets doctor
