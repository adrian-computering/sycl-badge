# Cart serial and the multiplayer lobby

Fork firmware lets a running cart exchange bytes with a program on the computer
the badge is plugged into. Plug several badges into one laptop (a powered hub
helps beyond four), run `badge lobby`, and every badge running a lobby-enabled
cart joins the same game.

```
 badge ──USB── ┐
 badge ──USB── ┤  laptop: badge lobby  (relays messages between badges)
 badge ──USB── ┤
 simulator ─TCP┘
```

There are three layers. Use the highest one that fits:

| Layer | Cart side | Host side | Use it for |
|---|---|---|---|
| Lobby | `cart.lobby` | `badge lobby` | multiplayer games: rooms, player ids, relayed messages |
| Frames | `cart.lobby.Framer` | `badge.frames` (Python) | your own host program speaking messages |
| Bytes | `cart.serial` | any serial terminal / pyserial | anything else |

## Quick start (cart developer)

```zig
const cart = @import("cart-api");

var lobby: cart.lobby.Client = undefined;

pub fn start() void {
    lobby = .init(.{ .game = "DOTS", .name = "player" });
}

pub fn update() void {
    while (lobby.poll()) |event| switch (event) {
        .joined => |j| { _ = j; },       // j.you = your player id
        .roster => {},                   // lobby.players() changed
        .data => |d| { _ = d; },         // d.from, d.bytes
        else => {},                      // .left, .host_error
    };
    lobby.broadcast(&my_state_bytes) catch {}; // not joined yet, or host busy
}
```

`send(to, bytes)` reaches one player, `broadcast` everyone else and
`broadcast_with_echo` everyone including yourself (your own message comes back
as `.data` at its place in the room's order). Sends fail with
`error.NotJoined`, `error.TooLong` (over 240 bytes) or `error.QueueFull` (the
host is not reading; nothing was sent).

`lobby.state()` tells the player what is happening: `.unsupported` (stock
firmware: hide the multiplayer menu), `.waiting_for_host` (plug in / run
`badge lobby`), `.joining`, `.joined`. See `carts/lobby-demo` for a complete
game and `carts/serial-echo` for the raw byte API.

In the simulator the cart serial port is a TCP socket. The simulator prints
`cart serial: tcp://127.0.0.1:7341` at startup (the first free port from 7341
up, or `--serial-port N` / `SYCL_SERIAL_PORT=N`). `badge list` and
`badge lobby` find simulators on 7341-7356 automatically, so two simulators and
a lobby on one laptop is a complete multiplayer test with no hardware. The
simulator serves one client at a time: while one is connected, a second
connection is reset right away (so a probe never kicks out the lobby).

## Quick start (badge owner)

```sh
pipx install ./tools/badge      # or: python3 tools/badge/badge.py ...
badge list                      # badges and simulators, with their ports
badge flash zig-out/firmware/sycl-os-kernel.uf2 --all   # fork firmware on every badge
badge install zig-out/carts/lobby-demo.uf2 --all        # a cart on every badge
badge lobby                     # run the relay; badges join as they connect
```

## USB layout (fork firmware)

The badge is one composite USB device:

| Interfaces | Function | Host sees |
|---|---|---|
| 0 | Mass storage | the `SYCLBADGE` drive |
| 1-2 | CDC ACM "SYCL Badge Console" | OS shell + `cart.trace()` output |
| 3-4 | CDC ACM "SYCL Badge Cart Serial" | the running cart's serial port |

Each CDC function sits behind an interface association descriptor and the
device class is Miscellaneous/Common/IAD, so Linux (`cdc_acm`), macOS and
Windows 10+ (`usbser`) bind both ports without drivers. Endpoints: EP1 mass
storage, EP2 (bulk) and EP3 (notifications) console, EP4 (bulk) and EP5
(notifications) cart serial, all 64 byte full speed packets.

The USB serial number is the RP2350 chip id as 16 uppercase hex digits, the
same digits `picotool info` and the pico-sdk report for the chip, unique per
badge. Ports therefore have stable names:
`/dev/serial/by-id/usb-*_SYCL_Badge_V2_<id>-if03` on Linux, `/dev/cu.usbmodem*`
on macOS, a COM port on Windows; tools should find the cart port by USB serial
number and interface number (3) rather than by name; `badge list` shows
which port is which on every OS. The console's `id`
command prints the chip id. The baud rate setting is ignored; the port always
runs at USB speed.

Behavior of the cart port:

- **No cart has the port open:** bytes from the host are discarded and the
  host can still open the port.
- **Cart open, host not connected (DTR low, or the bus suspended or the cable
  unplugged):** bytes the cart writes are discarded, so a cart never stalls on
  a closed port. `connected()` is false. Bytes from the host are still
  delivered. One packet (at most 64 bytes) the cart wrote just before the host
  closed the port may still be waiting in the badge and arrive when the host
  next opens it; framed protocols resynchronize past it.
- **Both open:** reliable, ordered, lossless. When the cart's receive ring is
  full the badge stops accepting USB data, so the host's writes block until the
  cart reads.
- **Cart exits:** the OS closes the port; the host side stays open and the next
  cart can open it again.

## Cart ABI (for other SDKs)

Carts built with this repo's `cart-api` need nothing below. It is for carts
built with other SDKs (for example a pinned older `sycl-badge`) that want to
talk to the port directly. Defined in `src/os/cart/os_abi.zig`.

- `ipc_data.os_flags` (u16 at `0x200350EA`) bit 1 = `cart_serial_supported`.
  Stock firmware leaves it 0.
- `ipc_data.cart_serial` (u32 at `0x200350F4`) = address of a
  `CartSerialRings` in cart RAM, or 0 when closed. The OS zeroes it when a cart
  starts and when it stops.

```
CartSerialRings (extern, 40 bytes, little-endian, in cart RAM)
  +0  magic     u32  0x53455231 ("SER1")
  +4  rx_buf    u32  address of the receive ring (host -> cart)
  +8  rx_cap    u32  power of two, >= 64
  +12 rx_write  u32  written by the OS
  +16 rx_read   u32  written by the cart
  +20 tx_buf    u32  address of the transmit ring (cart -> host)
  +24 tx_cap    u32  power of two, >= 64
  +28 tx_write  u32  written by the cart
  +32 tx_read   u32  written by the OS
  +36 status    u32  written by the OS: bit0 host_open (DTR), bit1 attached
```

Indices are free-running byte counts, so `write - read` (wrapping u32
subtraction) is the number of queued bytes, and byte `i` lives at
`buf[i & (cap - 1)]`. Writers store data, `dmb`, then the index; readers load
the index, `dmb`, then data. To open: fill the struct with zeroed indices, `dmb`,
store its address to `cart_serial`. To close: store 0. Every pass the OS
validates the magic, the sizes, that the struct (4-byte aligned) and both
rings lie in cart RAM (`0x20035100`-`0x20080000`), and that the rings overlap
neither each other nor the struct; it ignores a struct that fails.
`status.attached` turns on once it is serviced. Keep the struct and the rings
in static memory: right after the cart stores 0 the OS may still finish the
pass it is in.

## Lobby protocol v1

The protocol between `cart.lobby` and `badge lobby`. Any host program or cart
may implement it; the reference implementations are `src/os/cart/lobby.zig`
and `tools/badge/badge/lobby.py`.

### Framing

The byte stream carries frames. Each frame is a body encoded with
[COBS](https://en.wikipedia.org/wiki/Consistent_Overhead_Byte_Stuffing)
followed by one `0x00` byte. A body is `type: u8` then the payload, at most
250 bytes in total. A receiver drops a frame that fails to decode or is too
long, then carries on at the next `0x00`, so a badge or host that starts
listening mid-stream resynchronizes by itself. Senders write a lone `0x00`
when they (re)connect to flush any partial frame on the other end. Empty
frames (two `0x00` in a row) are ignored.

Integers are little-endian. Names and game ids are ASCII, zero-padded to their
fixed length.

### Messages

Cart to host:

| Type | Name | Payload |
|---|---|---|
| `0x01` | HELLO | `version: u8 = 1`, `game: [8]u8`, `name: [12]u8`, `max_players: u8` (2-16, 0 = host default) |
| `0x02` | SEND | `to: u8` (player id; `0xFF` = everyone else in the room; `0xFE` = everyone including the sender), `data` (0-240 bytes) |
| `0x03` | PING | `token: u32` |
| `0x04` | LEAVE | (none) |

Host to cart:

| Type | Name | Payload |
|---|---|---|
| `0x81` | WELCOME | `version: u8 = 1`, `you: u8` (player id), `room: u8`, `max_players: u8` |
| `0x82` | ROSTER | `count: u8`, then `count` x (`id: u8`, `name: [12]u8`), including you |
| `0x83` | DATA | `from: u8`, `data` (0-240 bytes) |
| `0x84` | PONG | `token: u32` (echoed) |
| `0x8F` | ERROR | `code: u8`, `message` (ASCII, rest of the frame) |

Error codes: 1 unsupported version, 2 no room (server full), 3 not joined
(SEND/LEAVE before WELCOME), 4 malformed message.

### Rules

- A cart sends HELLO when it opens the port and again whenever `connected()`
  goes from false to true (the lobby restarted, or the cable was replugged).
  A HELLO from a cart that is already in a room is a rejoin: it leaves the old
  room first, exactly like a LEAVE. The other members always get the ROSTER
  without the player before any ROSTER that has it again, so a rejoin is
  visible as a leave plus a join even when the player gets the same room and
  id back. (It can land in another room or get another id: placement is a
  fresh join. If it was alone, the old room closes and a new one opens.) The
  rejoining cart gets WELCOME, then the new room's ROSTER.
- The host puts a new player in the first room with the same `game` that has a
  free slot, otherwise opens a new room. A room's size is the first member's
  `max_players` (capped at 16). Rooms with different `game` ids never mix, so
  one lobby can run several games at once.
- Player ids are `0..max_players-1`, the lowest free id in the room, and stay
  fixed while the player is connected.
- The host sends WELCOME to the new player, then ROSTER to everyone in the
  room, after every join and leave.
- SEND is relayed as DATA to the addressed player, to every other player in
  the room for `0xFF`, or to every player including the sender for `0xFE`
  (self-echo: the sender gets `DATA(from = itself)` at its place in the room's
  order, like a shared serial line where a console hears its own bytes). A
  SEND to an id that is not in the room is dropped. The host never invents
  game data; games decide who is authoritative (for example, the lowest
  player id).
- **One order per room.** The host handles a room's frames one at a time: a
  frame is queued to every recipient before the next frame is looked at, so
  all players see the room's DATA in the same global order (each player minus
  its own frames, unless it used `0xFE`). The ROSTER that removes a player is
  queued after every frame that player got to the host, so "the last input
  anyone received from the leaver" is the same on every badge.
- **No silent loss.** While a player is connected nothing addressed to it is
  dropped. If a player stops reading and its outgoing queue overflows, the
  host removes that player (ROSTER to the others, port closed) rather than
  skipping frames.
- A player leaves when it sends LEAVE or HELLO for another game, its port
  closes, or the badge disappears. The host closes the port of a badge it
  stops seeing.
- Before its HELLO, a link hears nothing from the host except the leading
  `0x00` and PONGs: the host answers PING at any time, joined or not, and
  sends a link no room traffic until it joins. (`badge join` relies on this
  to check a new hub connection with a PING before it opens the cart port.)
- Unknown message types are ignored by both sides, so later versions can add
  messages without breaking v1 peers. Bytes after the end of a fixed-size
  payload are ignored too, so later versions can append fields. A host-to-cart
  type arriving at the host counts as unknown.
- Details of the reference host (`badge lobby`), which other hosts should
  match:
  - Rooms are numbered from 1, lowest free, up to 255; ERROR 2 only when all
    255 are in use.
  - `max_players` 0 means the host default (`--max-room`, 16); other values
    are clamped to 2..min(16, `--max-room`).
  - A HELLO with an unsupported version leaves the old room, then gets ERROR 1.
  - A SEND addressed to the sender's own id is delivered to it.
  - A SEND or DATA with more than 240 bytes of data is malformed (ERROR 4).
