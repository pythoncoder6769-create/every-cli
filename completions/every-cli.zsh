#compdef every-cli

_every-cli() {
  local -a categories=(anime movies tv cartoons youtube live)
  local -a qualities=(best 1080 720 480 360)

  _arguments \
    '(-c --category)'{-c,--category}'[Content category]:category:(${categories})' \
    '(-e --episode)'{-e,--episode}'[Episode number or range]:episode:' \
    '(-q --quality)'{-q,--quality}'[Video quality]:quality:(${qualities})' \
    '(-d --download)'{-d,--download}'[Download instead of streaming]' \
    '--dub[Use dubbed audio (anime)]' \
    '--vlc[Use VLC player]' \
    '--no-color[Disable colours]' \
    '--continue[Resume from history]' \
    '(-U --update)'{-U,--update}'[Self-update]' \
    '(-v --version)'{-v,--version}'[Print version]' \
    '(-h --help)'{-h,--help}'[Show help]' \
    '*:query:'
}

_every-cli
