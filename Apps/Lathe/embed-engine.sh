#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$SRCROOT/../.." && pwd)
case "$CONFIGURATION" in
    Release) package_configuration=release ;;
    *) package_configuration=debug ;;
esac

if [ -n "${LATHE_ENGINE_BINARY:-}" ]; then
    engine_binary=$LATHE_ENGINE_BINARY
else
    package_scratch="$repository_root/.build/xcode-helper"
    env -u SDKROOT -u SWIFT_EXEC xcrun swift build \
        --package-path "$repository_root/Packages/LatheKit" \
        --scratch-path "$package_scratch" \
        --configuration "$package_configuration" --product lathe-engine
    package_bin=$(env -u SDKROOT -u SWIFT_EXEC xcrun swift build \
        --package-path "$repository_root/Packages/LatheKit" \
        --scratch-path "$package_scratch" \
        --configuration "$package_configuration" --show-bin-path)
    engine_binary="$package_bin/lathe-engine"
fi

if [ ! -x "$engine_binary" ]; then
    echo "error: lathe-engine executable missing: $engine_binary" >&2
    exit 1
fi

helper_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helper_directory"
cp "$engine_binary" "$helper_directory/lathe-engine"
chmod 755 "$helper_directory/lathe-engine"
/usr/bin/codesign --force --sign - "$helper_directory/lathe-engine"
