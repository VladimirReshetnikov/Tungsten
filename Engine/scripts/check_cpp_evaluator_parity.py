#!/usr/bin/env python3
"""Compatibility entry point for the native C++ evaluator parity harness."""

from check_rust_evaluator_parity import main


if __name__ == "__main__":
    raise SystemExit(main())
