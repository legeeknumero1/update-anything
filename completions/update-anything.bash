#!/usr/bin/env bash
# Bash completion for update-anything.
# Install location (auto-detected by install.sh): ~/.local/share/bash-completion/completions/update-anything

_update_anything() {
    local cur opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="-y --yes -c --check --clean --orphans --firmware --snapshot --deep-clean \
--inhibit-sleep --audit --rollback --notify --only -q --quiet --no-parallel \
-h --help -v --version \
--no-pacman --no-apt --no-dnf --no-yum --no-zypper --no-apk --no-brew \
--no-macports --no-pkg --no-pkg_add --no-flatpak --no-snap --no-nix \
--no-cargo --no-npm --no-pipx --no-uv --no-pnpm --no-bun"
    # The canonical bash-completion idiom: word-splitting compgen's output is
    # the intent. mapfile would avoid SC2207 but does not exist in bash 3.2,
    # which macOS still ships and this project targets.
    # shellcheck disable=SC2207
    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    return 0
}
complete -F _update_anything update-anything
