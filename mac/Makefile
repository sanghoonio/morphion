CXX ?= clang++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -fobjc-arc
FRAMEWORKS = -framework Cocoa -framework AudioToolbox -framework CoreAudio -framework IOKit -framework UniformTypeIdentifiers

APP = build/morphion.app
EXE = $(APP)/Contents/MacOS/morphion

# The app bundle (icon, name in the Dock); build/morphion links to its executable so
# command-line flags still work: mac/build/morphion --probe
all: $(EXE) $(APP)/Contents/Info.plist $(APP)/Contents/Resources/AppIcon.icns $(APP)/Contents/Resources/score-guide.md build/morphion

$(EXE): main.mm ../engine/morphion.cpp ../engine/morphion.h ../engine/score.cpp ../engine/score.h Info.plist
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -DMORPHION_VERSION='"$(VERSION)"' -o $@ main.mm ../engine/morphion.cpp ../engine/score.cpp $(FRAMEWORKS)

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/AppIcon.icns: icon/AppIcon.icns
	@mkdir -p $(dir $@)
	cp $< $@

# the score guide, for the info panel's Copy guide for AI button
$(APP)/Contents/Resources/score-guide.md: ../scores/AGENTS.md
	@mkdir -p $(dir $@)
	cp $< $@

build/morphion: $(EXE)
	@rm -f $@
	ln -s morphion.app/Contents/MacOS/morphion $@

# A zip for a GitHub release: the bundle signed ad hoc as a whole (the linker signs only the
# executable, which macOS reports as "damaged" once downloaded), zipped with ditto.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP = build/morphion-$(VERSION)-macos.zip

release: all
	codesign --force --deep --sign - $(APP)
	@rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "wrote $(ZIP)"

clean:
	rm -rf build

.PHONY: all clean release
