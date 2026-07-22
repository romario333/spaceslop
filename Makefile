# Convenience wrappers around the zig build. `make wasm` serves the web build
# locally; override the port with `make wasm PORT=9000`.
PORT ?= 8000

.PHONY: run wasm

run:
	zig build run

wasm:
	zig build -Dtarget=wasm32-emscripten
	@echo "Dev server running at http://localhost:$(PORT)/space_slop.html"
	@python3 -m http.server $(PORT) --directory zig-out/web
