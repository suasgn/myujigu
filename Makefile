.PHONY: build test app run clean xcode-build xcode-test xcode-archive

ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif

build:
	swift build --disable-sandbox

test:
	swift test --disable-sandbox

app:
	./scripts/build-app.sh

run:
	swift run --disable-sandbox Myujigu

clean:
	swift package clean

xcode-build:
	xcodebuild -project Myujigu.xcodeproj -scheme Myujigu -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/XcodeDerivedData build

xcode-test:
	xcodebuild -project Myujigu.xcodeproj -scheme Myujigu -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/XcodeDerivedData test

xcode-archive:
	xcodebuild -project Myujigu.xcodeproj -scheme Myujigu -configuration Release -destination 'generic/platform=macOS' -derivedDataPath .build/XcodeDerivedData -archivePath .build/Myujigu.xcarchive archive
