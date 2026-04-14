#!/usr/bin/env bash

set -e

XCFRAMEWORK_NAME="RocksDB.xcframework"
FRAMEWORK_NAME="RocksDB.framework"
FRAMEWORK_EXECUTABLE_NAME="RocksDB"
FRAMEWORK_MODULE_NAME="RocksDB"

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
rm iphonedevice/librocksdb.a || true
rm iphonesimulator/librocksdb.a || true
rm maccatalyst/librocksdb.a || true
make static_lib -j${CORES}

# Create filtered include directory without Lua and C API headers
echo "Creating filtered include directory (excluding Lua and C API)..."
rm -rf include_filtered || true
mkdir -p include_filtered/rocksdb
rsync -av --exclude='lua' --exclude='c.h' include/rocksdb/ include_filtered/rocksdb/
cp include/module.modulemap include_filtered/

rm -rf "${XCFRAMEWORK_NAME}" || true
make xcframework FILTERED_INCLUDES=1

write_framework_info_plist() {
    local framework_dir="$1"

    cat > "${framework_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.goodnotes.${FRAMEWORK_MODULE_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_MODULE_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
}

create_versioned_framework_layout() {
    local framework_dir="$1"
    local headers_dir="$2"
    local modules_dir="$3"
    local executable_path="$4"

    local versions_dir="${framework_dir}/Versions"
    local current_dir="${versions_dir}/A"
    local resources_dir="${current_dir}/Resources"
    local current_headers_dir="${current_dir}/Headers"
    local current_modules_dir="${current_dir}/Modules"

    mkdir -p "${current_headers_dir}" "${current_modules_dir}" "${resources_dir}"

    mv "${headers_dir}/rocksdb" "${current_headers_dir}/rocksdb"
    mv "${modules_dir}/module.modulemap" "${current_modules_dir}/module.modulemap"
    mv "${executable_path}" "${current_dir}/${FRAMEWORK_EXECUTABLE_NAME}"

    write_framework_info_plist "${resources_dir}"

    rm -rf "${headers_dir}" "${modules_dir}"
    ln -sf A "${versions_dir}/Current"
    ln -sf "Versions/Current/Headers" "${framework_dir}/Headers"
    ln -sf "Versions/Current/Modules" "${framework_dir}/Modules"
    ln -sf "Versions/Current/Resources" "${framework_dir}/Resources"
    ln -sf "Versions/Current/${FRAMEWORK_EXECUTABLE_NAME}" "${framework_dir}/${FRAMEWORK_EXECUTABLE_NAME}"
}

echo "Rewriting XCFramework slices as frameworks to avoid ProcessXCFramework collisions..."
for slice in "${XCFRAMEWORK_NAME}"/*; do
    if [[ ! -d "${slice}" ]] || [[ "$(basename "${slice}")" == "Info.plist" ]]; then
        continue
    fi

    framework_dir="${slice}/${FRAMEWORK_NAME}"
    headers_dir="${framework_dir}/Headers"
    modules_dir="${framework_dir}/Modules"
    executable_path="${framework_dir}/${FRAMEWORK_EXECUTABLE_NAME}"

    rm -rf "${framework_dir}"
    mkdir -p "${headers_dir}/rocksdb" "${modules_dir}"

    mv "${slice}/librocksdb.a" "${executable_path}"
    if [[ -d "${slice}/Headers/rocksdb/rocksdb" ]]; then
        mv "${slice}/Headers/rocksdb/rocksdb" "${headers_dir}/rocksdb"
    else
        mv "${slice}/Headers/rocksdb" "${headers_dir}/rocksdb"
    fi

    find "${headers_dir}/rocksdb" -type f \( -name '*.h' -o -name '*.hpp' \) -print0 | \
        xargs -0 perl -0pi -e 's{([#]include\s*[<"])rocksdb/}{$1RocksDB/rocksdb/}g'

    cat > "${modules_dir}/module.modulemap" <<EOF
framework module ${FRAMEWORK_MODULE_NAME} {
  umbrella "../Headers/rocksdb"
  export *
  module * { export * }
}
EOF

    if [[ "$(basename "${slice}")" == *"maccatalyst"* ]]; then
        create_versioned_framework_layout "${framework_dir}" "${headers_dir}" "${modules_dir}" "${executable_path}"
    else
        write_framework_info_plist "${framework_dir}"
    fi
    rm -rf "${slice}/Headers"
done

for index in 0 1 2; do
    /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${index}:BinaryPath ${FRAMEWORK_NAME}/${FRAMEWORK_EXECUTABLE_NAME}" "${XCFRAMEWORK_NAME}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${index}:LibraryPath ${FRAMEWORK_NAME}" "${XCFRAMEWORK_NAME}/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${index}:HeadersPath" "${XCFRAMEWORK_NAME}/Info.plist" || true
done
