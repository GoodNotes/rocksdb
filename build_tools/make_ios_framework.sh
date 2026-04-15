#!/usr/bin/env bash

set -e

XCFRAMEWORK_NAME="RocksDB.xcframework"
FRAMEWORK_NAME="RocksDB.framework"
FRAMEWORK_EXECUTABLE_NAME="RocksDB"
FRAMEWORK_MODULE_NAME="RocksDB"

export TARGET_OS=IOS
export USE_RTTI=1

LZ4_VENDOR_DIR="$(pwd)/third_party/lz4/lib"
export CXXFLAGS="-DLZ4 -I${LZ4_VENDOR_DIR}"
export CPLUS_INCLUDE_PATH="${LZ4_VENDOR_DIR}:${CPLUS_INCLUDE_PATH}"

CORES=$(sysctl -n hw.ncpu)

if [[ "${SKIP_STATIC_BUILD:-0}" != "1" ]]; then
    rm iphonedevice-librocksdb.a || true
    rm iphonesimulator-librocksdb.a || true
    rm maccatalyst-librocksdb.a || true
    rm iphonedevice/librocksdb.a || true
    rm iphonesimulator/librocksdb.a || true
    rm maccatalyst/librocksdb.a || true
    make static_lib -j${CORES}
fi

# Create filtered include directory without Lua and C API headers
echo "Creating filtered include directory (excluding Lua and C API)..."
rm -rf include_filtered || true
mkdir -p include_filtered/rocksdb
rsync -av --exclude='lua' --exclude='c.h' include/rocksdb/ include_filtered/rocksdb/
cp include/module.modulemap include_filtered/

rm -rf "${XCFRAMEWORK_NAME}" || true
make xcframework FILTERED_INCLUDES=1

build_lz4_static_lib() {
    local triple="$1"
    local sdk_path="$2"
    local output_archive="$3"
    local object_dir="${output_archive%.a}.objs"

    rm -rf "${object_dir}"
    mkdir -p "${object_dir}"

    for source_name in lz4.c lz4hc.c lz4frame.c xxhash.c; do
        clang -c "${LZ4_VENDOR_DIR}/${source_name}" \
            -O2 \
            -fPIC \
            -target "${triple}" \
            -isysroot "${sdk_path}" \
            -I"${LZ4_VENDOR_DIR}" \
            -o "${object_dir}/${source_name%.c}.o"
    done

    libtool -static -o "${output_archive}" "${object_dir}"/*.o
}

build_framework_binary() {
    local slice_dir="$1"
    local output_path="$2"
    local sdk_path="$3"
    shift 3
    local triples=("$@")
    local slice_name
    local rocksdb_archive="${slice_dir}/librocksdb.a"
    local build_dir="${slice_dir}/.framework-build"
    local dylibs=()

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    for triple in "${triples[@]}"; do
        local arch="${triple%%-*}"
        local arch_rocksdb_archive="${build_dir}/librocksdb-${arch}.a"
        local arch_lz4_archive="${build_dir}/liblz4-${arch}.a"
        local arch_dylib="${build_dir}/RocksDB-${arch}.dylib"

        if lipo -info "${rocksdb_archive}" | grep -q "Non-fat file"; then
            cp "${rocksdb_archive}" "${arch_rocksdb_archive}"
        else
            lipo -extract "${arch}" "${rocksdb_archive}" -output "${arch_rocksdb_archive}"
        fi
        build_lz4_static_lib "${triple}" "${sdk_path}" "${arch_lz4_archive}"

        clang++ -dynamiclib \
            -target "${triple}" \
            -isysroot "${sdk_path}" \
            -install_name "@rpath/${FRAMEWORK_NAME}/${FRAMEWORK_EXECUTABLE_NAME}" \
            -Wl,-all_load,"${arch_rocksdb_archive}" \
            "${arch_lz4_archive}" \
            -lc++ \
            -o "${arch_dylib}"

        dylibs+=("${arch_dylib}")
    done

    if [[ ${#dylibs[@]} -eq 1 ]]; then
        cp "${dylibs[0]}" "${output_path}"
    else
        lipo -create "${dylibs[@]}" -output "${output_path}"
    fi
}

write_framework_info_plist() {
    local framework_dir="$1"
    local minimum_os_version="$2"
    local sdk_name="$3"

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
    <key>DTSDKName</key>
    <string>${sdk_name}</string>
    <key>MinimumOSVersion</key>
    <string>${minimum_os_version}</string>
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
    local minimum_os_version="$5"
    local sdk_name="$6"

    mkdir -p "${current_headers_dir}" "${current_modules_dir}" "${resources_dir}"

    mv "${headers_dir}/rocksdb" "${current_headers_dir}/rocksdb"
    mv "${modules_dir}/module.modulemap" "${current_modules_dir}/module.modulemap"
    mv "${executable_path}" "${current_dir}/${FRAMEWORK_EXECUTABLE_NAME}"

    write_framework_info_plist "${resources_dir}" "${minimum_os_version}" "${sdk_name}"

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
    minimum_os_version="15.0"

    case "$(basename "${slice}")" in
        *maccatalyst*)
            sdk_name="macosx$(xcrun --sdk macosx --show-sdk-version)"
            sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
            triples=("arm64-apple-ios15.0-macabi" "x86_64-apple-ios15.0-macabi")
            ;;
        *simulator*)
            sdk_name="iphonesimulator$(xcrun --sdk iphonesimulator --show-sdk-version)"
            sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            triples=("arm64-apple-ios15.0-simulator" "x86_64-apple-ios15.0-simulator")
            ;;
        *)
            sdk_name="iphoneos$(xcrun --sdk iphoneos --show-sdk-version)"
            sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
            triples=("arm64-apple-ios15.0")
            ;;
    esac

    rm -rf "${framework_dir}"
    mkdir -p "${headers_dir}" "${modules_dir}"

    build_framework_binary "${slice}" "${executable_path}" "${sdk_path}" "${triples[@]}"
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
        create_versioned_framework_layout "${framework_dir}" "${headers_dir}" "${modules_dir}" "${executable_path}" "${minimum_os_version}" "${sdk_name}"
    else
        write_framework_info_plist "${framework_dir}" "${minimum_os_version}" "${sdk_name}"
    fi
    rm -rf "${slice}/Headers" "${slice}/librocksdb.a" "${slice}/.framework-build"
done

for index in 0 1 2; do
    /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${index}:BinaryPath ${FRAMEWORK_NAME}/${FRAMEWORK_EXECUTABLE_NAME}" "${XCFRAMEWORK_NAME}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:${index}:LibraryPath ${FRAMEWORK_NAME}" "${XCFRAMEWORK_NAME}/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${index}:HeadersPath" "${XCFRAMEWORK_NAME}/Info.plist" || true
done
