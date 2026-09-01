#!/usr/bin/env bash
# Shared plumbing for the fetch scripts: the network rules and the cache
# rules, in one place. Sourced, not executed.
#
# The rules:
#   * https only, to a caller-supplied allowlist of exact hostnames.
#     Redirects are followed by hand, one hop at a time, and every hop is
#     re-checked against the same allowlist. A Location header pointing
#     anywhere else (another host, a bare IP, http, a port, userinfo) ends
#     the request. URLs that arrive inside API responses go through the same
#     gate, so a compromised or spoofed response cannot point a request at
#     loopback, link-local, private, or arbitrary origins.
#   * every download and every cache read is capped at MAX_BYTES while it
#     happens (curl --max-filesize aborts mid-transfer; reads go through
#     head -c), never after the fact.
#   * cache files live in a directory verified to be a real directory owned
#     by this user with mode 700, under a parent this user owns. Reads
#     refuse symlinks, other owners, and loose modes. Writes create an
#     exclusive temp file (mktemp, 0600) in the same directory and rename
#     over the target, which is atomic within a filesystem, under an
#     advisory lock.

# 256 KiB, mirroring the cap the widget applies to process output.
MAX_BYTES="${WEATHER_MAX_BYTES:-262144}"
UA="${WEATHER_USER_AGENT:-omarchy-noaa-weather/0.2.0 (+https://github.com/Josh-Gotro/omarchy-noaa-weather)}"
TIMEOUT="${WEATHER_TIMEOUT:-10}"
CACHE_DIR="${WEATHER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-noaa-weather}"

_LIB_UID=$(id -u)

# ---- URL policy ------------------------------------------------------------

# url_allowed URL HOST...
# True only for https, no userinfo, no port, and a host equal to one of the
# listed names. Equality is the point: api.weather.gov.evil.example,
# user@api.weather.gov@evil.example, https://127.0.0.1/ and http://anything
# all fail, because none of them IS an allowlisted public hostname.
url_allowed() {
  local url="$1" host h
  shift
  [[ $url == https://* ]] || return 1
  host="${url#https://}"
  host="${host%%[/?#]*}"
  [[ -n $host ]] || return 1
  [[ $host == *@* ]] && return 1
  [[ $host == *:* ]] && return 1
  host="${host,,}"
  for h in "$@"; do
    [[ $host == "$h" ]] && return 0
  done
  return 1
}

# http_get URL DEST HOST...
# GET under the policy above. The body lands in DEST, capped at MAX_BYTES
# while downloading. Prints the final HTTP status code on stdout.
# Returns: 0 response received (status printed), 6/7/28 curl's own resolve/
# connect/timeout codes, 60 URL refused by policy, 63 body exceeded
# MAX_BYTES, 65 redirect loop or unusable Location.
http_get() {
  local url="$1" dest="$2"
  shift 2
  local hop hdr code rc loc base
  for (( hop = 0; hop < 4; hop++ )); do
    url_allowed "$url" "$@" || return 60
    hdr=$(mktemp "${TMPDIR:-/tmp}/noaa-hdr.XXXXXX") || return 7
    # No -L: curl must not choose redirect targets. Each hop comes back here
    # and is re-checked before another request goes out.
    code=$(curl -sS \
             --proto '=https' \
             --connect-timeout 4 --max-time "$TIMEOUT" \
             --max-filesize "$MAX_BYTES" \
             -H "User-Agent: $UA" \
             -D "$hdr" -o "$dest" -w '%{http_code}' "$url" 2>/dev/null)
    rc=$?
    if (( rc != 0 )); then
      rm -f "$hdr"
      case $rc in
        63)     return 63 ;;
        6|7|28) return $rc ;;
        *)      return 7 ;;
      esac
    fi
    # Belt and braces for a curl old enough to enforce --max-filesize only
    # against a declared Content-Length.
    if (( $(stat -c %s "$dest" 2>/dev/null || echo 0) > MAX_BYTES )); then
      rm -f "$hdr"
      return 63
    fi
    case "$code" in
      301|302|303|307|308)
        loc=$(awk 'tolower($1) == "location:" { print $2; exit }' "$hdr" | tr -d '\r')
        rm -f "$hdr"
        [[ -n $loc ]] || return 65
        case "$loc" in
          https://*) url="$loc" ;;
          /*) base="${url#https://}"; url="https://${base%%[/?#]*}$loc" ;;
          *) return 65 ;;
        esac
        ;;
      *)
        rm -f "$hdr"
        printf '%s' "$code"
        return 0
        ;;
    esac
  done
  return 65
}

# ---- Strings from elsewhere ------------------------------------------------

# One printable line: control characters stripped, length capped. Every
# remote string passes through here before it can reach a label, a URL
# segment, or a file the widget will render.
sanitize_line() {
  printf '%s' "$1" | tr -d '\000-\037\177' | head -c "${2:-120}"
}

# ---- Cache -----------------------------------------------------------------

# A directory is trusted only if it is a real directory (not a symlink),
# owned by this user, with no group or world bits at all.
safe_dir() {
  local p="$1" info
  [[ -d $p && ! -L $p ]] || return 1
  info=$(stat -c '%u %a' "$p" 2>/dev/null) || return 1
  [[ ${info%% *} == "$_LIB_UID" ]] || return 1
  (( (8#${info##* } & 8#077) == 0 ))
}

# A cache file is trusted only if it is a regular file (not a symlink),
# owned by this user, and writable by nobody else.
safe_file() {
  local p="$1" info
  [[ -f $p && ! -L $p ]] || return 1
  info=$(stat -c '%u %a' "$p" 2>/dev/null) || return 1
  [[ ${info%% *} == "$_LIB_UID" ]] || return 1
  (( (8#${info##* } & 8#022) == 0 ))
}

# Create or adopt CACHE_DIR under a verified parent. The parent may be a
# symlink (a relocated ~/.cache is legitimate) but must resolve to a
# directory owned by this user or by root, and if it is world writable it
# must carry the sticky bit (the /tmp rule, which is what stops anyone else
# renaming our directory out from under us). The cache dir itself must then
# pass safe_dir: a real directory, ours, mode 700.
cache_init() {
  local parent info owner mode
  parent=$(dirname "$CACHE_DIR")
  mkdir -p "$parent" 2>/dev/null
  parent=$(realpath -e "$parent" 2>/dev/null) || return 1
  info=$(stat -c '%u %a' "$parent" 2>/dev/null) || return 1
  owner=${info%% *}
  mode=${info##* }
  [[ $owner == "$_LIB_UID" || $owner == 0 ]] || return 1
  if (( (8#$mode & 8#002) != 0 )); then
    (( (8#$mode & 8#1000) != 0 )) || return 1
  fi
  CACHE_DIR="$parent/$(basename "$CACHE_DIR")"
  if [[ ! -e $CACHE_DIR && ! -L $CACHE_DIR ]]; then
    mkdir -m 700 "$CACHE_DIR" 2>/dev/null
  fi
  chmod 700 "$CACHE_DIR" 2>/dev/null
  safe_dir "$CACHE_DIR"
}

# Advisory lock around cache mutation. Reads need no lock (replacement is
# rename-only, so a partial file is never visible); the lock keeps two
# concurrent runs from interleaving writes and prunes.
with_cache_lock() {
  if command -v flock >/dev/null 2>&1 && [[ -d $CACHE_DIR ]]; then
    flock -w 5 "$CACHE_DIR/.lock" "$@"
  else
    "$@"
  fi
}

# cache_put PATH: stdin -> PATH. Exclusive 0600 temp in the same directory,
# bounded write, atomic rename. An empty body is a failure, not a write.
cache_put() {
  local dest="$1" tmp
  safe_dir "$CACHE_DIR" || return 1
  tmp=$(mktemp "$dest.XXXXXX") || return 1
  if head -c "$MAX_BYTES" > "$tmp" && [[ -s $tmp ]]; then
    with_cache_lock mv -f -- "$tmp" "$dest"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

# cache_get PATH [MAX_AGE_SECONDS]: prints the cached JSON if the file is
# safe, fresh enough, within the byte cap, and still parses. Anything that
# fails those checks is treated as absent; an unsafe or unparseable entry is
# also removed so it cannot be retried forever.
cache_get() {
  local body
  body=$(cache_get_raw "$@") || return 1
  jq -e . <<<"$body" >/dev/null 2>&1 || { rm -f -- "$1"; return 1; }
  printf '%s' "$body"
}

# Same, without the JSON requirement, for line-format caches. The caller
# owns validating the shape of what comes back.
cache_get_raw() {
  local src="$1" max_age="${2:-}" body
  if [[ -e $src || -L $src ]] && ! safe_file "$src"; then
    rm -rf -- "$src" 2>/dev/null
    return 1
  fi
  [[ -s $src ]] || return 1
  if [[ -n $max_age ]]; then
    (( $(date +%s) - $(stat -c %Y "$src" 2>/dev/null || echo 0) < max_age )) || return 1
  fi
  body=$(head -c "$MAX_BYTES" -- "$src" 2>/dev/null) || return 1
  [[ -n $body ]] || return 1
  printf '%s' "$body"
}
