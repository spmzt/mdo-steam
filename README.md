# mdo-steam

Run Steam on FreeBSD as a **separate, unprivileged user inside your running
desktop session**, using [mac_do(4)](https://man.freebsd.org/mac_do)/`mdo(1)`
and [linux-steam-utils](https://github.com/shkhln/linuxulator-steam-utils)
(`games/linux-steam-utils`).

Steam and every game it runs see only the steam user's home, never your own
files, and you don't have to log out and back in as another user to play.

> **Tested only on FreeBSD 16.0-CURRENT** (`__FreeBSD_version` 1600030,
> November 2026). Some steps below, such as the split-lock tunable, exist
> only on recent -CURRENT kernels. Reports from other versions are welcome.

## How it works

`mdo-steam` does three things:

1. **X access:** it allows the steam user onto your X server (`xhost
   +si:localuser:steam`) and makes the X socket connectable for it (see
   [X socket permissions](#x-socket-permissions)).
2. **Switch user:** it becomes the steam user with `mdo -u steam`, in an empty
   environment (`env -i`), so nothing from your session leaks into Steam
   except `DISPLAY` and `LANG`.
3. **Start Steam:** it bootstraps Steam on first use (`lsu-bootstrap`), then
   runs linux-steam-utils' `steam`.

When started from the menu or taskbar, all output goes to
`~/.cache/mdo-steam.log`.

## Quick start

```sh
git clone https://github.com/spmzt/mdo-steam && cd mdo-steam
make check                      # what's missing (any user)
DRY_RUN=1 make setup            # preview the system changes
mdo make setup                  # make them (as root, via mdo or su)
make install                    # as yourself: ~/.local/bin and the menu entry
```

- **Who gets access:** `make setup` lets the user who runs it through `mdo`
  or `su`, i.e. your login name, become the steam user. Set `FOR_USER=name`
  to choose another user, and `STEAM_USER=name` for another steam account.
- **Safe to rerun:** it skips what's already in place and changes only what's
  missing.
- **Not changed for you:** `compat.linux.emul_path`, because that's
  system-wide (see step 2).
- **Refused:** a steam user that's in `wheel`.
- **Reboot:** needed if it set `hw.splitlock_force`.

Then run `mdo-steam` from a terminal once, to watch it bootstrap Steam and
download its first update. After that, start it from the menu.

## Setup in detail

This is what `make setup` does, step by step, if you'd rather do it by hand.
Everything except installing `mdo-steam` itself needs root.

### 1. Packages

```sh
pkg install linux-steam-utils
```

This pulls in the Rocky Linux 9 base (`linux_base-rl9`), which
linux-steam-utils requires.

### 2. Linux emulation and the filesystems Steam checks for

```sh
sysrc linux_enable=YES kld_list+=nullfs
service linux start           # mounts linprocfs, linsysfs, devfs, fdescfs, /dev/shm
kldload -n nullfs
```

In `/etc/sysctl.conf`:

```
security.bsd.unprivileged_chroot=1
vfs.usermount=1
compat.linux.use_real_ifnames=1
```

Apply them with `service sysctl restart`.

**`compat.linux.emul_path` must point at the Rocky base**: the default is
`/compat/linux`. If you changed it, for example to an Ubuntu chroot, Steam's
start script fails with a Ruby `String#undump` error, because it parses that
tree's `os-release` and requires Rocky. The setting is system-wide.

Steam also needs a machine ID:

```sh
[ -f /etc/machine-id ] || uuidgen | tr -d - > /etc/machine-id
```

### 3. Split-lock detection (recent -CURRENT, Intel CPUs)

Since September 2026, -CURRENT can detect *split locks*: atomic operations
whose operand crosses a cache-line boundary. With the default
`hw.splitlock_force=1`, detection is enabled for every program on CPUs that
support it, and a split lock kills the program with `SIGBUS`. Linux only logs
a warning by default.

The current Steam client does a split lock in its HTTP thread and dies
seconds after starting. `/var/log/messages` shows:

```
kernel: pid 54759 (CHTTPClientThre), jid 0, uid 1001: exited on signal 10
```

Turn the forced detection off in `/boot/loader.conf` and reboot. It's a
boot-time tunable and can't be changed on a running system:

```
hw.splitlock_force=0
```

### 4. The steam user

```sh
pw useradd steam -m -s /bin/sh -c "Steam" -G video
```

- **Not in wheel:** don't put it in `wheel`; `lsu-bootstrap` refuses to run
  for users in group 0.
- **Groups:** `video` gives access to the GPU (`/dev/dri`). Add `audio` too
  if your sound devices are restricted to that group.

### 5. mac_do: allow yourself to become steam

Load mac_do at boot, in `/boot/loader.conf`:

```
mac_do_load="YES"
```

Then add a rule to `security.mac.do.rules` in `/etc/sysctl.conf`. Rules use
numeric IDs; with your uid 1000, steam uid 1001, steam's group 1005, and
video group 44:

```
security.mac.do.rules="uid=1000>uid=1001,gid=1005,+gid=1005,+gid=44"
```

- **What the rule allows:** user 1000 may become uid 1001, with primary group
  1005 and supplementary groups 1005 and 44, and nothing else.
- **Finding the numbers:** `id -u`, `id steam`, and `pw groupshow video`.
- **Several rules:** separate them with `;`. If you already use mdo to become
  root, keep that rule in the list.

Test it:

```sh
mdo -u steam id
```

### 6. Install mdo-steam

As your own user, `make install` (or `make install PREFIX=...`) does this:

```sh
install -m 755 mdo-steam ~/.local/bin/
sed 's|^Exec=mdo-steam|Exec=$HOME/.local/bin/mdo-steam|' steam.desktop \
    > ~/.local/share/applications/steam.desktop
xdg-mime default steam.desktop x-scheme-handler/steam
```

The menu entry gets the full path, so it works even if your desktop session's
`PATH` doesn't include `~/.local/bin`.

Run `mdo-steam` from a terminal the first time, to watch it bootstrap Steam
and download its first update. After that, start it from the menu.

## X socket permissions

Some compositors, KWin's Xwayland for example, create `/tmp/.X11-unix/X0`
with mode `0755`. On FreeBSD, connecting to a Unix socket needs write
permission on it, so the steam user couldn't connect, whatever `xhost`
allows. Steam's setup then fails with `zenity: cannot open display`.

`mdo-steam` adds group and other write permission to your session's socket
on every start. X's own access control still applies: only your session and
the users you allowed with `xhost` can connect.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `exited on signal 10` for `CHTTPClientThre` in `/var/log/messages` | Split-lock detection: see step 3. |
| Ruby `String#undump` error | `compat.linux.emul_path` doesn't point at the Rocky base: see step 2. |
| `lsu-bootstrap` refuses to run | The steam user is in `wheel`. |
| `zenity: cannot open display`, `unable to open display` | X socket permission, or `xhost` failed. |
| `mdo: ... not permitted` | The mac_do rule doesn't match. Check the IDs, and that `mac_do` is loaded. |
| Steam isn't in `ps` | If `security.bsd.see_other_uids=0`, you can't see the steam user's processes. Use `mdo -u steam ps -x`. |

Steam's own logs are in `~steam/.steam/steam/logs/`; read them with
`mdo -u steam cat ...`.

## Known issues

- **A second launch can kill the running Steam.** Starting `mdo-steam` again,
  including clicking a `steam://` link, makes Steam forward the request to
  the running client and exit. linux-steam-utils' cleanup then kills leftover
  processes, which can include the first instance's. Start Steam once.
- **Log noise:** Steam's built-in browser may log a crashed GPU process
  (`GpuMemoryThread ... signal 11`) and `steam-runtime-launcher-service`
  failures. The client still starts.

## Tested with

- FreeBSD 16.0-CURRENT (1600030), amd64
- Intel Core i9-13900HX, NVIDIA RTX 4060 Laptop (`nvidia-drm`)
- KDE Plasma 6 on Wayland, with Steam on Xwayland
- linux-steam-utils 20260923, linux_base-rl9 9.8

Status: Steam starts, updates itself and reaches its login page. Running
games hasn't been verified yet.
