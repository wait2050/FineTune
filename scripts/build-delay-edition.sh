#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
xcodebuild build \
    -project "$PROJECT_DIR/FineTune.xcodeproj" \
    -scheme FineTune -configuration Release \
    -IDEPackageEnablePrebuilts=NO \
    -derivedDataPath "$PROJECT_DIR/build/DelayDerivedData" \
    -clonedSourcePackagesDirPath "$PROJECT_DIR/build/DerivedData/SourcePackages" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    PRODUCT_BUNDLE_IDENTIFIER=com.finetuneapp.FineTune.Delay \
    INFOPLIST_KEY_CFBundleDisplayName="FineTune Delay" \
    MARKETING_VERSION=1.9.0 \
    FINETUNE_URL_SCHEME=finetune-delay

# Never replace a running executable in place. Its mapped code/signature may still
# be in use while the user is listening; build first, then package after quitting.
if pgrep -f "^$PROJECT_DIR/build/FineTune Delay.app/Contents/MacOS/FineTune$" >/dev/null; then
    printf '\nBuild complete. Quit FineTune Delay, then re-run this script to package the update.\n' >&2
    exit 1
fi

ditto "$PROJECT_DIR/build/DelayDerivedData/Build/Products/Release/FineTune.app" \
      "$PROJECT_DIR/build/FineTune Delay.app"
printf '\nBuilt: %s\n' "$PROJECT_DIR/build/FineTune Delay.app"
ditto -c -k --sequesterRsrc --keepParent "$PROJECT_DIR/build/FineTune Delay.app" \
      "$PROJECT_DIR/build/FineTune-Delay-macOS.zip"
