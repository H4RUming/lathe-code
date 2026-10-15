#!/bin/bash
set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
configuration=debug
output_directory="$repository_root/.build/macos"
package_scratch="$repository_root/.build/native-package"
derived_data="$repository_root/.build/native-app"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) configuration="$2"; shift 2 ;;
        --output) output_directory="$2"; shift 2 ;;
        --scratch-path) package_scratch="$2"; shift 2 ;;
        --derived-data-path) derived_data="$2"; shift 2 ;;
        --help)
            echo "Usage: Scripts/build-app.sh [--configuration debug|release] [--output directory] [--scratch-path directory] [--derived-data-path directory]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$configuration" in
    debug) xcode_configuration=Debug ;;
    release) xcode_configuration=Release ;;
    *) echo "Configuration must be debug or release" >&2; exit 2 ;;
esac

mkdir -p "$output_directory"
output_directory=$(cd -- "$output_directory" && pwd)
swift build --package-path "$repository_root/Packages/LatheKit" \
    --scratch-path "$package_scratch" --configuration "$configuration" --product lathe-engine
swift build --package-path "$repository_root/Packages/LatheKit" \
    --scratch-path "$package_scratch" --configuration "$configuration" --product lathe
package_bin=$(swift build --package-path "$repository_root/Packages/LatheKit" \
    --scratch-path "$package_scratch" --configuration "$configuration" --show-bin-path)

xcodebuild -project "$repository_root/Apps/Lathe/Lathe.xcodeproj" \
    -scheme Lathe -configuration "$xcode_configuration" -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    "LATHE_ENGINE_BINARY=$package_bin/lathe-engine" build

ditto "$derived_data/Build/Products/$xcode_configuration/Lathe.app" "$output_directory/Lathe.app"
cp "$package_bin/lathe" "$output_directory/lathe"
cp "$package_bin/lathe-engine" "$output_directory/lathe-engine"
codesign --verify --deep --strict "$output_directory/Lathe.app"
echo "Built app: $output_directory/Lathe.app"
echo "Built CLI: $output_directory/lathe"
