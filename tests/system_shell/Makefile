SHELL := /bin/sh
.SHELLFLAGS := -ec
.PHONY: all
all:
	@value=$$(printf '%s' 'two words'); test "$$value" = 'two words'; printf 'substitution:%s\n' "$$value"
	@for word in one two three; do printf '<%s>' "$$word"; done; printf '\n'
	@printf '%s\n' '#!/bin/sh' 'set -eu' 'printf "shebang:%s\n" "$$1"' >child; chmod +x child; ./child argument
	@printf 'a\nb\n' | while IFS= read -r line; do printf '[%s]\n' "$$line"; done
