<p align="center">
  <img src="images/Sbar.svg" />
</p>

<p align="center">
<a href="https://felixkratz.github.io/SketchyBar/setup">Install</a>
<span> • </span>
<a href="https://felixkratz.github.io/SketchyBar/config/bar">Documentation</a> 
<span> • </span> 
<a href="https://github.com/FelixKratz/SketchyBar/discussions/47?sort=top">Setups</a>
<span> • </span> 
<a href="https://github.com/FelixKratz/SketchyBar/discussions/12?sort=top">Plugins</a>
</p>

<p align="center">
<a href="https://opensource.org/licenses/"><img src="https://img.shields.io/badge/License-GPL%20v3-blue.svg"></a>
<a href="https://github.com/FelixKratz/SketchyBar/releases"><img src="https://img.shields.io/github/v/release/FelixKratz/SketchyBar.svg?style=flat&color=orange" /></a>
<a href="https://github.com/FelixKratz/SketchyBar/releases"><img src="https://img.shields.io/github/commits-since/FelixKratz/SketchyBar/latest.svg?color=orange"></a>
<a href="https://en.wikipedia.org/wiki/Free_and_open-source_software"><img src="https://img.shields.io/badge/FOSS-100%25-green.svg?style=flat"></a>
</p>

<p align="center">
This bar project aims to create a highly flexible, customizable, fast and powerful status bar replacement for people that like playing with
shell scripts.
</p>

![](images/example.png)
<p align="center">
<a href="https://github.com/FelixKratz/SketchyBar/discussions/47?sort=top">More Setups</a>
</p>



## Features
* Full *configurability* at any time
* Dynamic *animation* system
* Powerful *scripting* and *event* system
* Optimized to be *fast* and *efficient*
* Interactive *mouse* support
* Support for displaying macOS menu bar apps (*aliases*)
* Can draw arbitrary *graphs*
* On-demand *popup* menus

The main design principle of this project is that *all* elements of the bar can
be added, removed and freely changed at any point in time. Thus, the
configuration of the bar is not *static*, rather it is possible to adapt the
appearance of the bar completely dynamically with the help of a powerful
event-driven scripting system at any point in time using the highly
configurable basic building blocks SketchyBar offers.

## Getting Started
Refer to the installation guide in the [documentation](https://felixkratz.github.io/SketchyBar/setup) to get the program set up.
Once this is sorted you can start to become familiar with the syntax of sketchybar by going through the default [*sketchybarrc*](https://github.com/FelixKratz/SketchyBar/blob/master/sketchybarrc) file and the default [*plugin scripts*](https://github.com/FelixKratz/SketchyBar/blob/master/plugins),
which are located in `~/.config/sketchybar/` and look like this:

![](images/default.png)

All commands and options are explained in detail in the relevant sections
of the configuration [documentation](https://felixkratz.github.io/SketchyBar/config/bar). You can try the commands directly from
the commandline to see which affect they have and how they alter the bar. Once you have become familiar with the syntax you can
look for a config to start from [here](https://github.com/FelixKratz/SketchyBar/discussions/47?sort=top) or start from scratch and customize
everything to your liking.

You might also enjoy looking at the [Tips & Tricks](https://felixkratz.github.io/SketchyBar/config/tricks) section
for some further tips on your journey. If you are searching for functional items you might want to check the
[plugins](https://github.com/FelixKratz/SketchyBar/discussions/12?sort=top) section if someone has already created what you are looking for.

Should you encounter things not working as you expect them to, please *do not* hesitate to open an [issue](https://github.com/FelixKratz/SketchyBar/issues), as
this is either a bug or a documentation problem and relevant in any case.

## Paneru workspaces

This fork can show [Paneru](https://github.com/karinushka/paneru)'s virtual
workspaces in space items. Paneru keeps several workspaces inside one macOS
Space, so Mission Control indices cannot tell them apart.

```bash
sketchybar --bar workspace_source=paneru

for i in 1 2 3 4 5; do
  sketchybar --add space space.$i left \
             --set space.$i associated_space=$i icon=$i \
                   click_script="paneru send-cmd window virtualnum $i"
done
```

With `workspace_source=paneru`:

- `associated_space=N` (or `space=N`) means Paneru workspace N on the
  display's current macOS Space. A space item is drawn on every display that
  has a workspace N, and hidden where there is none.
- `SELECTED` is true for the workspace each display shows.
- `space_change` reports each display's Paneru workspace number.
- `space_windows_change` reports the apps tiled on each Paneru workspace, in
  strip order. Floating windows stay on screen across workspaces, so they
  count toward none. Its `INFO` adds a `display` key, because every display
  has its own workspace 1:
  `{"space": 2, "display": 1, "apps": {"Safari": 1, "Terminal": 2}}`.

Paneru's own events reach scripts as `paneru_<event>`, with the event's JSON
line as `INFO`: `paneru_window_focused`, `paneru_window_title_changed`,
`paneru_windows_changed`, `paneru_virtual_workspace_changed` and
`paneru_display_changed`. Register one with `--add event` before subscribing:

```bash
sketchybar --add event paneru_window_focused \
           --subscribe window_title paneru_window_focused
```

`on_screen_changed` fires every few milliseconds while windows move and is not
forwarded. When a workspace disappears, `space_windows_change` reports it once
with `"apps": {}`.

`app.<name>` images look for an installed app bundle named `<name>.app` before
the running app's bundle identifier, so web apps that share one runtime (Firefox
PWAs, Chrome apps) show their own icons.

The bar runs `paneru subscribe` and re-reads `paneru query state` when the
workspace rows change. It finds `paneru` on `PATH`, then in `~/.cargo/bin`,
`/opt/homebrew/bin` and `/usr/local/bin`. While Paneru is not running, no
workspace is shown, and the bar reconnects when Paneru is back.
`workspace_source=native` (the default) restores Mission Control spaces.

## Menu bar icons on macOS 26 and later

macOS 26 draws every app's menu bar icon into one shared window, so the icons
no longer have windows for `alias` items to mirror. This fork finds them
through Accessibility instead, by app name:

```bash
sketchybar --query default_menu_items      # "Wispr Flow,1", "Stats,3", ...
sketchybar --add alias "Wispr Flow,1" right
```

`<app>,<n>` is the app's n-th icon from the left. The icon is cropped live from
the menu bar. An icon hidden behind the notch shows its app's icon instead.

macOS reserves blank space around some icons, which leaves uneven gaps between
aliases. `alias.trim=on` crops an alias to the columns its icon draws in. The
crop never shrinks, so the alias keeps a steady width as the icon's content
changes:

```bash
sketchybar --set "Stats,1" alias.trim=on
```

Clicking an alias without a `click_script` opens what the icon opens, under
the alias rather than in the menu bar:

* An icon with a menu shows a copy of it, read through Accessibility.
  Choosing an entry chooses the app's own menu item. This works for icons
  hidden behind the notch too.
* Any other icon is clicked, and the panel it opens is moved under the alias.
  A hidden icon's app is brought forward instead, since macOS has nowhere to
  open its panel.

This needs Screen Recording and Accessibility permission for the `sketchybar`
binary. macOS ties both to the code signature, so `install-local.sh` signs with
a stable identity. Clicks only reach the bar above the backstop level:
use `topmost=window` when windows never cover the bar.

## Notifications that carry their payload as text

A custom event tied to a distributed notification passes the notification's
`userInfo` as `$INFO`. Some apps put their payload in the notification's
`object` string instead; `$INFO` then holds that string. For example,
BetterDisplay's OSD notifications (with Settings > Application > Integration >
Dispatch OSD notifications on) arrive as JSON:

```bash
sketchybar --add event display_osd pro.betterdisplay.BetterDisplay.osd
# $INFO: {"controlTarget":"combinedBrightness","value":60,"maxValue":64,...}
```

## Documentation
For the full documentation of all commands and properties please refer to the [website](https://felixkratz.github.io/SketchyBar/config/bar).

If questions remain, feel free to consult the [Q&A](https://github.com/FelixKratz/SketchyBar/discussions/categories/q-a) section.

## Supporting
*You* can support this project is many ways:
- By *creating* issues and pull-requests if you encounter problems
- By *sharing* your [plugins](https://github.com/FelixKratz/SketchyBar/discussions/12) and [setups](https://github.com/FelixKratz/SketchyBar/discussions/47)
- By *starring* the project on GitHub
- If this project has value to you, consider quantifying it and *donating* to a charity of your choice. If you want to let me know about your donation, you
can contact me via [email](mailto:felix.kratz@tu-dortmund.de?Subject=Donation).
- If you want to support me directly, you can do so via [ko-fi](https://ko-fi.com/felixkratz)

## Credits
This project was forked from *[spacebar](https://github.com/cmacrae/spacebar)* and completely reimagined and rewritten. <br>
The original idea is based on the status bar that was included in *[yabai](https://github.com/koekeishiya/yabai)* before getting removed.


## Related Projects
- [SbarLua](https://github.com/FelixKratz/SbarLua): A Lua API for SketchyBar
- [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font): A symbol font for SketchyBar
- [SketchyBarHelper](https://github.com/FelixKratz/SketchyBarHelper): A header for C/C++ to directly communicate with SketchyBar

## Some animation examples

https://user-images.githubusercontent.com/22680421/211198711-45318f04-e96f-4aa1-a0ba-c7f30f050902.mp4


