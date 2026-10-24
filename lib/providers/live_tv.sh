#!/bin/sh
# lib/providers/live_tv.sh
# Live IPTV browser with category icons and channel switching
# Requires: core.sh

IPTV_INDEX="https://iptv-org.github.io/iptv/index.m3u"
IPTV_BY_CAT_BASE="https://iptv-org.github.io/iptv/categories"

live_tv_browse() {
  local category="$1"

  if [ -z "$category" ]; then
    local cat_choice
    cat_choice=$(printf '%s\n' \
      "all           Worldwide channels (8,000+)" \
      "news          Global & local news" \
      "sports        Live sports & highlights" \
      "movies        Continuous movie channels" \
      "animation     Anime & animated broadcasts" \
      "kids          Cartoons & children TV" \
      "music         24/7 music videos & concerts" \
      "entertainment General entertainment & series" \
      "cooking       Culinary, food & recipes" \
      "documentary   Nature, science & history" \
      | fzf_prompt "IPTV Category")
    [ -z "$cat_choice" ] && return
    category=$(printf '%s' "$cat_choice" | awk '{print $1}')
  fi

  local m3u_url
  if [ "$category" = "all" ]; then
    m3u_url="$IPTV_INDEX"
  else
    m3u_url="$IPTV_BY_CAT_BASE/${category}.m3u"
  fi

  local m3u
  m3u=$(spin_task "Loading IPTV playlist ($category)..." cached_get "$m3u_url" 3600)


  if [ -z "$m3u" ]; then
    err "Could not load IPTV playlist."
    return 1
  fi

  local channels
  channels=$(printf '%s' "$m3u" \
    | awk '
      /^#EXTINF/ {
        title = $0
        sub(/^.*,/, "", title)
        flag = ""
        if (match($0, /tvg-country="[^"]*"/)) {
          flag = " [" substr($0, RSTART + 13, RLENGTH - 14) "]"
        } else if (match($0, /\.[a-z]{2}@[^"]*"/)) {
          flag = " [" toupper(substr($0, RSTART + 1, 2)) "]"
        }
        line = title flag
        next_is_url = 1
        next
      }
      next_is_url && /^https?/ {
        printf "%s|%s\n", line, $0
        next_is_url = 0
      }
    ')

  [ -z "$channels" ] && { err "No channels found in playlist."; return 1; }

  local selected
  selected=$(printf '%s\n' "$channels" \
    | awk -F'|' '{print $1}' \
    | fzf_prompt "Select live channel")
  [ -z "$selected" ] && return

  local stream_url
  stream_url=$(printf '%s\n' "$channels" \
    | awk -F'|' -v s="$selected" '$1==s{print $2}' | head -1)

  while [ -n "$stream_url" ]; do
    info "Opening: $selected"
    play_url "$stream_url" "$selected"

    # Channel control menu
    local next_act
    next_act=$(printf 'change channel\nreconnect\nchange category\nquit' \
      | fzf_prompt "Live TV — $selected")
    case "$next_act" in
      "change channel")
        selected=$(printf '%s\n' "$channels" | awk -F'|' '{print $1}' | fzf_prompt "Select live channel")
        [ -z "$selected" ] && break
        stream_url=$(printf '%s\n' "$channels" | awk -F'|' -v s="$selected" '$1==s{print $2}' | head -1)
        ;;
      reconnect)
        continue
        ;;
      "change category")
        live_tv_browse ""
        break
        ;;
      *)
        break
        ;;
    esac
  done
}
