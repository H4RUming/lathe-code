#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$SRCROOT/../.." && pwd)
case "$CONFIGURATION" in
    Release) package_configuration=release ;;
    *) package_configuration=debug ;;
esac

if [ -n "${LATHE_RUNNER_BINARY:-}" ]; then
    runner_binary=$LATHE_RUNNER_BINARY
else
    package_scratch="$repository_root/.build/xcode-helper"
    env -u SDKROOT -u SWIFT_EXEC xcrun swift build \
        --package-path "$repository_root/Packages/LatheKit" \
        --scratch-path "$package_scratch" \
        --configuration "$package_configuration" --product lathe-runner
    package_bin=$(env -u SDKROOT -u SWIFT_EXEC xcrun swift build \
        --package-path "$repository_root/Packages/LatheKit" \
        --scratch-path "$package_scratch" \
        --configuration "$package_configuration" --show-bin-path)
    runner_binary="$package_bin/lathe-runner"
fi

helper_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helper_directory"
# Clean the daemon helper from an incremental build of an older app version.
rm -f "$helper_directory/lathe-engine"
if [ ! -x "$runner_binary" ]; then
    echo "error: lathe-runner executable missing: $runner_binary" >&2
    exit 1
fi
cp "$runner_binary" "$helper_directory/lathe-runner"
chmod 755 "$helper_directory/lathe-runner"
/usr/bin/codesign --force --sign - "$helper_directory/lathe-runner"
