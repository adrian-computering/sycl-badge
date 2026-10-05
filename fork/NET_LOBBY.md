# Network lobby: plan

Goal: badges plugged into different laptops play in the same lobby, over a
shared network or the internet. Builds on the cart serial port and
`badge lobby` ([CART_SERIAL.md](CART_SERIAL.md), [PLAN.md](PLAN.md)).
Branch `feature/net-lobby`, based on `feature/cart-serial`.

```
 laptop A (hub)                               laptop B (joiner)
 ┌──────────────────────────┐                ┌───────────────────────┐
 │ badge lobby --tailcat    │  tailcat       │ badge join tcXXXX     │
 │   rooms, relay           │◀═ WireGuard ══▶│   one TCP stream      │
 │   local badges ──USB     │  direct P2P,   │   per local badge     │
 │   --listen 127.0.0.1:7360│  DERP fallback │   badges ──USB        │
 └──────────────────────────┘                └───────────────────────┘
```

## Design

Nothing changes on the badge: same firmware, same carts, lobby protocol v1
as it is. Networking lives entirely in the `badge` host tool.

- **One hub.** One laptop runs `badge lobby` as usual and is the only
  place with room logic. `--listen [ADDR:]PORT` (default `127.0.0.1:7360`)
  also accepts TCP connections. Each connection is one remote player, and
  its byte stream is exactly what a cart serial port carries (COBS lobby v1
  frames). When the connection closes, the hub treats it as that badge's
  port closing, so the player leaves the room.
- **Joiners just pass bytes through.** `badge join TARGET` finds local
  badges and simulators the same way `badge lobby` does (with hot-plug).
  For each one it opens a TCP connection to the hub and copies bytes both
  ways without decoding anything. If the hub link drops, the joiner closes
  the badge's cart port, so DTR goes low and the cart shows "waiting for
  host". It reconnects with backoff and reopens the port, the cart sees
  `connected()` go true, and it sends HELLO again (rule in CART_SERIAL.md).
- **Targets.** `host:port` works on a LAN or over Tailscale. A tailcat
  address (`tc...`) makes the joiner run `tailcat forward ADDR 0:PORT` and
  connect to the local port tailcat prints.
- **`--tailcat` on the hub** runs `tailcat serve --key=new PORT`, then
  prints the address and a ready-to-paste `badge join tc...` line.
  `--tailcat-key NAME` uses a saved tailcat key, so the address stays the
  same across restarts (for a standing show lobby).
- **Why tailcat:** it's open source and needs no account or admin rights.
  Connections are encrypted end to end with WireGuard and go direct
  peer-to-peer after NAT traversal. Tailscale's free DERP relays carry the
  traffic only if that fails, and lobby traffic is tiny. Verified on the VM
  2026-10-05 with tailcat v0.7.0: one `serve`, two `forward` clients, three
  connections, the first ping via DERP(sfo) in 19 ms, then direct.
- **Security.** By default `--listen` binds to loopback only, so only
  tailcat (or ssh) can reach it. `--listen 0.0.0.0:7360` opens it to the
  LAN, which is fine on a trusted network. A tailcat address works like a
  password, so share it privately. The hub never runs anything a peer
  sends; it only relays frames, and v1 already drops malformed ones.

## Milestones

### N0: join over TCP (LAN / Tailscale)
1. `badge/net.py`: `Listener` (accepted sockets become player links for
   the relay), `Joiner` (a TCP stream per local endpoint, reconnect, DTR
   cycling, hot-plug), endpoint-agnostic so tests use fakes.
2. `badge lobby --listen`, plus a `badge join HOST:PORT` subcommand.
3. Unit tests (`python3 -m unittest`): byte passthrough, hub restart
   (the cart sees disconnect then reconnect), joiner restart (the player
   leaves and rejoins), hot-plug, a closed hub port.

### N1: tailcat
1. `Tailcat` wrapper: finds the `tailcat` binary (or `--tailcat-bin`),
   runs `serve` / `forward`, parses the address and local port from
   its output, prints the path (direct or DERP) via `tailcat ping`, and
   says how to install it if it's missing.
2. `badge lobby --tailcat [--tailcat-key NAME]`, `badge join tc...`.
3. A test that uses a fake `tailcat` script (so CI needs no network), plus
   a real tailcat end-to-end check on the VM.

### N2: end-to-end + docs
1. On the VM: two simulators running lobby-demo on the hub, two on a
   joiner, linked through real tailcat. Scripted check that all four
   rosters match and data flows between them.
2. A "Playing over the network" section in CART_SERIAL.md, a FORK.md row,
   and copy-paste steps for two laptops.

## Not in scope (notes)

- **Latency.** The hub relays immediately. Over the internet, round trips
  are 20-150 ms instead of about 1 ms on USB. Loosely synced games (the
  lobby demo, turn-based play) are fine. Frame-locked games
  (snouty-badge `lib/lockstep.zig`, Genesis 4P) need an input delay of at
  least RTT / 16.7 ms frames, or the server-clocked lockstep listed in
  PLAN.md "Later".
- **Several hubs merging their rooms.** One hub per session is simpler, and
  tailcat makes any laptop reachable.

## Status

- 2026-10-05: plan written; tailcat v0.7.0 verified on the VM.
- 2026-10-05: N0 + N1 + N2 DONE on `feature/net-lobby`.
  - `badge lobby --listen [ADDR:]PORT --tailcat [--tailcat-key NAME]` and
    `badge join TARGET` (tools/badge/badge/net.py; cli.py only gains three
    hook lines). Remote players are `SocketLink`s from a `ListenSource`, so
    they get the relay's ordering and no-silent-loss rules unchanged.
  - Joiner details beyond the plan: a PING/PONG handshake before a cart
    port opens (tailcat's local end accepts even when the hub is down), a
    heartbeat PING after 3 s of hub silence with the joiner's own PONGs
    filtered out (10 s without an answer drops the link), SIGTERM/SIGHUP act
    as Ctrl-C, and the tailcat child dies with us on Linux (PR_SET_PDEATHSIG).
  - tailcat v0.7.0 quirks found and handled: `tailcat forward` ignores
    SIGTERM (we escalate to SIGKILL); a forward client that had a connection
    open when the server died never reaches the restarted server again, so
    `TailcatTunnel` restarts the forward on every lost hub (at most every 5 s).
  - Tests: 22 in tools/badge/tests/test_net.py (real LobbyServer, FakeCart
    simulators, fake tailcat binary); full suite 127 pass. Opt-in
    `BADGE_TEST_TAILCAT=1` end to end through real tailcat passes.
  - N2 on the VM with real `lobby-demo` simulators (SDL dummy drivers): two
    on the hub + two through `badge join tc...` all in DOTS room 1, 2/4
    frames/s in/out each, path direct. Hub SIGTERM + restart on a saved key:
    the joiner noticed in 13 s, restarted its tunnel, both back in 1 s.
    Joiner SIGTERM: hub logs both leaves. Hub SIGKILL: no tailcat left over.
  - Untested: real badges, two physical computers behind different NATs
    (tailcat via DERP), macOS/Windows joiners.

## Deferred questions (defaults taken)

- Default listen port 7360, just above the simulator range 7341-7356.
- `--tailcat` uses an ephemeral key by default (a new address each run).
- The hub must run the same `badge` version as joiners only for the
  `join` side's own flags; the wire format is plain lobby v1.
