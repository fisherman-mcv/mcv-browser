.PHONY: build run release app dmg clean

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
	mkdir -p "MCV Browser.app/Contents/MacOS"
	cp Resources/Info.plist "MCV Browser.app/Contents/Info.plist"
	cp .build/release/MCV "MCV Browser.app/Contents/MacOS/MCV"
	@echo "✓ MCV Browser.app готовий"

dmg: app
	bash Scripts/make_dmg.sh

clean:
	rm -rf .build "MCV Browser.app" MCV-Browser.dmg
