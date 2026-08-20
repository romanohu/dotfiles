## alias
### move
alias cdhome='cd $HOME'

### zsh
alias sz='source $HOME/.config/zsh/.zshrc'

### git
alias gc-b='git checkout -b'
alias gc-m='git commit -m'
alias gac-m='git add -A && git commit -m'
alias gp='git push'
alias gs='git status --short --branch'

gcof() {
    local branch

    command -v fzf > /dev/null 2>&1 || return 0
    [ -t 0 ] && [ -t 1 ] || return 0
    branch="$(git for-each-ref --format='%(refname:short)' refs/heads | fzf)" || return 0
    [ -n "$branch" ] || return 0
    git switch -- "$branch"
}

glogf() {
    local commit

    command -v fzf > /dev/null 2>&1 || return 0
    [ -t 0 ] && [ -t 1 ] || return 0
    commit="$(git log --oneline | fzf)" || return 0
    [ -n "$commit" ] || return 0
    git show -- "${commit%% *}"
}
