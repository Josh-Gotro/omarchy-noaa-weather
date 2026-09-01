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
* It contacts `ipapi.co` or `wttr.in` **only** when no location is configured,
  to guess one. Set `WEATHER_AUTOLOCATE=0` and it never does.
* It writes a cache under `~/.cache/omarchy-noaa-weather`, created `0700`.
* It writes exactly one key, `locations`, on **its own** entry in
  `~/.config/omarchy/shell.json`, and only when you edit locations in the
  popup. It does this by running `omarchy bar set`, never by editing the file.

It needs no credentials, stores none, and reads nothing else of yours.

## Notes for reviewers

* Settings are persisted with `Util.execArgv`, an argv vector, so a location
  name never crosses a shell.
* Coordinates are formatted under `LC_ALL=C` and interpolated into a URL only
  after being reduced to four decimal places.
* Responses are parsed with `jq`, never with `eval` or a shell.
