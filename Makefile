.PHONY: build test app run clean

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
