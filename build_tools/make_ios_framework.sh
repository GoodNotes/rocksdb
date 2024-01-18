#/usr/bin/env bash

set -e

export TARGET_OS=IOS
export USE_RTTI=1

export CXXFLAGS=-DLZ4
export LIBRARY_PATH=/usr/local/lib:$LIBRARY_PATH
export CPLUS_INCLUDE_PATH=/usr/local/include:$CPLUS_INCLUDE_PATH

CORES=$(sysctl -n hw.ncpu)

if ! brew list lz4 &>/dev/null; then
    echo "LZ4 not installed. Installing via Homebrew..."
    brew install lz4
fi

rm iphonedevice-librocksdb.a || true
rm iphonesimulator-librocksdb.a || true
rm maccatalyst-librocksdb.a || true
make static_lib -j${CORES}

rm -rf RocksDB.xcframework || true
make xcframework

