.POSIX:

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
DATADIR = $(PREFIX)/share/every-cli
MANDIR = $(PREFIX)/share/man/man1
BASHCOMPDIR = $(PREFIX)/share/bash-completion/completions
ZSHCOMPDIR = $(PREFIX)/share/zsh/site-functions
FISHCOMPDIR = $(PREFIX)/share/fish/vendor_completions.d

all:
	@echo "every-cli is a shell-based utility and does not require compiling."
	@echo "Run 'sudo make install' to install to $(PREFIX)."
	@echo "Run 'make check' to verify POSIX shell syntax."

check:
	sh -n every-cli lib/core.sh lib/providers/*.sh lib/scrapers/*.sh
	@echo "All shell scripts passed syntax validation."

install:
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 755 every-cli $(DESTDIR)$(BINDIR)/every-cli
	mkdir -p $(DESTDIR)$(DATADIR)/lib/providers
	mkdir -p $(DESTDIR)$(DATADIR)/lib/scrapers
	install -m 644 lib/core.sh $(DESTDIR)$(DATADIR)/lib/core.sh
	install -m 644 lib/providers/*.sh $(DESTDIR)$(DATADIR)/lib/providers/
	install -m 644 lib/scrapers/*.sh $(DESTDIR)$(DATADIR)/lib/scrapers/
	mkdir -p $(DESTDIR)$(MANDIR)
	if [ -f man/every-cli.1 ]; then install -m 644 man/every-cli.1 $(DESTDIR)$(MANDIR)/every-cli.1; fi
	mkdir -p $(DESTDIR)$(BASHCOMPDIR)
	if [ -f completions/every-cli.bash ]; then install -m 644 completions/every-cli.bash $(DESTDIR)$(BASHCOMPDIR)/every-cli; fi
	mkdir -p $(DESTDIR)$(ZSHCOMPDIR)
	if [ -f completions/every-cli.zsh ]; then install -m 644 completions/every-cli.zsh $(DESTDIR)$(ZSHCOMPDIR)/_every-cli; fi
	mkdir -p $(DESTDIR)$(FISHCOMPDIR)
	if [ -f completions/every-cli.fish ]; then install -m 644 completions/every-cli.fish $(DESTDIR)$(FISHCOMPDIR)/every-cli.fish; fi
	@echo "every-cli successfully installed to $(DESTDIR)$(BINDIR)/every-cli"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/every-cli
	rm -rf $(DESTDIR)$(DATADIR)
	rm -f $(DESTDIR)$(MANDIR)/every-cli.1
	rm -f $(DESTDIR)$(BASHCOMPDIR)/every-cli
	rm -f $(DESTDIR)$(ZSHCOMPDIR)/_every-cli
	rm -f $(DESTDIR)$(FISHCOMPDIR)/every-cli.fish
	@echo "every-cli uninstalled from $(PREFIX)"

.PHONY: all check install uninstall
