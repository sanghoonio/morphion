CXX ?= clang++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -Wpedantic
# the release version, stamped into score files (bump it in mac/Info.plist)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" ../mac/Info.plist)

build/render_test: render_test.cpp morphion.cpp morphion.h score.cpp score.h ../mac/Info.plist
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -DMORPHION_VERSION='"$(VERSION)"' -o $@ render_test.cpp morphion.cpp score.cpp

clean:
	rm -rf build

.PHONY: clean
