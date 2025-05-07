#!/bin/bash
set -e  # Exit on any error

echo "🚀 Building universal binary for imessagedump..."

# Ensure we have the x86_64 target
echo "📦 Adding x86_64 target..."
rustup target add x86_64-apple-darwin

# Clean previous builds
echo "🧹 Cleaning previous builds..."
cargo clean

# Build for ARM64 (native)
echo "🔨 Building for ARM64..."
cargo build --release

# Build for x86_64
echo "🔨 Building for x86_64..."
cargo build --release --target x86_64-apple-darwin

# Create universal binary
echo "🔗 Creating universal binary..."
lipo -create \
    target/release/imessagedump \
    target/x86_64-apple-darwin/release/imessagedump \
    -output target/release/imessagedump-universal

# Verify the universal binary
echo "✅ Verifying universal binary..."
file target/release/imessagedump-universal

echo "✨ Done! Universal binary created at: target/release/imessagedump-universal"
