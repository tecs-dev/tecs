#!/bin/bash
set -e

echo "Building Teal files..."
cyan build

echo "Copying assets..."
cp -r assets build/ 2>/dev/null || true

echo "Build complete! Run with: love build"