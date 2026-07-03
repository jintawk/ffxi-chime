# Chime

A kitchen timer for FFXI (Windower 4). Set a timer with one command, watch it
count down on screen, and get an audible chime when it rings, even if you have
tabbed away.

```
//timer 5m Dinner
```

That's it. A draggable countdown window appears, turns yellow in the last
minute, flashes red in the last ten seconds, and rings when time is up.

## Install

Clone (or download) into your Windower addons folder:

```
cd <Windower>/addons
git clone https://github.com/jintawk/ffxi-chime.git Chime
```

Load it in game with `//lua load chime`, or add `lua load chime` to
`scripts/init.txt` to load it on startup.

## Why

FFXI is full of "come back in N minutes" moments: repops, Mog Garden,
cooldowns, real-world tea. The Timers plugin only tracks recasts and buffs.
Chime is for everything else.

## Commands

Aliases: `//chime`, `//timer`, `//tm`. Durations accept `5m`, `90s`, `1h30m`,
`1:30` (m:ss), `1:30:00` (h:mm:ss). A bare number means minutes.

| Command | What it does |
|---|---|
| `//timer 5m Dinner` | Start a timer (`add`, `start`, `new` also work) |
| `//timer at 21:30 Raid` | Ring at a clock time (`9:30pm` works too) |
| `//timer repeat 10m Repop` | Repeating timer (`every` works; or add `-r` to any timer) |
| `//timer at 19:00 Dinner -r` | Daily alarm |
| `//timer 30s Pull \| /p Go!` | Run a command when it rings (see below) |
| `//timer list` | List timers in chat (`ls`) |
| `//timer remove Din` | Cancel, by number or name; a prefix is enough (`rm`, `del`, `stop`, `cancel`) |
| `//timer pause Nap` / `resume Nap` | Freeze / continue a timer |
| `//timer extend Nap 2m` | Add time (`-30s` subtracts) |
| `//timer snooze` | Re-run the last finished timer (default 5m, or `snooze 10m`) |
| `//timer clear` | Remove all timers |
| `//timer sound bell` | Pick alert sound; `//timer sounds` lists them, `//timer test` previews |
| `//timer set <key> <value>` | Tweak settings (below) |
| `//timer pos <x> <y>` | Move the window, or just drag it |
| `//timer help` | Cheat sheet in chat |

With a single timer running, `remove`, `pause`, `resume` and `extend` don't
need a name at all: `//timer extend 2m` just works.

## Ring commands

Pipe anything after `|` and it runs when the timer rings:

```
//timer 30s Pull | /p Pulling now!
//timer 15m Buffs | /ja "Hasso" <me>
//timer 20m Farm | send Alt /follow Main
```

A command starting with `/` is typed into the game for you: chat lines, job
abilities, `/echo`, anything you could put in a macro. Anything else runs as a
Windower console command (`lua`, `send`, `exec`, `bind`, ...), exactly as if
typed in the console.

## The display

- Timers sort soonest-first; paused ones sink to the bottom, dimmed.
- Green, then yellow (last 60s), then flashing red (last 10s). Thresholds
  are configurable.
- Each timer gets a progress bar that drains as time passes.
- A finished timer flashes a TIME'S UP banner for a few seconds.
- Hidden automatically during cutscenes and when no timers are running.
- Drag it anywhere with the mouse.

## Sounds

Four bundled sounds, all synthesized: `chime` (doorbell, the default), `ding`
(single bright bell), `bell` (deep church bell), `alarm` (urgent beeps). Drop
any `.wav` into `sounds/` and it becomes selectable by filename.
`//timer set sound off` for silence.

The alert plays twice by default. `set repeats 1` for once, up to 10 for
can't-miss-it.

## Settings (`//timer set <key> <value>`)

| Key | Default | Meaning |
|---|---|---|
| `sound` | chime | Alert sound, or `off` |
| `repeats` | 2 | How many times the alert plays |
| `gap` | 2.5 | Seconds between alert plays |
| `warn` | 60s | Turn yellow below this |
| `crit` | 10s | Flash red below this |
| `linger` | 12 | Seconds the TIME'S UP banner stays |
| `snooze` | 5m | Default snooze duration |
| `size` / `font` | 11 / Consolas | Display text |
| `bg` | 200 | Background alpha (0-255) |
| `bar` / `barwidth` | on / 10 | Progress bars |
| `label` | 14 | Label column width |
| `max` | 8 | Max timers shown (rest collapse to "+N more") |
| `header` / `chat` | on / on | Header line / chat alerts |
| `icon_repeat` / `icon_pause` | ↻ / \|\| | Markers (change if your font lacks the glyph) |

## Persistence

Timers survive `//lua reload chime`, zoning, and relogging. They are stored
per character with absolute end times. If a timer expires while you are logged
out, Chime tells you when you return ("Dinner finished 12m ago"), and a
repeating timer re-arms itself to its next future ring.

## Notes

- Requires Windower 4. No dependencies beyond the standard `config` and
  `texts` libraries.
- The Timers plugin (recast tracking) is unrelated and unaffected; Chime
  deliberately uses the singular `//timer`.

## License

BSD 3-clause. See [LICENSE](LICENSE).
