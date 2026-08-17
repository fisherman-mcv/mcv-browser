.PHONY: build run release app dmg clean

UPDATE_FEED_URL ?= https://raw.githubusercontent.com/fisherman-mcv/mcv-browser/main/appcast.xml
UPDATE_PUBLIC_KEY ?= PRvV5jR0eJT7ojMGKHKxaGWVgewRy6iJGKJZDdIlUW8=
VERSION ?= 1.0.0
BUILD_NUMBER ?= 1

build:
	swift build

run: build
	.build/debug/MCV

release:
	swift build -c release
	@echo "→ бінарник: .build/release/MCV"

# Збирає повноцінний MCV Browser.app для перетягування в /Applications
app: release
	rm -rf "MCV Browser.app"
	mkdir -p "MCV Browser.app/Contents/MacOS" "MCV Browser.app/Contents/Resources" "MCV Browser.app/Contents/Frameworks"
	cp Resources/Info.plist "MCV Browser.app/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "MCV Browser.app/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "MCV Browser.app/Contents/Info.plist"
	/usr/bin/sed -i '' 's|MCV_UPDATE_FEED_URL|$(UPDATE_FEED_URL)|g' "MCV Browser.app/Contents/Info.plist"
	/usr/bin/sed -i '' 's|MCV_UPDATE_PUBLIC_KEY|$(UPDATE_PUBLIC_KEY)|g' "MCV Browser.app/Contents/Info.plist"
	cp Resources/AppIcon.icns "MCV Browser.app/Contents/Resources/AppIcon.icns"
	cp .build/release/MCV "MCV Browser.app/Contents/MacOS/MCV"
	cp -R .build/release/Sparkle.framework "MCV Browser.app/Contents/Frameworks/Sparkle.framework"
	install_name_tool -add_rpath @executable_path/../Frameworks "MCV Browser.app/Contents/MacOS/MCV"
	codesign --force --deep --sign - "MCV Browser.app"
	codesign --verify --deep --strict "MCV Browser.app"
	@echo "✓ MCV Browser.app готовий"

dmg: app
	bash Scripts/make_dmg.sh

clean:
	rm -rf .build "MCV Browser.app" MCV-Browser.dmg
