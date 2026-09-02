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
#     happens (curl --max-filesize aborts mid-transfer; cache reads are
#     bounded reads from an already-verified descriptor), never after the
#     fact. Redirect targets come from curl's own %{redirect_url} write-out,
#     so no unbounded header file is ever written.
#   * all cache I/O is descriptor-bound, in ./cache-io: the cache directory
#     is opened once with O_DIRECTORY|O_NOFOLLOW and verified by fstat on
#     that descriptor, entries are opened relative to it with O_NOFOLLOW and
#     verified (regular, owned, no loose modes) on the open descriptor,
#     reads come from that same descriptor, and writes are an exclusive 0600
#     temp file plus a descriptor-relative rename with file and directory
#     fsync, under an flock taken on a descriptor-verified lock file. A
#     pathname is never checked at one moment and used at another, and
#     nothing is ever deleted recursively.

# 256 KiB, mirroring the cap the widget applies to process output.
MAX_BYTES="${WEATHER_MAX_BYTES:-262144}"
UA="${WEATHER_USER_AGENT:-omarchy-noaa-weather/0.2.0 (+https://github.com/Josh-Gotro/omarchy-noaa-weather)}"
TIMEOUT="${WEATHER_TIMEOUT:-10}"
CACHE_DIR="${WEATHER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-noaa-weather}"

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
  local hop out code rc loc
  for (( hop = 0; hop < 4; hop++ )); do
    url_allowed "$url" "$@" || return 60
    # No -L: curl must not choose redirect targets. Each hop comes back here
    # and is re-checked before another request goes out. The target itself
    # comes from curl's %{redirect_url} write-out (the Location header,
    # already resolved to an absolute URL), so no response-header file is
    # written anywhere -- headers were the one sink --max-filesize does not
    # bound.
    out=$(curl -sS \
             --proto '=https' \
             --connect-timeout 4 --max-time "$TIMEOUT" \
             --max-filesize "$MAX_BYTES" \
             -H "User-Agent: $UA" \
             -o "$dest" -w '%{http_code} %{redirect_url}' "$url" 2>/dev/null)
    rc=$?
    if (( rc != 0 )); then
      case $rc in
        63)     return 63 ;;
        6|7|28) return $rc ;;
        *)      return 7 ;;
      esac
    fi
    # Belt and braces for a curl old enough to enforce --max-filesize only
    # against a declared Content-Length.
    if (( $(stat -c %s "$dest" 2>/dev/null || echo 0) > MAX_BYTES )); then
      return 63
    fi
    code=${out%% *}
    loc=${out#* }
    case "$code" in
      301|302|303|307|308)
        # Only an absolute https target can continue; relative Locations
        # were already resolved by curl, so anything else is off-policy.
        [[ $loc == https://* ]] || return 65
        url="$loc"
        ;;
      *)
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
#
# Entries are named by bare filename ("geo-<md5>", "points-<md5>.json"), never
# by path. All I/O happens inside ./cache-io, which holds the verified cache
# directory as a file descriptor and does every open, check, read, rename,
# fsync, lock, and delete relative to that descriptor -- see its header for
# the exact rules. Shell can only name files by pathname, and a pathname
# checked is not a pathname used, which is why this is not done here in bash.
#
# python3 ships with Omarchy; on a machine without it cache_init fails and
# every caller already degrades to running uncached.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_cache_io() {
  CACHE_IO_DIR="$CACHE_DIR" CACHE_IO_MAX="$MAX_BYTES" \
    python3 "$_LIB_DIR/cache-io" "$@" 2>/dev/null
}

# Verify (creating if needed) the cache directory: 0700, ours, under a parent
# that nobody else could swap out. Callers run uncached when this fails.
cache_init() {
  command -v python3 >/dev/null 2>&1 || return 1
  _cache_io init
}

# cache_put NAME: stdin -> entry. Exclusive 0600 temp in the cache directory,
# descriptor-relative rename, file+directory fsync, under the cache lock.
# An empty or oversized body is a failure, not a write.
cache_put() {
  _cache_io put "$1"
}

# cache_get_raw NAME [MAX_AGE_SECONDS]: prints the entry if it is a safe
# regular file, non-empty, within the byte cap, and fresh enough. The caller
# owns validating the shape of what comes back. An unsafe entry (symlink,
# FIFO, wrong owner, loose modes, oversize) is removed, never read.
cache_get_raw() {
  _cache_io get "$@"
}

# cache_del NAME: drop one entry, without recursion, missing is fine.
cache_del() {
  _cache_io del "$1"
}

# cache_prune DAYS: drop entries untouched for DAYS days. Entries are
# per-location and never expire on their own, so a machine that has looked
# up many places would otherwise accumulate files forever.
cache_prune() {
  _cache_io prune "${1:-30}"
}

# cache_get NAME [MAX_AGE_SECONDS]: cache_get_raw plus a JSON requirement.
# An entry that no longer parses is removed so it cannot be retried forever.
cache_get() {
  local body
  body=$(cache_get_raw "$@") || return 1
  jq -e . <<<"$body" >/dev/null 2>&1 || { cache_del "$1"; return 1; }
  printf '%s' "$body"
}
