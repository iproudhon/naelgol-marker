#!/bin/bash
# Put TensorFlow Lite's xcframeworks in TFLite/Vendor/.
#
# They are 171 MB and are NOT in git. Everything else about this package is, so a
# fresh clone builds after running this once.
#
# There is no official Swift Package Manager distribution of TensorFlow Lite —
# CocoaPods or Bazel, and a pod cannot be consumed from inside a package — but the
# pod *contains* xcframeworks, which is exactly what `.binaryTarget` wants. So the
# supported route is: install the pod once, anywhere, and copy three directories.
#
#   ./fetch-tflite.sh                     # pod install into a temp dir (needs CocoaPods)
#   ./fetch-tflite.sh --from ~/src/vipl   # copy from a checkout that already has Pods/
#
# The version is PINNED. vipl runs 0.0.1-nightly.20221227 and naelvol's keypoints
# are gated against vipl's, so bumping this is a measurement with a before and an
# after — see docs/plan-naelvol.md §6.
set -euo pipefail

VERSION="${NAELVOL_TFLITE_VERSION:-0.0.1-nightly.20221227}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$HERE/Vendor"
FRAMEWORKS=(TensorFlowLiteC TensorFlowLiteCCoreML TensorFlowLiteCMetal)

from=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) from="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "usage: $0 [--from <dir with Pods/>] [--version <pod version>]" >&2; exit 2 ;;
    esac
done

copy_from() {
    local src="$1"
    for f in "${FRAMEWORKS[@]}"; do
        if [ ! -d "$src/$f.xcframework" ]; then
            echo "missing $src/$f.xcframework" >&2
            return 1
        fi
    done
    mkdir -p "$VENDOR"
    for f in "${FRAMEWORKS[@]}"; do
        rm -rf "$VENDOR/$f.xcframework"
        cp -R "$src/$f.xcframework" "$VENDOR/"
    done
}

if [ -n "$from" ]; then
    copy_from "$from/Pods/TensorFlowLiteC/Frameworks"
else
    command -v pod >/dev/null || { echo "CocoaPods not installed; use --from <dir with Pods/>" >&2; exit 1; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/Podfile" <<PODFILE
platform :ios, '16.0'
target 'Fetch' do
  use_frameworks!
  pod 'TensorFlowLiteSwift', '$VERSION', :subspecs => ['CoreML', 'Metal']
end
PODFILE
    ( cd "$tmp" && pod install --no-repo-update >/dev/null )
    copy_from "$tmp/Pods/TensorFlowLiteC/Frameworks"
fi

# **Write an Info.plist into every framework slice.** The pod ships these as
# *static* frameworks with no Info.plist — CocoaPods handles that itself — and
# Xcode refuses a binary target whose framework has none:
#   "Framework .../TensorFlowLiteC.framework did not contain an Info.plist"
# The binary is a Mach-O object, so the linker still links it statically and what
# lands in the app bundle is a 40 KB stub, not 65 MB.
for f in "${FRAMEWORKS[@]}"; do
    for slice in "$VENDOR/$f.xcframework"/*/; do
        fw="$slice$f.framework"
        [ -d "$fw" ] || continue
        cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$f</string>
	<key>CFBundleIdentifier</key><string>org.tensorflow.$f</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$f</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>12.0</string>
</dict>
</plist>
PLIST
    done
done

# Report what landed. The **slices** are the thing to look at: these carry
# ios-arm64 and the iOS simulator and NO macOS slice, which is the whole reason
# this package is separate from `Naelvol`.
for f in "${FRAMEWORKS[@]}"; do
    printf '%s  %s\n' "$(du -sh "$VENDOR/$f.xcframework" | cut -f1)" "$f"
    /usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$VENDOR/$f.xcframework/Info.plist" \
        | grep -E 'LibraryIdentifier' | sed 's/^/    /'
done
