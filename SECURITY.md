# Security

## Reporting a vulnerability

Please report privately through GitHub's
[private vulnerability reporting](https://github.com/Josh-Gotro/omarchy-noaa-weather/security/advisories/new)
rather than opening a public issue.

I will acknowledge what I can, when I can. This is a personal project, not a
staffed one, so please do not expect a same day response.

## What this plugin does on your machine

Worth knowing, because Omarchy plugins run **unsandboxed inside your
long lived shell process**:

* It runs `curl` and `jq` on a timer.
* It contacts `api.weather.gov`, plus `api.zippopotam.us` or
  `nominatim.openstreetmap.org` when resolving a location you typed.
* It contacts `ipapi.co` or `wttr.in` **only** if you have turned automatic
  location on **and** no location is configured. This is off by default:
  guessing a location means sending your IP address to a third party, so it
  never happens until you opt in.
* It writes a cache under `~/.cache/omarchy-noaa-weather`, created `0700`.
* It writes exactly one key, `locations`, on **its own** entry in
  `~/.config/omarchy/shell.json`, and only when you edit locations in the
  popup. It does this by running `omarchy bar set`, never by editing the file.

It needs no credentials, stores none, and reads nothing else of yours.

## Notes for reviewers

* Settings are persisted with `Util.execArgv`, an argv vector, so a location
  name never crosses a shell.
* All network access goes through `lib.sh`: https only, to an exact
  per-script hostname allowlist, with redirects followed one hop at a time
  and re-checked at each hop. URLs handed back inside API responses pass the
  same gate before they are fetched.
* Downloads and cache reads are capped at 256 KiB while they happen, not
  after buffering; payload fields are length-capped and control-stripped on
  top, and rendered with `Text.PlainText`.
* The cache directory and every entry in it are verified (regular file,
  owned by the user, no loose modes, no symlinks) before use; writes are
  exclusive-create temp files renamed in place under an advisory lock.
* Each refresh runs under one hard `timeout` deadline that signals the whole
  process group, so a hung request cannot outlive its run.
* Which provider executables may run is a fixed allowlist in `weather-fetch`,
  not a path taken from settings, and nothing a provider or a network
  response prints can name a command for the widget to execute.
* Coordinates are formatted under `LC_ALL=C`, validated against a numeric
  pattern, and interpolated into a URL only after being reduced to four
  decimal places. Station identifiers from responses are pattern-checked
  before they appear in a URL path.
* Responses are parsed with `jq`, never with `eval` or a shell.
