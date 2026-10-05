# About this fork

This is a fork of [ZigEmbeddedGroup/sycl-badge](https://github.com/ZigEmbeddedGroup/sycl-badge)
that adds a few OS features ahead of upstream. It tracks upstream `main`
closely: everything upstream ships lands here too, usually within a day.
Carts built for upstream run unchanged on this firmware, and carts that use
fork features detect stock firmware at run time and degrade gracefully.

## What the fork adds

| Feature | Branch | Status | Docs |
|---|---|---|---|
| USB serial console (restores the console and `cart.trace()` output over USB, lost in upstream #136) | `feature/usb-console` | merged | below |
| Cart serial port and multiplayer lobby (`cart.serial`, `cart.lobby`, `badge lobby`) | `feature/cart-serial` | merged (untested on hardware) | [fork/CART_SERIAL.md](fork/CART_SERIAL.md) |
| Network lobby (`badge lobby --listen/--tailcat`, `badge join`: badges on different laptops share a lobby over a LAN or the internet via [tailcat](https://github.com/tailscale/tailcat)) | `feature/net-lobby` (on `feature/cart-serial`) | merged (simulator-tested through real tailcat; untested on hardware) | [fork/NET_LOBBY.md](fork/NET_LOBBY.md) |

The USB console comes from Carl Sverre's upstream PRs #159 and #160, merged
as-is so upstream can tell them apart.

## Using the firmware

Build exactly as upstream (`zig build`), then flash
`zig-out/firmware/sycl-os-kernel.uf2`. Carts on the badge survive a firmware
update. The first time, on each badge: hold `BOOT_SEL` and tap `RESET` on the
back of the badge, then copy the UF2 to the `RP2350` drive that appears (the
manual's "Flashing the kernel" section has details). Once a badge runs fork
firmware its console can reboot it into the bootloader, so later updates for
every plugged-in badge are one command:
`badge flash zig-out/firmware/sycl-os-kernel.uf2 --all` (see `tools/badge`).

The console is the "SYCL Badge Console" serial port: `/dev/ttyACM0` or
`/dev/serial/by-id/*SYCL*-if01` on Linux, one of the badge's two
`/dev/cu.usbmodem*` ports on macOS, a COM port on Windows (`badge list` shows
which). Open it with any terminal (`tio`, `screen`, PuTTY) or
`badge console`, and type `help`.

To go back to upstream firmware, flash an upstream build the same way.

## Branches

```
upstream/main ──●──────●───────────●─────────▶  (never modified here)
                 \      \           \
main ─────────────●──────●───────────●───────▶  upstream/main + all features
                 /      /           /
feature/* ──────●──────●───────────●─────────▶  one branch per feature
```

- `main` is what badges run: upstream `main` with every feature branch merged.
- Each feature lives on its own `feature/<name>` branch. A feature branch is
  based on upstream `main` (or on another feature it needs, which the table
  says) and contains only that feature. Features stay separable, so one can be
  dropped once upstream ships its own version.
- History is never rewritten on shared branches. Syncing with upstream is a
  merge, not a rebase.
- Fork-only files live in `fork/`, `tools/badge/`, `FORK.md` and new files
  next to the code they extend. Edits to upstream files are kept small so
  upstream merges rarely conflict.

## Staying in sync with upstream

```sh
git remote add upstream https://github.com/ZigEmbeddedGroup/sycl-badge.git  # once
fork/sync-upstream.sh            # merges upstream/main into every feature branch and main,
                                 # builds and tests each, stops at the first conflict
git push origin main 'feature/*'
```

When a conflict stops the script, resolve it on that branch, commit, and run
the script again; it carries on where it stopped. Resolve conflicts on the
feature branch, not on `main`, so the resolution is reused by every later
merge.

When upstream ships its own version of a feature (for example the USB serial
driver it is working on in `upstream/cdc`), switch the fork to it: merge
upstream, keep upstream's code, re-apply what the fork still needs on top on
the feature branch, and update the table above.

## Adding a feature

1. `git switch -c feature/<name> upstream/main`, and add the branch to
   `IN_PROGRESS` in `fork/sync-upstream.sh` so syncs keep it current.
2. Build it. Keep upstream files' diffs small; put new code in new files.
3. Document it: a section or file under `fork/`, and a row in the table above.
4. When it works: `git switch main && git merge --no-ff feature/<name>`, and
   move the branch from `IN_PROGRESS` to `FEATURES`.

If a feature changes the cart ABI (`src/os/cart/os_abi.zig`), it must take
reserved space only, flag itself in `os_flags`, and keep stock-firmware carts
working. Write down the offsets you used in its doc so other SDKs can follow.
