CXX ?= clang++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -fobjc-arc
FRAMEWORKS = -framework Cocoa -framework AudioToolbox -framework CoreAudio

APP = build/morphion.app
EXE = $(APP)/Contents/MacOS/morphion

# The app bundle (icon, name in the Dock); build/morphion links to its executable so
# command-line flags still work: mac/build/morphion --probe
all: $(EXE) $(APP)/Contents/Info.plist $(APP)/Contents/Resources/AppIcon.icns build/morphion

$(EXE): main.mm ../engine/morphion.cpp ../engine/morphion.h
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -o $@ main.mm ../engine/morphion.cpp $(FRAMEWORKS)

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/AppIcon.icns: icon/AppIcon.icns
	@mkdir -p $(dir $@)
	cp $< $@

build/morphion: $(EXE)
	@rm -f $@
	ln -s morphion.app/Contents/MacOS/morphion $@

clean:
	rm -rf build

.PHONY: all clean
