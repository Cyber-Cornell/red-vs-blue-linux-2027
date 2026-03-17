if [[ $- != *i* ]]; then
  # Shell is non-interactive.  Be done now!
  return
fi

unalias -a

PS1="\[\e[92;1m\]\u@\h \[\e[94m\]\w \$\[\e[0m\] "

export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin

export HISTCONTROL=ignoredups

export XDG_CACHE_HOME="${HOME}"/.cache
export XDG_CONFIG_HOME="${HOME}"/.config
export XDG_DATA_HOME="${HOME}"/.local/share
export XDG_STATE_HOME="${HOME}"/.local/state
