#!/bin/bash

check_release_target() {
    local id="$1" path link
    [[ "$id" =~ ^r[0-9]+$ ]] ||
        { echo "Invalid release ID: $id" >&2; return 1; }
    [[ -d /srv/releases && ! -L /srv/releases ]] ||
        { echo "Release directory must be a real directory" >&2; return 1; }
    path="/srv/releases/$id"
    for link in current previous; do
        if [[ -L "/srv/$link" && "$(readlink -f "/srv/$link")" == "$path" ]]; then
            echo "Refusing to replace or remove the $link release" >&2
            return 1
        fi
    done
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -d "$path" && ! -L "$path" &&
           -f "$path/.managed-release" && ! -L "$path/.managed-release" ]] ||
            { echo "Refusing unrecognized release target: $path" >&2; return 1; }
    fi
}

remove_release() {
    check_release_target "$1" || return 1
    rm -rf -- "/srv/releases/$1"
}
