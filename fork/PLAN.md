# Cart serial + USB lobby: plan

Goal: several badges plugged into one laptop play the same game through a
lobby program. Carts get a serial byte pipe to the host (`cart.serial`) and a
lobby client (`cart.lobby`); the host gets the `badge` tool (`badge lobby`,
`badge flash`, ...). Spec: [CART_SERIAL.md](CART_SERIAL.md). Fork workflow:
[../FORK.md](../FORK.md).

Constraints:

- ABI-compatible with upstream: only reserved IPC space, a new `os_flags` bit,
  no layout moves. Stock-firmware carts run unchanged; serial carts run on
  stock firmware and report `.unsupported`.
- Small diffs to upstream files; new code in new files.
- Everything testable on the VM without a badge: unit tests, the simulator
  (TCP serial), a USB descriptor check. Hardware checks are listed for the
  show, never blocking.
- Zig: `~/.local/zig-x86_64-linux-0.17.0/zig` (repo needs 0.17.0).
  `zig build` builds firmware, carts and simulators; `zig build test` tests.

## Milestones

### M0: interface (done)

- `feature/usb-console`: Carl's #159 (CDC console) and #160 (reboot bootsel)
  merged onto upstream main 5955625. Builds, tests pass.
- `feature/cart-serial` (on top of usb-console): ABI in `os_abi.zig`
  (`CartSerialRings`, `ipc_data.cart_serial`, `os_flags.cart_serial_supported`),
  `cart.serial` API in `src/os/cart/serial.zig` with platform stubs,
  `cart.lobby` placeholder, this plan, CART_SERIAL.md, FORK.md.

### M1: three parallel tracks

**M1-A OS (src/os, OS side only)**
1. Review the auto-merge of Carl's `setup.zig` changes against upstream #171
   (control OUT data stage for SET_LINE_CODING).
2. Composite device: MSC (if 0), console CDC (if 1-2), cart CDC (if 3-4), each
   CDC behind an IAD; interface strings per CART_SERIAL.md. Endpoint and
   DPRAM allocation documented in usb.zig.
3. USB serial number = RP2350 chip id, 16 uppercase hex digits.
4. Kernel cart serial service: validate rings, rx with backpressure, tx while
   DTR, discard rules, `status`, detach at cart start/stop, set
   `os_flags.cart_serial_supported`. Pure ring logic in its own file with host
   unit tests.
5. Host-side test that walks the configuration descriptor (lengths, counts,
   unique endpoints, IADs).
6. Console `id` command: chip id, firmware version, cart serial state.

**M1-B cart SDK + simulator + carts**
1. `platform_badge.zig` serial implementation against the ABI.
2. Simulator: TCP cart serial (`--serial-port`, `SYCL_SERIAL_PORT`, first free
   7341-7356, printed at startup), `SimulatorAPI` additions.
3. `src/os/cart/lobby.zig`: COBS `Framer`, lobby `Client` (states, events,
   send/broadcast, ping, auto re-HELLO), host unit tests.
4. Carts: `carts/serial-echo`, `carts/lobby-demo` (up to 16 players, each a
   colored square on the d-pad, roster + ping on screen, "needs fork firmware"
   on stock firmware). Registered in build.zig.

**M1-C host tool (tools/badge)**
1. Python 3.9+, pyserial only. `pipx install ./tools/badge` gives `badge`;
   `python3 tools/badge/badge.py` works without installing.
2. Discovery: badges by USB serial number with console + cart ports (Linux,
   macOS, Windows), simulators on 127.0.0.1:7341-7356.
3. Commands: `list`, `console`, `monitor`, `flash` (reboot bootsel over the
   console, wait for the RP2350 drive, copy), `install` (copy a cart UF2 to
   SYCLBADGE drives), `lobby` (protocol v1 relay, hot-plug, rooms).
4. Unit tests with fake transports, `python3 -m unittest`.

### M2: integration (lead)

- Merge M1 tracks, end-to-end on the VM: two or more simulators running
  lobby-demo + `badge lobby`, scripted check that rosters and data flow.
- `fork/sync-upstream.sh`, `main` = upstream + features, README banner.
- Firmware + carts in a dist folder with flashing steps.

### M3: monorepo carts (snouty-badge)

- `lib/cart_serial.zig` + `lib/lobby.zig` in snouty-badge speaking the ABI
  directly (pinned older SDK), so existing carts can add lobby play.

### Later (not scheduled)

- Server-clocked lockstep in the lobby (host collects every player's input
  for frame N and broadcasts the set), for big-lobby action games.
- Web Serial lobby page (Chrome) so the host needs no install.

## Hardware checks (show day, never blocking)

1. Flash fork firmware; `SYCLBADGE` drive still works, carts survive.
2. `badge list` on macOS shows the badge with console and cart ports.
3. `badge console`: `help`, `id`; a cart's `cart.trace()` shows up.
4. serial-echo: `badge monitor` round trip.
5. Two badges + lobby-demo + `badge lobby`: both squares move on both screens.
6. `badge flash --all` updates two badges in one go.

## Status

- 2026-10-05: M0 done. M1 tracks launched.
- 2026-10-05: M1-A OS done on `cart-serial/os`: setup processor fixes from the
  merge review (EP0 stalls, control OUT data stage, string 0), composite
  device with both CDC ports, chip id serial number, cart serial service with
  host tests, console `id`. Untested on hardware.

## Deferred questions (defaults taken)

- Fork remote: needs a GitHub repo (suggested `antithesishq/sycl-badge`) plus
  an exe.dev integration; until then branches are local in
  `/home/exedev/sycl-badge-fork`.
- Room cap 16 players (ROSTER fits one frame).
- Port numbering for simulators starts at 7341.
