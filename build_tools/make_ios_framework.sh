#!/usr/bin/env bash

set -e

export TARGET_OS=IOS
export USE_RTTI=1

LZ4_PREFIX=$(brew --prefix lz4)
export CXXFLAGS="-DLZ4 -I${LZ4_PREFIX}/include"
export LIBRARY_PATH="${LZ4_PREFIX}/lib:$LIBRARY_PATH"
export CPLUS_INCLUDE_PATH="${LZ4_PREFIX}/include:$CPLUS_INCLUDE_PATH"

CORES=$(sysctl -n hw.ncpu)

if ! brew list lz4 &>/dev/null; then
    echo "LZ4 not installed. Installing via Homebrew..."
    brew install lz4
fi

rm iphonedevice-librocksdb.a || true
rm iphonesimulator-librocksdb.a || true
rm maccatalyst-librocksdb.a || true
make static_lib -j${CORES}

# Create filtered include directory without Lua and C API headers
echo "Creating filtered include directory (excluding Lua and C API)..."
rm -rf include_filtered || true
mkdir -p include_filtered/rocksdb
rsync -av --exclude='lua' --exclude='c.h' include/rocksdb/ include_filtered/rocksdb/
cp include/module.modulemap include_filtered/

rm -rf RocksDB.xcframework || true
make xcframework FILTERED_INCLUDES=1

