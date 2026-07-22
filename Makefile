# Convenience wrapper around `zig build` — see build.zig for the real targets.
# Run from the project root (the web build embeds resources/ relative to cwd).

ZIG ?= zig
PORT ?= 8000

.PHONY: build run test web serve clean

build: ## Native build -> zig-out/bin/space-slop
	$(ZIG) build

run: ## Native build + run
	$(ZIG) build run

test: ## Run the dependency-free simulation tests
	$(ZIG) build test

web: ## Web build -> zig-out/web/
	$(ZIG) build -Dtarget=wasm32-emscripten

serve: web ## Web build + serve it at http://localhost:$(PORT)/space_slop.html
	cd zig-out/web && python3 -m http.server $(PORT)

clean: ## Remove build outputs and the local zig cache
	rm -rf zig-out .zig-cache
