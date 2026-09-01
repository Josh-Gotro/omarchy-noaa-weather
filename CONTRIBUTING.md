# Contributing

Thanks for taking a look. Issues and pull requests are welcome.

## Running it locally

The plugin is plain bash, jq and QML. There is nothing to build.

```bash
git clone https://github.com/Josh-Gotro/omarchy-noaa-weather.git
cd omarchy-noaa-weather
./tests/run              # 39 assertions, no network
./tests/run -v           # show each one
```

To try a change on a real bar, copy the folder into place and restart the
shell. QML does **not** hot reload, because Omarchy runs Quickshell with
`QS_DISABLE_FILE_WATCHER=1`:

```bash
cp -r . ~/.config/omarchy/plugins/gotro.noaa-weather
omarchy restart shell
omarchy-shell gotro.noaa-weather status
omarchy-shell gotro.noaa-weather command   # print the exact fetch command
```

Changes to the shell scripts, `weather.jq`, and `shell.json` take effect on the
next poll without a restart.

## Before opening a pull request

```bash
./tests/run                 # must pass
omarchy plugin validate .   # must pass, on an Omarchy machine
bash -n weather-fetch geocode geolocate providers/noaa
```

Please add a test for anything that changes behaviour. The suite is offline by
design: shaping runs against frozen NOAA responses in `tests/fixtures/`, and the
orchestrator tests use `lat,lon` locations, which skip geocoding, together with
a stub provider. Keep it that way so the tests stay deterministic and do not
depend on the weather.

## Things that are easy to get wrong

These are documented at more length in the README under **Notes for anyone
reading the code**, and each of them has bitten this project already:

* `printf '%f'` honours `LC_NUMERIC`. Format coordinates under `LC_ALL=C` or a
  comma decimal locale will build a malformed NOAA URL.
* Never build a shell string from user input. Use `Util.execArgv`.
* Never name a widget setting `exec`. Omarchy claims that key for its own
  custom command module and your plugin will not load at all.
* `omarchy bar set` writes strings unless `--json` is passed, so settings can
  arrive as `"true"` rather than `true`.
* Cache writes go through a temp file and a rename, and reads discard anything
  that no longer parses.

## Adding a weather provider

`providers/noaa` is the only file that knows NOAA exists. Any executable that
takes `<lat> <lon> [alias] [fallback-label]` and prints one page object works.
Drop it in `providers/` and select it with the `provider` setting. This is how
worldwide coverage would be added without touching the widget.

## Style

Match what is already there. Comments explain **why**, not what, and are worth
writing when the reason is not obvious from the code.
