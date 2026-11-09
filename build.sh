#!/bin/sh
# Ad-hoc signing with the virtualization entitlement, no paid Apple account involved.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
go build -o bin/crateyardd ./cmd/crateyardd
codesign --force --sign - --entitlements crateyardd.entitlements bin/crateyardd
