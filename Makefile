APP     = EFStatus
BUNDLE  = $(APP).app
EXEC    = $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES = $(wildcard Sources/*.swift)
MIN_OS  = 12.0
SWIFTC_FLAGS = -framework Cocoa -framework UserNotifications -framework CryptoKit -framework Network

.PHONY: all clean run

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Resources/Info.plist Resources/AppIcon.icns
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	swiftc $(SOURCES) $(SWIFTC_FLAGS) \
		-target x86_64-apple-macosx$(MIN_OS) \
		-o $(EXEC)-x86_64
	swiftc $(SOURCES) $(SWIFTC_FLAGS) \
		-target arm64-apple-macosx$(MIN_OS) \
		-o $(EXEC)-arm64
	lipo -create -output $(EXEC) $(EXEC)-x86_64 $(EXEC)-arm64
	@rm -f $(EXEC)-x86_64 $(EXEC)-arm64
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "✓ Built universal $(BUNDLE) (x86_64 + arm64)"

run: all
	open $(BUNDLE)

clean:
	rm -rf $(BUNDLE)
