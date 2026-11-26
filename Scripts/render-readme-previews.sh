#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 显式渲染真实 SwiftUI/AppKit 视图；内存夹具不连接硬件、不修改用户偏好。
TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
TESTING_PLUGIN="$TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
test -f "$TESTING_PLUGIN"
swift build --build-tests -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN"
./Scripts/prepare-test-resources.sh
OUTPUT_DIR="$(mktemp -d -t auxmo-readme-render)"
trap 'rm -rf "$OUTPUT_DIR"' EXIT
for language in en zh; do
    AUXMO_RENDER_README=1 AUXMO_README_LANGUAGE="$language" AUXMO_README_OUTPUT_DIR="$OUTPUT_DIR" \
        swift test --skip-build --no-parallel --filter 'ReadmePreviewTests|StatisticsReadmePreviewTests' \
        -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN"
done
# 两种语言都渲染成功后才更新文档资产；临时目录每次新建，不复制上次遗留截图。
mkdir -p docs/images
for language in en zh; do
    for name in hero mixer outputs effects headphones statistics; do
        cp "$OUTPUT_DIR/$language/$name.png" "docs/images/$name-$language.png"
    done
done
