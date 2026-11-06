#!/bin/sh
#
# Check or configure a FreeBSD system for mdo-steam.  See README.md.
#
# usage: setup.sh check		report what is missing (any user)
#	 setup.sh setup		configure what is missing (root)
#
# Environment:
#	STEAM_USER	the user Steam runs as (default: steam)
#	FOR_USER	the user allowed to start it (default: your login name)
#	DRY_RUN=1	setup prints what it would do and changes nothing

STEAM_USER=${STEAM_USER:-steam}
FOR_USER=${FOR_USER:-$(logname)}
EMUL_PATH=/compat/linux

missing=0
reboot=0

ok()	{ printf '  ok       %s\n' "$*"; }
miss()	{ printf '  MISSING  %s\n' "$*"; missing=$((missing + 1)); }
note()	{ printf '  note     %s\n' "$*"; }
die()	{ printf 'setup.sh: %s\n' "$*" >&2; exit 1; }

run() {
	printf '  + %s\n' "$*"
	[ -n "$DRY_RUN" ] || "$@" || die "failed: $*"
}

# set NAME=VALUE in a sysctl.conf/loader.conf-style FILE, replacing an
# existing assignment of NAME
conf_set() {
	file=$1 name=$2 value=$3
	grep -qxF "$name=$value" "$file" 2>/dev/null && return
	printf '  + %s: %s=%s\n' "$file" "$name" "$value"
	[ -n "$DRY_RUN" ] && return
	if grep -q "^$name=" "$file" 2>/dev/null; then
		tmp=$(mktemp) || die "mktemp failed"
		awk -v n="$name" -v v="$value" \
		    'index($0, n "=") == 1 { print n "=" v; next } { print }' \
		    "$file" >"$tmp" && cat "$tmp" >"$file"
		rm -f "$tmp"
	else
		printf '%s=%s\n' "$name" "$value" >>"$file"
	fi
}

sysctl_is() { [ "$(sysctl -qn "$1")" = "$2" ]; }

mounted() { mount -p | awk -v p="$2" -v t="$1" '$2 == p && $3 == t { f = 1 } END { exit !f }'; }

# the mac_do rule letting FOR_USER become STEAM_USER with its groups
mac_do_rule() {
	u=$(id -u "$FOR_USER") || return 1
	s=$(id -u "$STEAM_USER") || return 1
	g=$(id -g "$STEAM_USER") || return 1
	r="uid=$u>uid=$s,gid=$g"
	for x in $(id -G "$STEAM_USER"); do
		r="$r,+gid=$x"
	done
	echo "$r"
}

has_rule() {
	cur=$(sysctl -qn security.mac.do.rules)
	case ";$cur;" in *";$1;"*) return 0 ;; esac
	return 1
}

check() {
	echo "Packages"
	pkg info -q linux-steam-utils && ok "linux-steam-utils" ||
	    miss "linux-steam-utils (pkg install linux-steam-utils)"

	echo "Linux emulation"
	sysctl_is kern.features.linux64 1 && sysctl_is kern.features.linux 1 &&
	    ok "linux and linux64" || miss "Linux emulation (linux_enable=YES)"
	if [ "$(realpath "$(sysctl -qn compat.linux.emul_path)" 2>/dev/null)" = \
	    "$(realpath $EMUL_PATH 2>/dev/null)" ]; then
		ok "compat.linux.emul_path is $EMUL_PATH"
	else
		miss "compat.linux.emul_path is $(sysctl -qn compat.linux.emul_path), Steam needs the Rocky base at $EMUL_PATH (system-wide: change it yourself)"
	fi
	for m in linprocfs:proc linsysfs:sys devfs:dev tmpfs:dev/shm fdescfs:dev/fd; do
		mounted "${m%%:*}" "$EMUL_PATH/${m#*:}" &&
		    ok "${m%%:*} on $EMUL_PATH/${m#*:}" ||
		    miss "${m%%:*} on $EMUL_PATH/${m#*:} (service linux start)"
	done
	kldstat -q -m nullfs && ok "nullfs loaded" || miss "nullfs loaded"
	for s in security.bsd.unprivileged_chroot vfs.usermount \
	    compat.linux.use_real_ifnames; do
		sysctl_is $s 1 && ok "$s=1" || miss "$s=1"
	done
	[ -s /etc/machine-id ] && ok "/etc/machine-id" || miss "/etc/machine-id"

	echo "Split-lock detection"
	if [ -z "$(sysctl -qn hw.splitlock_force)" ]; then
		ok "not in this kernel"
	elif sysctl_is hw.splitlock_force 0; then
		ok "hw.splitlock_force=0"
	else
		miss "hw.splitlock_force=0 (loader tunable, needs a reboot)"
	fi

	echo "Users"
	if ! id "$STEAM_USER" >/dev/null 2>&1; then
		miss "user $STEAM_USER"
	else
		ok "user $STEAM_USER"
		id -Gn "$STEAM_USER" | tr ' ' '\n' | grep -qx wheel &&
		    miss "$STEAM_USER must not be in wheel"
		id -Gn "$STEAM_USER" | tr ' ' '\n' | grep -qx video &&
		    ok "$STEAM_USER in video" || miss "$STEAM_USER in video"
	fi
	id "$FOR_USER" >/dev/null 2>&1 || die "no such user: $FOR_USER (set FOR_USER)"

	echo "mac_do"
	if ! kldstat -q -m mac_do; then
		miss "mac_do loaded"
	elif rule=$(mac_do_rule 2>/dev/null) && has_rule "$rule"; then
		ok "$FOR_USER may become $STEAM_USER"
	else
		miss "mac_do rule for $FOR_USER to become $STEAM_USER"
	fi
}

setup() {
	[ -n "$DRY_RUN" ] || [ "$(id -u)" = 0 ] ||
	    die "setup needs root: mdo make setup (or DRY_RUN=1)"
	[ "$FOR_USER" != root ] ||
	    die "FOR_USER is root: run as yourself through mdo/su, or set FOR_USER"
	id "$FOR_USER" >/dev/null 2>&1 || die "no such user: $FOR_USER"

	echo "Packages"
	pkg info -q linux-steam-utils || run pkg install -y linux-steam-utils

	echo "Linux emulation"
	case $(sysrc -n linux_enable 2>/dev/null) in
	[Yy][Ee][Ss]) ;;
	*) run sysrc -q linux_enable=YES ;;
	esac
	case " $(sysrc -n kld_list 2>/dev/null) " in
	*" nullfs "*) ;;
	*) run sysrc -q kld_list+=nullfs ;;
	esac
	kldstat -q -m nullfs || run kldload nullfs
	mounted linprocfs $EMUL_PATH/proc || run service linux start
	for s in security.bsd.unprivileged_chroot vfs.usermount \
	    compat.linux.use_real_ifnames; do
		sysctl_is $s 1 || run sysctl $s=1
		conf_set /etc/sysctl.conf $s 1
	done
	[ -s /etc/machine-id ] ||
	    { printf '  + /etc/machine-id\n'; [ -n "$DRY_RUN" ] ||
	      uuidgen | tr -d - >/etc/machine-id; }

	echo "Split-lock detection"
	if [ -n "$(sysctl -qn hw.splitlock_force)" ] &&
	    ! sysctl_is hw.splitlock_force 0; then
		conf_set /boot/loader.conf hw.splitlock_force 0
		reboot=1
	fi

	echo "Users"
	if ! id "$STEAM_USER" >/dev/null 2>&1; then
		run pw useradd "$STEAM_USER" -m -s /bin/sh -c "Steam" -G video
	fi
	id -Gn "$STEAM_USER" 2>/dev/null | tr ' ' '\n' | grep -qx wheel &&
	    die "$STEAM_USER is in wheel; lsu-bootstrap refuses group 0: remove it (pw groupmod wheel -d $STEAM_USER)"
	id -Gn "$STEAM_USER" 2>/dev/null | tr ' ' '\n' | grep -qx video ||
	    run pw groupmod video -m "$STEAM_USER"

	echo "mac_do"
	# a kernel with mac_do built in needs no module
	if kldstat -q -n mac_do.ko || ! kldstat -q -m mac_do; then
		conf_set /boot/loader.conf mac_do_load '"YES"'
		kldstat -q -m mac_do || run kldload mac_do
	fi
	if [ -n "$DRY_RUN" ] && ! id "$STEAM_USER" >/dev/null 2>&1; then
		note "the mac_do rule is computed once $STEAM_USER exists"
	else
		rule=$(mac_do_rule) || die "cannot compute the mac_do rule"
		if ! has_rule "$rule"; then
			cur=$(sysctl -qn security.mac.do.rules)
			new=${cur:+$cur;}$rule
			run sysctl security.mac.do.rules="$new"
			conf_set /etc/sysctl.conf security.mac.do.rules "\"$new\""
		fi
	fi

	if [ "$(realpath "$(sysctl -qn compat.linux.emul_path)" 2>/dev/null)" != \
	    "$(realpath $EMUL_PATH 2>/dev/null)" ]; then
		note "compat.linux.emul_path is $(sysctl -qn compat.linux.emul_path)," \
		    "Steam needs $EMUL_PATH; it is system-wide, so change it yourself"
	fi
	[ "$reboot" = 0 ] || note "reboot for hw.splitlock_force=0 to take effect"
	echo "Done.  Next, as $FOR_USER: make install"
}

case $1 in
check)
	check
	[ "$missing" = 0 ] && echo "All set." || { echo "$missing missing: run 'mdo make setup'"; exit 1; }
	;;
setup)
	setup
	;;
*)
	echo "usage: setup.sh check | setup" >&2
	exit 64
	;;
esac
