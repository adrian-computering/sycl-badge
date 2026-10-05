#!/usr/bin/env python3
"""Run the badge tool without installing: python3 tools/badge/badge.py ..."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from badge.cli import main  # noqa: E402  (the package next to this file)

if __name__ == "__main__":
    sys.exit(main())
