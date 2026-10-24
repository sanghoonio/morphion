CXX ?= clang++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -Wpedantic

build/render_test: render_test.cpp morphion.cpp morphion.h
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@ render_test.cpp morphion.cpp

clean:
	rm -rf build

.PHONY: clean
