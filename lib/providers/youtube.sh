#!/bin/sh
# lib/providers/youtube.sh
# YouTube browsing with instant search, quality selector, and playback controls
# Requires: core.sh, yt_search.sh

youtube_search_and_play() {
  local query="$1" download_mode="$2"

  if [ -z "$query" ]; then
    printf "${C_CYN}  Search YouTube ❯${C_RST} "
    read -r query
    [ -z "$query" ] && return
  fi

  local results
  results=$(spin_task "Searching YouTube for '$query'..." yt_search_list "$query" 25)

  [ -z "$results" ] && { err "No YouTube results found."; return 1; }


  local selected
  selected=$(printf '%s\n' "$results" \
    | awk -F'\t' '{print $1}' | fzf_prompt "Select YouTube video")
  [ -z "$selected" ] && return

  local yt_url
  yt_url=$(printf '%s\n' "$results" | awk -F'\t' -v s="$selected" '$1==s{print $2; exit}')
  [ -z "$yt_url" ] && return

  # Prompt for quality if not passed via CLI
  local quality
  quality=$(prompt_quality "Select YouTube Quality")
  EVERY_CLI_QUALITY="$quality"

  if [ "$download_mode" = "1" ]; then
    yt_download "$yt_url"
  else
    hist_add "youtube" "$selected" ""
    info "Launching: $selected ($quality)..."
    play_url "$yt_url" "$selected"

    # Post-playback menu
    while [ -t 0 ]; do
      local action
      action=$(printf 'replay\nsearch again\nchange quality\nquit' \
        | fzf_prompt "YouTube — $selected")
      case "$action" in
        replay)
          play_url "$yt_url" "$selected"
          ;;
        "search again")
          youtube_search_and_play "" "$download_mode"
          break
          ;;
        "change quality")
          quality=$(prompt_quality "Select YouTube Quality")
          EVERY_CLI_QUALITY="$quality"
          play_url "$yt_url" "$selected"
          ;;
        *)
          break
          ;;
      esac
    done
  fi
}
