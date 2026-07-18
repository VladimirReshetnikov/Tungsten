#!/usr/bin/env python3
"""Compatibility entry point for the native C++ parser parity harness."""

from check_rust_parser_parity import main


if __name__ == "__main__":
    raise SystemExit(main())
