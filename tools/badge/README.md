# badge: host tool for SYCL badges

One command for everything you do with badges plugged into a laptop: find them,
open their console, talk to a cart's serial port, flash firmware onto many
badges in one go, install carts, and run the multiplayer lobby. It works with
the badge simulator too.

Needs Python 3.9 or newer and [pyserial](https://pypi.org/project/pyserial/).
Runs on macOS, Linux and Windows.

Cart serial and the lobby need the fork firmware (see
[../../fork/CART_SERIAL.md](../../fork/CART_SERIAL.md)). `list`, `install` and
`flash` also work with upstream firmware.

## Install

```sh
pipx install ./tools/badge          # gives you the `badge` command
# or, with no install at all:
pip install pyserial
python3 tools/badge/badge.py list
```

## Quick start

```sh
badge list                                              # what is plugged in
badge flash zig-out/firmware/sycl-os-kernel.uf2 --all   # fork firmware on every badge
badge install zig-out/carts/lobby-demo.uf2 --all        # a cart on every badge
badge lobby                                             # badges join as they connect
```

With no hardware: start two simulators running a lobby cart, then
`badge lobby`. Simulators listen on `127.0.0.1:7341` and up, and the lobby finds
them by itself.

## Choosing badges

Commands that act on badges take badge names from `badge list`:

| You type | Matches |
|---|---|
| `4A7A31` | the short id shown by `badge list` |
| `E6614C311B4A7A31`, `B4A7` | the USB serial number, or a unique part of it |
| `/dev/ttyACM1`, `COM5`, `/Volumes/SYCLBADGE` | a port or drive of the badge |
| `usb:1-1.2` | a USB location (badges with older firmware have no unique serial) |
| `sim:7341`, `7341` | a simulator; `sim` matches every simulator |

`--all` means every badge. Most commands also take `--port PATH_OR_URL` to skip
discovery and open a serial device or a `socket://host:port` URL directly.

## Commands

### `badge list`

```
ID         KIND   CONSOLE        CART                      DRIVE
4A7A31     fork   /dev/ttyACM0   /dev/ttyACM1              /media/me/SYCLBADGE
usb:1-1.3  stock  /dev/ttyACM2   -                         /media/me/SYCLBADGE1
sim:7341   sim    -              socket://127.0.0.1:7341   -
```

- `fork`: fork firmware (has the cart serial port). `stock`: upstream firmware
  (console only, or only the drive). `sim`: a running simulator.
- Also lists badges in BOOTSEL mode (RP2350 drive), SYCLBADGE drives that could
  not be matched to a badge, and drives that are not mounted.
- `--json` for scripts, `--no-sim` to skip probing simulators, `--sim PORTS` to
  probe other ports, `-v` for serials and USB locations.

### `badge console [BADGE] [-c COMMAND...]`

A terminal on the badge OS console: type `help`. Ctrl-] quits (Ctrl-T Ctrl-H
lists the other terminal keys). Cart `trace()` output shows up here too.

```sh
badge console                    # the only badge
badge console 4A7A31 -c cart list
```

`-c` runs one command, prints its reply and exits (`--timeout` seconds, default
3). `--port` opens a given console port.

### `badge monitor [BADGE] [--hex | --frames]`

Opens a cart serial port (badge or simulator) and prints what the cart sends.
Lines you type are sent to the cart (`--eol lf|cr|crlf|none`, default `lf`).

- `--hex`: hex dump.
- `--frames`: decodes lobby protocol frames, one per line, and turns typed
  lines into frames, so you can play the lobby by hand against a cart:
  `welcome 0 1 4`, `roster 0=me 1=you`, `data 1 hello` (or `data 1 hex:00ff`),
  `pong 7`, `error 3 text`, `raw 83 01 41`, and the cart-side
  `hello GAME NAME [MAX]`, `send TO|all TEXT`, `ping [TOKEN]`, `leave`.

### `badge flash FIRMWARE.uf2 [BADGE ...] [--all]`

Flashes OS firmware. For each badge, one at a time:

1. sends `reboot bootsel` on its console, so the badge restarts into the RP2350
   boot loader and an `RP2350` drive appears;
2. copies the UF2 onto that drive;
3. waits for the drive to go away (the badge reboots into the new firmware) and
   for the badge to come back.

Badges without a console (upstream firmware without the USB console) need the
buttons once: hold `BOOT_SEL` on the back, tap `RESET`, let go of `BOOT_SEL`.
`badge flash` says so and waits for the drive (`--manual-timeout`, default 120
s). An `RP2350` drive that is already there gets flashed first.

- Checks the file first: every block must be valid UF2, and it must start at
  `0x10000000` like an OS image (a cart UF2 is refused; `--force` overrides).
- `--loop`: afterwards keep flashing every `RP2350` drive that appears, until
  Ctrl-C. Handy for a box of badges with upstream firmware: press the buttons
  on one badge after another.
- `--timeout`: seconds to wait for the drive after `reboot bootsel` (default 20).
- Linux without an automounter: `badge flash` tries `udisksctl mount`; if that
  fails it prints the mount command to run and keeps waiting
  (`--no-mount` turns the attempt off).

Carts on the badge survive a firmware update.

### `badge install CART.uf2 [BADGE ...] [--all]`

Copies a cart onto the `SYCLBADGE` drive of each badge, under the cart's file
name (`--name` to change it), and flushes it to the badge. Then pick the cart
from the badge menu.

- `--all` copies to every `SYCLBADGE` drive, even ones not matched to a badge.
- Refuses OS firmware (use `badge flash`), checks free space first. The drive
  holds 32 root directory entries; delete old carts (from the drive, or
  `badge console -c cart delete NAME`) when it is full.

### `badge lobby`

Runs the lobby relay (protocol v1 in
[CART_SERIAL.md](../../fork/CART_SERIAL.md)). Plug badges in and out while it
runs: it rescans every second, opens each new badge's cart port (with DTR set,
which tells the badge a host is listening) and every simulator it finds, and
drops ports that vanish. Carts join rooms by game id; up to 16 players a room,
any number of rooms and games at once.

```
12:00:01 lobby v1: watching USB badges, simulators on 127.0.0.1:7341-7356; Ctrl-C stops
12:00:01 + 4A7A31
12:00:02 room 1 opened for DOTS (size 16)
12:00:02 join  4A7A31 'adrian' -> DOTS room 1 as 0 (1/16)
12:00:05 + sim:7341
12:00:05 join  sim:7341 'player' -> DOTS room 1 as 1 (2/16)
12:00:12 stats (frames/s in/out): room 1 DOTS 2/16: 0 adrian 60/60, 1 player 60/61
```

- `--sim PORTS`: simulator ports (`7341,7342`, `7341-7344`, `host:port`);
  `--no-sim`, `--no-usb` to leave either out; `--port PATH_OR_URL` (repeatable)
  for extra ports.
- `--max-room N`: room size for carts that ask for the host default, and the
  cap for all rooms (2-16, default 16).
- `--stats SECONDS`: per-player frame rates every N seconds (0 = off).
- `--queue-limit BYTES`: a player whose port stops taking data (the cart hung)
  is removed once this much output is waiting, so it never holds up the others
  and nobody loses frames.
- `-v`: log every message.
- `--listen [ADDR:]PORT`: also take players from `badge join` on other
  computers (default `127.0.0.1:7360`; `0.0.0.0:7360` opens it to the LAN).
- `--tailcat`: serve that port over [tailcat](https://github.com/tailscale/tailcat)
  and print the `badge join tc...` line to send the others (implies
  `--listen`). Each run gets a new address; `--tailcat-key NAME` uses a key
  saved with `tailcat genkey --key=NAME`, so the address survives restarts.

### `badge join TARGET`

Puts this computer's badges and simulators in a lobby that runs on another
computer (fork/NET_LOBBY.md). TARGET is the hub's tailcat address
(`tc...`, printed by `badge lobby --tailcat`) or `HOST[:PORT]` for a hub
on the same network or tailnet with `--listen 0.0.0.0`. Each local badge
gets its own connection to the hub, so the hub sees one player per badge,
exactly as if it were plugged in there.

```
12:00:01 joining the lobby at tailcat tcpGFwWCBgaP...; Ctrl-C stops
12:00:01 usb:E4637C9C1B6A2B21: found
12:00:02 usb:E4637C9C1B6A2B21: in the lobby
12:00:02 tailcat path: direct via 203.0.113.7:41641, 18ms
```

A badge's cart port opens only once the hub has answered through the new
connection, so while the hub is unreachable the cart shows "waiting for
host"; it rejoins by itself when the hub comes back (with a fresh tailcat
address only if you passed `--tailcat-key` on the hub). The joiner PINGs a
quiet hub every 3 s and drops the link after 10 s without an answer.
`--sim`, `--no-sim`, `--no-usb` and `--port` work as for `badge lobby`;
`--remote-port N` when the hub listens on a port other than 7360.

Tailcat: open source, no account, WireGuard end to end, direct
peer-to-peer after NAT traversal, falling back to Tailscale's free relays.
Install it on every computer (`brew install tailcat`, `scoop install
tailcat`, or a release binary). Anyone with the address can join, so share
it only with the players.

Performance (`python3 tools/badge/bench_lobby.py`, 16 fake carts over
localhost TCP at 60 Hz with 6-byte payloads): 960 frames/s in, 14,400/s out,
about 0.2 ms median and 5-7 ms 99th percentile relay latency, 8% of one core.

## Platform notes

**macOS.** Ports are `/dev/cu.usbmodem...`; drives are `/Volumes/SYCLBADGE`,
`/Volumes/SYCLBADGE 1`, ... when several badges are plugged in. The tool reads
`ioreg` to tell the console port from the cart port and to match each drive to
its badge. macOS may warn that a disk was not ejected properly after a
firmware flash; that is expected (the badge reboots). The badge drive has
room for 32 root directory entries and macOS's hidden folders (`.fseventsd`,
`.Spotlight-V100`, `.Trashes`) take several of them; if `badge install` reports
a full drive with space left, delete old carts.

**Linux.** Ports are `/dev/ttyACM*` (stable names:
`/dev/serial/by-id/usb-*_SYCL_Badge_V2_<serial>-if01` for the console, `-if03`
for the cart port). You need access to serial ports (the `dialout` or `uucp`
group, or the udev rule below) and, without a desktop automounter, mounted
drives. ModemManager may probe new serial ports; tell it to leave badges alone
and give the logged-in user access with a udev rule:

```
# /etc/udev/rules.d/70-sycl-badge.rules
ATTRS{idVendor}=="04d2", ATTRS{idProduct}=="04d2", ENV{ID_MM_DEVICE_IGNORE}="1", TAG+="uaccess"
```

then `sudo udevadm control --reload && sudo udevadm trigger`.

**Windows.** Ports are `COM` ports, drives are drive letters labelled
`SYCLBADGE`. With several badges the tool cannot always tell which drive is
whose; `badge install --all` still reaches every drive.

## Using it from Python

The modules are importable for your own host programs:

```python
from badge import discover, frames, links

scan = discover.scan()                       # badges and simulators
badge = next(b for b in scan.badges if b.cart)
link = links.open_link(badge.cart)           # serial port or socket:// URL
link.write(frames.encode(frames.Hello(game="DOTS", name="host").pack()))
decoder = frames.FrameDecoder()
for body in decoder.feed(link.read(1.0)):
    print(frames.describe(frames.unpack(body)))
```

- `frames`: COBS, `FrameDecoder`, every protocol v1 message (`Hello`, `Send`,
  `Ping`, `Leave`, `Welcome`, `Roster`, `Data`, `Pong`, `Error`), `unpack`,
  `describe`. No dependencies.
- `discover`: `scan()`, `Badge`, `select()`, simulator probing.
- `links`: `Link` (read / write / close, plus an optional non-blocking
  selector path), `SerialLink`, `SocketLink`, `open_link`.
- `net`: `ListenSource` (remote players for a `LobbyServer`), `Joiner`,
  `Tailcat` (see the module docstring).
- `lobby`: `Lobby` (the protocol state machine, no I/O) and `LobbyServer`.
  Anything that produces `Link`s can feed the relay: a source is an object
  with `start(server)` and `stop()` that calls `server.add_link(link)` and
  `server.remove_key(key, reason)` (see the module docstring).

## Tests

```sh
python3 -m unittest discover tools/badge/tests
python3 tools/badge/bench_lobby.py            # relay throughput and latency
```

The tests need no hardware: canned USB data for macOS, Linux and Windows,
fake drives and boot loader, a pseudo terminal standing in for a serial port,
and fake simulator carts over localhost TCP.
`BADGE_TEST_TAILCAT=1` adds an end-to-end test through real tailcat
(needs tailcat installed and internet access).
