#!/usr/bin/env python3
"""Compatibility entry point for the native C++ stateful parity harness."""

from check_rust_stateful_evaluator_parity import main


if __name__ == "__main__":
    raise SystemExit(main())
