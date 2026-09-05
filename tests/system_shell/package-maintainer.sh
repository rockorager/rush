#!/bin/sh
set -eu
record() {
    local action="$1"
    shift
    printf '%s' "$action" >>/var/log/rush-lifecycle.log
    for argument do
        printf ' <%s>' "$argument" >>/var/log/rush-lifecycle.log
    done
    printf '\n' >>/var/log/rush-lifecycle.log
}
record "${0##*.}" "$@"
