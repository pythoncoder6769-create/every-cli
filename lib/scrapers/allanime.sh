#!/bin/sh
# lib/scrapers/allanime.sh
# Mirrors ani-cli's AllAnime GraphQL scraping approach (GPL-3.0 inspiration)

ALLANIME_API="https://api.allanime.day/api"
ALLANIME_REFERER="https://allanime.to"

allanime_search() {
  local query="$1"
  local gql_query
  gql_query=$(printf '{"query":"query($search:SearchInput $translationType:VaildTranslationTypeEnumType){shows(search:$search translationType:$translationType){edges{_id name availableEpisodes}}}","variables":{"search":{"query":"%s"},"translationType":"sub"}}' "$query")

  retry_curl \
    -H "Referer: $ALLANIME_REFERER" \
    -H 'Content-Type: application/json' \
    --data "$gql_query" \
    "$ALLANIME_API" \
  | sed 's/},{/\n/g' \
  | sed -n 's/.*"_id":"\([^"]*\)","name":"\([^"]*\)".*"sub":\([0-9]*\).*"dub":\([0-9]*\).*/\1|\2|\3|\4/p'
}

allanime_episode() {
  local show_id="$1" ep="$2" lang="${3:-sub}"
  local gql_query
  gql_query=$(printf '{"query":"query($showId:String! $translationType:VaildTranslationTypeEnumType! $episodeString:String!){episode(showId:$showId translationType:$translationType episodeString:$episodeString){sourceUrls}}","variables":{"showId":"%s","translationType":"%s","episodeString":"%s"}}' "$show_id" "$lang" "$ep")

  retry_curl \
    -H "Referer: $ALLANIME_REFERER" \
    -H 'Content-Type: application/json' \
    --data "$gql_query" \
    "$ALLANIME_API"
}

allanime_decrypt_url() {
  local encoded="$1"
  if command -v python3 >/dev/null 2>&1; then
    local res
    res=$(printf '%s' "$encoded" | python3 -c "
import sys
s = sys.stdin.read().strip()
result = ''
for i, c in enumerate(s):
    if i % 2 == 0:
        result += chr(ord(c) - 1) if ord(c) > 0 else c
    else:
        result += chr(ord(c) + 1)
print(result)
" 2>/dev/null)
    if [ -n "$res" ]; then
      printf '%s' "$res"
      return 0
    fi
  fi

  printf '%s' "$encoded" | awk '
    BEGIN {
      for(i=0;i<256;i++) ord[sprintf("%c",i)]=i
    }
    {
      n=split($0,a,"")
      for(i=1;i<=n;i++){
        c=a[i]; v=ord[c]
        if((i-1)%2==0) printf "%c", v-1
        else printf "%c", v+1
      }
    }
  '
}

allanime_get_stream() {
  local episode_json="$1"
  local stream_url=""

  local sources
  sources=$(printf '%s' "$episode_json" | grep -o '"sourceUrl":"[^"]*"' \
            | sed 's/"sourceUrl":"//;s/"$//')

  for src in $sources; do
    case "$src" in
      *"--"*)
        src=$(printf '%s' "$src" | sed 's/--//g')
        src=$(allanime_decrypt_url "$src")
        ;;
    esac

    case "$src" in *"googletagmanager"*|*"doubleclick"*) continue ;; esac

    if stream_url=$(yt-dlp --no-warnings -g "$src" 2>/dev/null | tr -d '\r' | head -1) \
       && [ -n "$stream_url" ]; then
      printf '%s' "$stream_url"
      return 0
    fi
  done

  return 1
}
