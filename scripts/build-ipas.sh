#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'Building a device IPA requires macOS with Xcode and the iPhoneOS SDK.' >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/build"
project_path="$repo_dir/PersonalSigner.xcodeproj"
resolved_path="$project_path/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
test -s "$resolved_path"
bash "$repo_dir/scripts/fetch-build-dependencies.sh"
mkdir -p "$build_dir/ipas"

build_ipa() {
  local target="$1" version="$2" output="$3"
  local derived="$build_dir/$target-$version"
  local application_path="$derived/Build/Products/Release-iphoneos/$target.app"
  local staging_path

  xcodebuild -project "$project_path" -scheme "$target" \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$build_dir/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    CURRENT_PROJECT_VERSION="$version" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

  xcrun lipo -verify_arch arm64 "$application_path/$target"
  test ! -e "$application_path/embedded.mobileprovision"
  test ! -e "$application_path/_CodeSignature/CodeResources"
  staging_path="$(mktemp -d "$build_dir/package.XXXXXX")"
  (
    trap 'rm -rf -- "$staging_path"' EXIT
    mkdir -p "$staging_path/Payload"
    ditto --norsrc "$application_path" "$staging_path/Payload/$target.app"
    ditto -c -k --norsrc --keepParent "$staging_path/Payload" "$staging_path/unsigned.ipa"
    unzip -tq "$staging_path/unsigned.ipa"
    mv -f -- "$staging_path/unsigned.ipa" "$build_dir/ipas/$output"
  )
}

build_ipa PersonalSigner 3 PersonalSigner-proof-unsigned.ipa
build_ipa StorageProbe 1 StorageProbe-build-1-unsigned.ipa
build_ipa StorageProbe 2 StorageProbe-build-2-unsigned.ipa

(
  cd "$build_dir/ipas"
  shasum -a 256 ./*.ipa > SHA256SUMS
)
python3 "$repo_dir/scripts/verify-ipas.py" "$build_dir/ipas"
