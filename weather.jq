# NOAA forecast + observation -> one normalized page for the widget contract.
#
# Args: $forecast (/gridpoints/.../forecast), $current (latest observation or
#       null), $label, $units ("f"|"c"), $days
#
# NOAA returns 14 periods: a day/night pair per date, except the first period
# is "Tonight" when it is already evening. Grouping by local date rather than
# by pairs is what makes that edge case harmless.

def c2f: (. * 9 / 5) + 32;
def r0: (. + 0.5 | floor);
def temp(f_value):                      # NOAA forecast temps are already F
  if $units == "c" then ((f_value - 32) * 5 / 9 | r0) else (f_value | r0) end;
def tempC(c_value):                     # observations are Celsius
  if $units == "c" then (c_value | r0) else (c_value | c2f | r0) end;
def deg: if $units == "c" then "°C" else "°F" end;
def degShort: "°";

# Condition text -> a Nerd Font weather glyph. Ordered most-specific first:
# "Chance Rain Showers then Sunny" must read as rain, not sun.
def glyph:
  ascii_downcase as $s
  | if   ($s | test("thunder|tstm"))        then ""
    elif ($s | test("snow|flurr|blizzard|wintry|sleet|ice")) then ""
    elif ($s | test("freezing|hail"))       then ""
    elif ($s | test("rain|shower|drizzle")) then ""
    elif ($s | test("fog|haze|mist|smoke")) then ""
    elif ($s | test("wind|breezy|blustery")) then ""
    elif ($s | test("mostly cloudy|overcast")) then ""
    elif ($s | test("partly|scattered|few|mostly sunny|mostly clear")) then ""
    elif ($s | test("cloud"))               then ""
    elif ($s | test("sunny|clear|fair"))    then ""
    else "" end;

# Anything that is not plainly fair weather is worth a warm colour; severe
# weather is worth an urgent one. Everything else stays neutral.
def condState:
  ascii_downcase as $s
  | if   ($s | test("tornado|hurricane|blizzard|ice storm|warning")) then "error"
    elif ($s | test("thunder|tstm|snow|freezing|hail|sleet"))        then "warn"
    else "ok" end;

($forecast.properties.periods // []) as $periods
| ($periods | map(. + { date: (.startTime | split("T")[0]) })) as $p

# One entry per calendar date, daytime period preferred for the description.
| ([$p[].date] | unique | sort) as $dates
| ([ $dates[] as $d
     | ($p | map(select(.date == $d))) as $sameDay
     | ($sameDay | map(select(.isDaytime))[0]) as $day
     | ($sameDay | map(select(.isDaytime | not))[0]) as $night
     | ($day // $night) as $lead
     | {
         date: $d,
         name: ($day.name // $night.name // $d),
         hi: (if $day then temp($day.temperature) else null end),
         lo: (if $night then temp($night.temperature) else null end),
         short: ($lead.shortForecast // ""),
         pop: ([$day.probabilityOfPrecipitation.value, $night.probabilityOfPrecipitation.value]
               | map(select(. != null)) | if length == 0 then null else max end),
         wind: ($lead.windSpeed // "")
       } ] | .[0:$days]) as $daily

| ($current.properties // null) as $obs
| (if $obs and $obs.temperature.value != null then tempC($obs.temperature.value) else null end) as $nowT
| (if $obs and (($obs.heatIndex.value // $obs.windChill.value) != null)
   then tempC(($obs.heatIndex.value // $obs.windChill.value)) else null end) as $feels
| (($obs.textDescription // $daily[0].short // "")) as $nowText

# The bar shows current temperature when a station reported one, otherwise
# today's high -- never a blank pill.
| (if $nowT != null then $nowT else $daily[0].hi end) as $barT

| {
    label: $label,
    # Short enough for the popup header chip; the long form lives in rows[0].
    condition: $nowText,
    text: (if $barT == null then "--" else ($barT | tostring) + degShort end),
    icon: ($nowText | glyph),
    state: ($nowText | condState),
    tooltip: ($label + " · " + $nowText
              + (if $nowT != null then " · " + ($nowT | tostring) + deg else "" end)
              + (if $daily[0].hi != null and $daily[0].lo != null
                 then " · H " + ($daily[0].hi|tostring) + degShort + " L " + ($daily[0].lo|tostring) + degShort
                 else "" end)),
    rows: ([
      (if $obs != null then {
         label: "Now",
         value: (if $nowT == null then "--" else ($nowT | tostring) + degShort end),
         detail: ($nowText
                  + (if $feels != null and $feels != $nowT then " · feels " + ($feels|tostring) + degShort else "" end)
                  + (if $obs.relativeHumidity.value != null then " · " + ($obs.relativeHumidity.value | r0 | tostring) + "% rh" else "" end)
                  + (if $obs.windSpeed.value != null
                     then " · wind " + (($obs.windSpeed.value * 0.621371) | r0 | tostring) + " mph" else "" end)),
         state: ($nowText | condState)
       } else empty end)
    ] + [
      $daily[] | {
        label: .name,
        # Today can have no daylight period left, so show whichever exists
        # rather than a placeholder half like "-- / 79°".
        value: (if .hi != null and .lo != null
                then (.hi|tostring) + degShort + " / " + (.lo|tostring) + degShort
                elif .hi != null then (.hi|tostring) + degShort
                elif .lo != null then (.lo|tostring) + degShort
                else "--" end),
        detail: (.short + (if .pop != null and .pop > 0 then " · " + (.pop|tostring) + "%" else "" end)),
        state: (.short | condState)
      }
    ])
  }
