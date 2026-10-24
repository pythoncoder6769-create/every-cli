# Bash completion for every-cli
_every_cli() {
  local cur prev opts categories
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  opts="-c --category -e --episode -q --quality -d --download --dub --vlc --no-color --continue -U --update -v --version -h --help"
  categories="anime movies tv cartoons youtube live"

  case "$prev" in
    -c|--category)
      COMPREPLY=( $(compgen -W "$categories" -- "$cur") )
      return 0
      ;;
    -q|--quality)
      COMPREPLY=( $(compgen -W "best 1080 720 480 360" -- "$cur") )
      return 0
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
  fi
}
complete -F _every_cli every-cli
