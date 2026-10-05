"""Host tool for SYCL badges: discovery, console, cart serial, flashing,
cart install and the multiplayer lobby. See tools/badge/README.md.

Reusable modules: frames (COBS + lobby protocol v1 messages), discover
(badges, ports, drives, simulators), links (serial / TCP byte streams),
lobby (the relay), flash (UF2 checks and drive copies).
"""

__version__ = "0.1.0"
