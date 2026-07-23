APP     = EFStatus
BUNDLE  = $(APP).app
EXEC    = $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES = $(wildcard Sources/*.swift)

.PHONY: all clean run

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Resources/Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	swiftc $(SOURCES) \
		-framework Cocoa \
		-framework UserNotifications \
		-framework CryptoKit \
		-o $(EXEC)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@echo "✓ Built $(BUNDLE)"

run: all
	open $(BUNDLE)

clean:
	rm -rf $(BUNDLE)
