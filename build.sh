#!/bin/bash
# Thin wrapper kept for muscle memory; the build itself lives in the Makefile.
set -e
exec make "$@"
