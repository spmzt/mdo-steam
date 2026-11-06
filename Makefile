# mdo-steam: run Steam as a separate user in your desktop session.
# See README.md.

PREFIX?=	${HOME}/.local
BINDIR?=	${PREFIX}/bin
APPDIR?=	${PREFIX}/share/applications

all:
	@echo "make check       check the system setup Steam needs (any user)"
	@echo "mdo make setup   configure what is missing (root; DRY_RUN=1 to preview)"
	@echo "make install     install mdo-steam for yourself (not as root)"
	@echo "make uninstall   remove it again"

check:
	@sh ${.CURDIR}/setup.sh check

setup:
	@sh ${.CURDIR}/setup.sh setup

install:
	@[ "$$(id -u)" != 0 ] || { echo "install as yourself, not as root"; exit 1; }
	install -d ${BINDIR} ${APPDIR}
	install -m 755 ${.CURDIR}/mdo-steam ${BINDIR}/mdo-steam
	sed 's|^Exec=mdo-steam|Exec=${BINDIR}/mdo-steam|' \
	    ${.CURDIR}/steam.desktop >${APPDIR}/steam.desktop
	-xdg-mime default steam.desktop x-scheme-handler/steam

uninstall:
	rm -f ${BINDIR}/mdo-steam ${APPDIR}/steam.desktop

.PHONY: all check setup install uninstall
