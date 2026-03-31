#!/bin/bash
set -e

# Initialize and update submodules
echo "Initializing submodules..."
git submodule update --init --recursive

# Build binpack-rust
echo "Building binpack-rust..."
cd binpack-rust
cargo build --release --features "ffi"
cd ..

# Remove any old libsfbinpack.so from lc0 directory
echo "Removing old libsfbinpack.so..."
rm -f ./lc0/libsfbinpack.so

# Copy the newly built library to lc0 root
echo "Copying libsfbinpack.so to lc0..."
cp ./binpack-rust/target/release/libsfbinpack.so ./lc0/

# Build lc0 rescorer
echo "Building lc0 rescorer..."
cd lc0
./build.sh release -Drescorer=true
cd ..

echo "Setup completed successfully!"
