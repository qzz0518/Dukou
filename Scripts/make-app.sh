#!/usr/bin/env bash
# Assemble and sign Dukou.app, with five share extensions nested inside it.
#
# Local development stays fast by building the host architecture and signing
# ad-hoc. A distribution build passes both architectures, a Developer ID hash,
# and DISTRIBUTION=1; the extension is then signed before the app, because a
# signature over a bundle has to cover code that is already final.
set -euo pipefail

CONFIG="${CONFIG:-release}"

# TCC remembers a permission by code signature, so an ad-hoc signature — which
# changes on every build — makes the user re-grant Accessibility after every
# rebuild. A stable Developer ID or Apple Development identity is picked
# automatically when the keychain has one; ad-hoc stays the fallback so a clone
# without any certificate still builds.
select_identity() {
	local found
	for PREFIX in "Developer ID Application:" "Apple Development:"; do
		found="$(security find-identity -v -p codesigning 2>/dev/null \
			| awk -v prefix="$PREFIX" 'index($0, prefix) { print $2; exit }')"
		if [ -n "$found" ]; then
			printf '%s' "$found"
			return
		fi
	done
	printf '%s' '-'
}
IDENTITY="${IDENTITY:-$(select_identity)}"
DISTRIBUTION="${DISTRIBUTION:-0}"
ARCHS="${ARCHS:-$(uname -m)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/share-slots.sh"
source "$ROOT/Scripts/share-targets.sh"
APP="${APP_PATH:-$ROOT/dist/Dukou.app}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/dukou-bundle}"
APP_INFO="$ROOT/Resources/Info.plist"
SHARE_INFO="$ROOT/Resources/Share-Info.plist"
APP_ENTITLEMENTS="$ROOT/Resources/Dukou.entitlements"
SHARE_ENTITLEMENTS="$ROOT/Resources/DukouShare.entitlements"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")}"
# Overriding this retargets both bundles and both entitlement files at once.
# The checked-in default is the only value the source falls back to.
APP_GROUP="${APP_GROUP:-$(/usr/libexec/PlistBuddy -c "Print :DKAppGroupIdentifier" "$APP_INFO")}"

if [ "$DISTRIBUTION" = "1" ] && [ "$IDENTITY" = "-" ]; then
	echo "DISTRIBUTION=1 requires a Developer ID Application identity" >&2
	exit 1
fi

read -r -a ARCH_LIST <<< "$ARCHS"
if [ "${#ARCH_LIST[@]}" -eq 0 ]; then
	echo "ARCHS must contain at least one architecture" >&2
	exit 1
fi

MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_INFO")"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# The Xcode 27 clang hands the linker the deployment target as the SDK
# version, and ld then stamps Dukou as built against macOS 14. 0.1.16 shipped
# that way: macOS ran it in its macOS 14 compatibility mode, in which SwiftUI
# opened the empty `Settings` scene as a window on every launch. Name the real
# SDK explicitly; ld takes the last -platform_version it is given. The same
# fix as Charker's.
LINK_SDK_FLAGS=(
	-Xlinker -platform_version -Xlinker macos
	-Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION"
)

APP_BINARIES=()
SHARE_BINARIES=()
HOST_BINARIES=()
BIN_DIRS=()
for ARCH in "${ARCH_LIST[@]}"; do
	case "$ARCH" in
		arm64|x86_64) ;;
		*) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
	esac
	SCRATCH="$BUILD_ROOT/$ARCH"
	swift build -c "$CONFIG" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --product Dukou "${LINK_SDK_FLAGS[@]}"
	swift build -c "$CONFIG" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --product DukouShare "${LINK_SDK_FLAGS[@]}"
	swift build -c "$CONFIG" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --product DukouShareTargetsHost "${LINK_SDK_FLAGS[@]}"
	BIN_DIR="$(swift build -c "$CONFIG" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --show-bin-path)"
	for PRODUCT in Dukou DukouShare DukouShareTargetsHost; do
		if [ ! -x "$BIN_DIR/$PRODUCT" ]; then
			echo "missing $PRODUCT executable for $ARCH: $BIN_DIR/$PRODUCT" >&2
			exit 1
		fi
		# The SDK version decides which behaviours macOS gives the app, and a
		# wrong one builds, signs and notarizes without complaint.
		LINKED_SDK="$(vtool -show-build "$BIN_DIR/$PRODUCT" | awk '$1 == "sdk" { print $2; exit }')"
		if [ "$LINKED_SDK" != "$SDK_VERSION" ]; then
			echo "$PRODUCT ($ARCH) is linked as SDK ${LINKED_SDK:-unknown}, not the macOS $SDK_VERSION SDK it was built with" >&2
			exit 1
		fi
		if ! lipo -archs "$BIN_DIR/$PRODUCT" | tr ' ' '\n' | grep -Fxq "$ARCH"; then
			echo "$PRODUCT does not contain requested architecture $ARCH" >&2
			exit 1
		fi
	done
	APP_BINARIES+=("$BIN_DIR/Dukou")
	SHARE_BINARIES+=("$BIN_DIR/DukouShare")
	HOST_BINARIES+=("$BIN_DIR/DukouShareTargetsHost")
	BIN_DIRS+=("$BIN_DIR")
done

# Sparkle ships as a universal binary framework, so the copy SwiftPM placed
# beside the first architecture's build serves every architecture requested.
SPARKLE_FRAMEWORK="${BIN_DIRS[0]}/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
	echo "missing embedded framework: $SPARKLE_FRAMEWORK" >&2
	exit 1
fi

# An app extension is entered at NSExtensionMain, not main. If the linker flag
# in Package.swift is ever dropped the appex still builds, still installs, and
# silently never activates — so the entry symbol is a build invariant.
if ! nm -u "${SHARE_BINARIES[0]}" | grep -Fq '_NSExtensionMain'; then
	echo "DukouShare is not linked against _NSExtensionMain; check the -e linker flag" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

lipo -create "${APP_BINARIES[@]}" -output "$APP/Contents/MacOS/Dukou"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
for ARCH in "${ARCH_LIST[@]}"; do
	if ! lipo -archs "$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle" | tr ' ' '\n' | grep -Fxq "$ARCH"; then
		echo "Sparkle.framework is missing requested architecture $ARCH" >&2
		exit 1
	fi
done
# SwiftPM links the framework through @rpath. A shell-assembled app does not
# inherit Xcode's LD_RUNPATH_SEARCH_PATHS, so the conventional location is
# added before any signature is created. Only the app: the extensions never
# link Sparkle.
if ! otool -l "$APP/Contents/MacOS/Dukou" | grep -Fq '@executable_path/../Frameworks'; then
	install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Dukou"
fi
SHARE_BINARY="$BUILD_ROOT/DukouShare"
lipo -create "${SHARE_BINARIES[@]}" -output "$SHARE_BINARY"
HOST_BINARY="$BUILD_ROOT/DukouShareTargetsHost"
lipo -create "${HOST_BINARIES[@]}" -output "$HOST_BINARY"

cp "$APP_INFO" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :DKAppGroupIdentifier $APP_GROUP" "$APP/Contents/Info.plist"

APP_ID="${APP_ID:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO")}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_ID" "$APP/Contents/Info.plist"
APPEX_PATHS=()
SHARE_TARGETS_DIR="$APP/Contents/Resources/ShareTargets"
DIRECT_HELPER_ROOT="$SHARE_TARGETS_DIR/Builtins"
DIRECT_HELPER_APPS=()
mkdir -p "$SHARE_TARGETS_DIR" "$DIRECT_HELPER_ROOT"

# Each direct target is a pre-signed helper app. Its containing app supplies the
# target icon, and its appex carries the target id in Info.plist. Shipping these
# signed templates avoids asking users for a developer certificate at runtime.
for TARGET_ROW in "${DIRECT_SHARE_TARGETS[@]}"; do
	IFS='|' read -r TARGET_KEY TARGET_ID TARGET_DISPLAY TARGET_ICON <<< "$TARGET_ROW"
	HELPER_APP="$DIRECT_HELPER_ROOT/$TARGET_KEY.app"
	HELPER_APPEX="$HELPER_APP/Contents/PlugIns/DukouShareTarget.appex"
	mkdir -p "$HELPER_APP/Contents/MacOS" "$HELPER_APP/Contents/Resources" "$HELPER_APPEX/Contents/MacOS" "$HELPER_APPEX/Contents/Resources"
	cp "$HOST_BINARY" "$HELPER_APP/Contents/MacOS/DukouShareTargetsHost"
	cp "$ROOT/Resources/ShareTargetIcons/$TARGET_ICON" "$HELPER_APP/Contents/Resources/AppIcon.icns"
	printf 'APPL????' > "$HELPER_APP/Contents/PkgInfo"
	cat > "$HELPER_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleDisplayName</key><string>Dukou · $TARGET_DISPLAY</string>
<key>CFBundleExecutable</key><string>DukouShareTargetsHost</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleIdentifier</key><string>$APP_ID.ShareTargetHost.$TARGET_KEY</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Dukou</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>DKDirectTargetKey</key><string>$TARGET_KEY</string>
<key>DKGeneratedShareTargetHost</key><true/>
<key>DKShareTargetOwner</key><string>$APP_ID</string>
<key>DKTargetBundleIdentifier</key><string>$TARGET_ID</string>
<key>DKTargetDisplayName</key><string>$TARGET_DISPLAY</string>
<key>DKTemplateVersion</key><integer>1</integer>
<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
	cp "$SHARE_BINARY" "$HELPER_APPEX/Contents/MacOS/DukouShareTarget"
	cp "$SHARE_INFO" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable DukouShareTarget' "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_ID.ShareTargetHost.$TARGET_KEY.Share" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Send to $TARGET_DISPLAY" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Set :DKShareAction custom' "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :DKHostBundleIdentifier string $APP_ID" "$HELPER_APPEX/Contents/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :DKHostBundleIdentifier $APP_ID" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :DKForwardBundleIdentifier string $TARGET_ID" "$HELPER_APPEX/Contents/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :DKForwardBundleIdentifier $TARGET_ID" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :DKForwardDisplayName string $TARGET_DISPLAY" "$HELPER_APPEX/Contents/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :DKForwardDisplayName $TARGET_DISPLAY" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Add :DKForwardPastesPathOnly bool false' "$HELPER_APPEX/Contents/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c 'Set :DKForwardPastesPathOnly false' "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :DKDirectTargetKey string $TARGET_KEY" "$HELPER_APPEX/Contents/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :DKDirectTargetKey $TARGET_KEY" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$HELPER_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :DKAppGroupIdentifier $APP_GROUP" "$HELPER_APPEX/Contents/Info.plist"
	DIRECT_HELPER_APPS+=("$HELPER_APP")
	APPEX_PATHS+=("$HELPER_APPEX")
done

# One executable, five bundles. The extensions differ only in identity, so
# copying the same binary keeps them honestly identical and keeps the build to a
# single compile.
for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
	IFS='|' read -r SLOT APPEX_NAME ID_SUFFIX SLOT_ACTION DISPLAY_NAME <<< "$SLOT_ROW"
	SLOT_APPEX="$APP/Contents/PlugIns/$APPEX_NAME.appex"
	mkdir -p "$SLOT_APPEX/Contents/MacOS" "$SLOT_APPEX/Contents/Resources"
	cp "$SHARE_BINARY" "$SLOT_APPEX/Contents/MacOS/$APPEX_NAME"
	cp "$SHARE_INFO" "$SLOT_APPEX/Contents/Info.plist"

	PLIST="$SLOT_APPEX/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APPEX_NAME" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_ID.$ID_SUFFIX" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :DKShareAction $SLOT_ACTION" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
	/usr/libexec/PlistBuddy -c "Set :DKAppGroupIdentifier $APP_GROUP" "$PLIST"

	SLOT_LOCALIZATIONS="$ROOT/Resources/ShareLocalizations/$SLOT"
	if [ ! -d "$SLOT_LOCALIZATIONS" ]; then
		echo "missing localizations for share slot $SLOT: $SLOT_LOCALIZATIONS" >&2
		exit 1
	fi
	APPEX_PATHS+=("$SLOT_APPEX")
done

# Entitlements are copied and rewritten rather than edited in place: a build
# with APP_GROUP set must not leave the repository's files modified.
BUILT_ENTITLEMENTS="$BUILD_ROOT/entitlements"
mkdir -p "$BUILT_ENTITLEMENTS"
for PAIR in "Dukou:$APP_ENTITLEMENTS" "DukouShare:$SHARE_ENTITLEMENTS"; do
	NAME="${PAIR%%:*}"
	SOURCE="${PAIR#*:}"
	cp "$SOURCE" "$BUILT_ENTITLEMENTS/$NAME.entitlements"
	/usr/libexec/PlistBuddy -c \
		"Set :com.apple.security.application-groups:0 $APP_GROUP" \
		"$BUILT_ENTITLEMENTS/$NAME.entitlements"
done

# Bundle.main must own localisations. SwiftPM's Bundle.module points back into
# the build directory and does not survive a standalone .app distribution. The
# extension needs its own copy: it is a separate bundle with a separate
# Bundle.main.
shopt -s nullglob
for LPROJ in "$ROOT/Resources/Localizations"/*.lproj; do
	ditto "$LPROJ" "$APP/Contents/Resources/$(basename "$LPROJ")"
done
for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
	IFS='|' read -r SLOT APPEX_NAME _ _ _ <<< "$SLOT_ROW"
	SLOT_APPEX="$APP/Contents/PlugIns/$APPEX_NAME.appex"
	for LPROJ in "$ROOT/Resources/Localizations"/*.lproj; do
		ditto "$LPROJ" "$SLOT_APPEX/Contents/Resources/$(basename "$LPROJ")"
	done
	# The entry's name in the Share menu comes from the appex's own
	# InfoPlist.strings, so this deliberately overwrites the app's copy of that
	# one table inside each extension bundle.
	for LPROJ in "$ROOT/Resources/ShareLocalizations/$SLOT"/*.lproj; do
		ditto "$LPROJ" "$SLOT_APPEX/Contents/Resources/$(basename "$LPROJ")"
	done
done
for TARGET_ROW in "${DIRECT_SHARE_TARGETS[@]}"; do
	IFS='|' read -r TARGET_KEY _ TARGET_DISPLAY _ <<< "$TARGET_ROW"
	HELPER_APPEX="$DIRECT_HELPER_ROOT/$TARGET_KEY.app/Contents/PlugIns/DukouShareTarget.appex"
	for LPROJ in "$ROOT/Resources/Localizations"/*.lproj; do
		ditto "$LPROJ" "$HELPER_APPEX/Contents/Resources/$(basename "$LPROJ")"
	done
	mkdir -p "$HELPER_APPEX/Contents/Resources/zh-Hans.lproj" "$HELPER_APPEX/Contents/Resources/en.lproj"
	cat > "$HELPER_APPEX/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<EOF
"CFBundleDisplayName" = "发给 $TARGET_DISPLAY";
"CFBundleName" = "Dukou";
EOF
	cat > "$HELPER_APPEX/Contents/Resources/en.lproj/InfoPlist.strings" <<EOF
"CFBundleDisplayName" = "Send to $TARGET_DISPLAY";
"CFBundleName" = "Dukou";
EOF
done
shopt -u nullglob

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
ditto "$ROOT/Resources/Licenses" "$APP/Contents/Resources/Licenses"

# Repository fallbacks are useful for `swift run`, but a distributable binary
# must never reveal the builder's absolute checkout path.
if [ "$CONFIG" = "release" ]; then
	RELEASE_BINARIES=(
		"$APP/Contents/MacOS/Dukou"
	)
	for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
		IFS='|' read -r _ APPEX_NAME _ _ _ <<< "$SLOT_ROW"
		RELEASE_BINARIES+=("$APP/Contents/PlugIns/$APPEX_NAME.appex/Contents/MacOS/$APPEX_NAME")
	done
	for TARGET_ROW in "${DIRECT_SHARE_TARGETS[@]}"; do
		IFS='|' read -r TARGET_KEY _ _ _ <<< "$TARGET_ROW"
		RELEASE_BINARIES+=(
			"$DIRECT_HELPER_ROOT/$TARGET_KEY.app/Contents/MacOS/DukouShareTargetsHost"
			"$DIRECT_HELPER_ROOT/$TARGET_KEY.app/Contents/PlugIns/DukouShareTarget.appex/Contents/MacOS/DukouShareTarget"
		)
	done
	for BINARY in "${RELEASE_BINARIES[@]}"; do
		if strings "$BINARY" | grep -Fq "$ROOT"; then
			echo "release binary contains the absolute repository path: $BINARY" >&2
			exit 1
		fi
	done
fi

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$DISTRIBUTION" = "1" ]; then
	SIGN_FLAGS+=(--options runtime --timestamp)
fi

# Inside out. Signing the app first would seal a hash of unsigned nested code,
# and codesign --deep is not a substitute for signing it explicitly. Sparkle
# carries executable code several levels below the framework; Downloader.xpc
# keeps its upstream entitlement metadata, everything else gets a fresh
# signature.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/Current"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VERSION/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_VERSION/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE"
for SLOT_APPEX in "${APPEX_PATHS[@]}"; do
	codesign "${SIGN_FLAGS[@]}" --entitlements "$BUILT_ENTITLEMENTS/DukouShare.entitlements" "$SLOT_APPEX"
done
for HELPER_APP in "${DIRECT_HELPER_APPS[@]}"; do
	codesign "${SIGN_FLAGS[@]}" "$HELPER_APP"
done
codesign "${SIGN_FLAGS[@]}" --entitlements "$BUILT_ENTITLEMENTS/Dukou.entitlements" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

# The single most common way this bundle breaks is the two halves drifting onto
# different app groups, which produces an app that receives nothing and no error
# anywhere. Read it back out of the signatures, not out of the source files.
# PlistBuddy rather than `plutil -extract`: its key paths are colon-separated,
# so an entitlement key full of dots does not have to be escaped.
signed_app_group() {
	local dump
	dump="$(mktemp "$BUILD_ROOT/entitlements.XXXXXX.plist")"
	codesign -d --entitlements - --xml "$1" 2>/dev/null > "$dump"
	/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$dump"
	rm -f "$dump"
}
APP_GROUP_SIGNED="$(signed_app_group "$APP")"
if [ "$APP_GROUP_SIGNED" != "$APP_GROUP" ]; then
	echo "signed app group for the app is $APP_GROUP_SIGNED, expected $APP_GROUP" >&2
	exit 1
fi
for SLOT_APPEX in "${APPEX_PATHS[@]}"; do
	SHARE_GROUP_SIGNED="$(signed_app_group "$SLOT_APPEX")"
	if [ "$SHARE_GROUP_SIGNED" != "$APP_GROUP" ]; then
		echo "signed app group for $(basename "$SLOT_APPEX") is $SHARE_GROUP_SIGNED, expected $APP_GROUP" >&2
		exit 1
	fi
done

echo "built $APP"
echo "version $VERSION ($BUILD_NUMBER)"
echo "app group $APP_GROUP"
echo "share entries ${#SHARE_SLOTS[@]}"
echo "direct target templates ${#DIRECT_SHARE_TARGETS[@]}"
echo "architectures $(lipo -archs "$APP/Contents/MacOS/Dukou")"
if [ "$DISTRIBUTION" = "1" ]; then
	echo "signed for Developer ID distribution"
elif [ "$IDENTITY" = "-" ]; then
	echo "signed ad-hoc — macOS will ask for Accessibility again after each rebuild"
else
	echo "signed with a stable identity, so granted permissions survive a rebuild"
fi
