## ohmyzsh
export ZSH="$HOME/.config/zsh/oh-my-zsh"
export ZSH_CUSTOM="$HOME/.config/zsh/custom"
export ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-zsh"
export ZSH_COMPDUMP="$ZSH_CACHE_DIR/.zcompdump-${ZSH_VERSION}"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
if [ -f "$ZSH/oh-my-zsh.sh" ]; then
    source "$ZSH/oh-my-zsh.sh"
fi

## OS
if [[ "$(uname)" == "Darwin" ]]; then
    # Mac (Apple Silicon)
    [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ "$(uname)" == "Linux" ]]; then
    # Linux / WSL
    [[ -f /home/linuxbrew/.linuxbrew/bin/brew ]] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

if command -v mise > /dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi

if command -v starship > /dev/null 2>&1; then
    eval "$(starship init zsh)"
fi

if command -v zoxide > /dev/null 2>&1 && [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(zoxide init zsh)"
fi

setopt hist_ignore_all_dups  # 重複したヒストリを無視
setopt share_history         # ターミナル間でヒストリを共有

[[ -f "$ZDOTDIR/aliases.zsh" ]] && source "$ZDOTDIR/aliases.zsh"
