# makefile
INSTDIR = ~/.local/bin

.PHONY: all help spec bench

all: help

help:               ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36mmake %-18s\033[0m \033[2;37m%s\033[0m\n", $$1, $$2}'

spec:               ## Run spec suite
	crystal spec

bench:             ## Run bench suite
	crystal clear_cache
	@rm -f bench-suite
	crystal build --verbose --release --no-debug bench/all.cr -o bench-suite
	./bench-suite
	@rm -f bench-suite