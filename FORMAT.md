# The `.macpaper` wallpaper format

A MacPaper wallpaper is a folder whose name ends in `.macpaper`. Finder shows it as a single
file and double‑clicking imports it into MacPaper Engine. Everything the wallpaper needs lives
inside it; everything *you* choose (control values, crop, speed, color, volume) lives in the app
and is never written back into the package.

```
Koi Dusk.macpaper/
  manifest.json        what to draw and which knobs exist
  poster.heic          frame 0 at canvas resolution — shown instantly, used for the lock screen
  media/base.mov       HEVC or H.264, any length, loops gaplessly
  images/plate.heic    stills (HEIC, PNG, JPEG)
  images/plate-depth.png
  masks/water.png      white = effect applies / particles spawn
  shaders/ripple.metal Metal shading language, see "Shaders"
  thumbs/…             thumbnails for gallery choices
```

Paths in the manifest are relative to the package and must stay inside it.

## manifest.json

```json
{
  "format": 1,
  "id": "4D0E5E8C-6B4B-4F59-9C5F-2C1D3A0E9B11",
  "title": "Koi Dusk",
  "author": "Adil",
  "description": "Koi circling under lanterns.",
  "tags": ["water", "calm", "night"],
  "canvas": { "width": 3840, "height": 2160 },
  "focus": [0.5, 0.45],
  "poster": "poster.heic",
  "fps": 30,
  "background": "#000000",
  "drift": 0.3,
  "audio": { "src": "audio/ambience.m4a", "volume": 0.8 },
  "layers": [ … ],
  "controls": [ … ]
}
```

| Field | Meaning |
|---|---|
| `format` | Always `1`. |
| `id` | A UUID. Never change it — the app keys your settings by it. |
| `title`, `description` | A string, or a localized object `{"en": "…", "ru": "…"}`. |
| `canvas` | The design size in pixels. Displays with another aspect ratio see a crop of it, unless the user picks Show All. |
| `focus` | The point (0…1, origin top‑left) the crop keeps in view. Users can override it per display. |
| `poster` | Optional; when missing, MacPaper renders frame 0 into its own cache (never into the package). An authored poster must be frame 0 so the hand‑off to live playback is invisible. |
| `fps` | The rate the wallpaper is designed for. The app caps it further if the user asks. |
| `background` | Color under the bottom layer. |
| `drift` | 0…1. Slow automatic parallax sway so depth layers move even without a mouse (screen saver). |
| `audio` | Optional looping sound. Video layers may also carry their own audio. |
| `captions` | Optional lines a character says over a video layer — see [Captions](#captions). |
| `reactions` | Optional short clips a video layer plays when something happens — see [Reactions](#reactions). |

Colors are `"#rrggbb"`, `"#rrggbbaa"` or `[r, g, b, a]` with 0…1 components.

## Layers

Layers are drawn bottom to top. Every layer has:

| Field | Default | Meaning |
|---|---|---|
| `id` | — | Unique, letters/digits/`-`/`_`. Controls target layers by it. |
| `type` | — | `video`, `image`, `shader`, `particles`. |
| `opacity` | `1` | 0…1. |
| `visible` | `true` | |
| `blend` | `normal` | `normal`, `add`, `screen`, `multiply`. |
| `rect` | `[0,0,1,1]` | Video and image layers: where the layer sits on the canvas: x, y, width, height (0…1, top‑left origin). Shader and particle layers always cover the canvas; particles use `area`. |
| `fit` | `fill` | How media fits its rect: `fill`, `fit`, `stretch`. |
| `parallax` | `0` | How far the layer shifts with the pointer / drift, as a fraction of the canvas. Background ≈ 0.005, foreground ≈ 0.03. |
| `daypart` | `always` | `day` or `night` fades the layer with the time of day (sunrise ≈ 7:00, sunset ≈ 19:00). |

### `video`

```json
{ "id": "base", "type": "video", "src": "media/base.mov", "rate": 1, "freeze": null, "volume": 1,
  "intro": false, "crossfade": 0 }
```

- HEVC (Main or Main10) or H.264 in `.mov`/`.mp4`. HEVC with alpha works for animated cut‑outs.
- Videos loop gaplessly. Make the last frame flow into the first (with AI video: use the same
  image as start and end frame; or let the importer crossfade the loop).
- `freeze`: `null` plays; a number 0…1 holds that point of the clip.
- `intro`: with `freeze`, a clip the user switches to plays from its start and then holds at
  `freeze` — an entrance. When the wallpaper starts it shows the held frame straight away.
- `crossfade`: seconds, up to 5. When `src` changes, the new clip fades in over the last frame of the old
  one. A looping clip with a crossfade plays to its end and fades back into its start, for clips
  whose ends don't match.
- A wallpaper that is just one full‑canvas video plays on the zero‑copy video path — no GPU work at all.

### `image`

```json
{ "id": "plate", "type": "image", "src": "images/plate.heic",
  "depth": "images/plate-depth.png", "depthStrength": 0.03, "parallax": 0.01 }
```

- `depth`: grayscale depth map, white = near. The image is displaced by depth as the pointer
  moves, which reads as real 3D.
- `depthStrength`: displacement of the nearest pixels, as a fraction of the canvas.

### `particles`

GPU‑simulated sprites. Start from a `preset` and override what you need.

```json
{ "id": "flies", "type": "particles", "preset": "fireflies", "count": 120,
  "area": [0, 0.4, 1, 0.6], "color": "#ffd27a" }
```

| Field | Meaning |
|---|---|
| `preset` | `snow`, `rain`, `fireflies`, `dust`, `embers`, `bokeh`, `stars`, `bubbles`, `petals`. |
| `count` | Live particles (max 20000). |
| `area` | Spawn rectangle on the canvas. |
| `mask` | Optional spawn mask image; particles only spawn on white. |
| `lifetime` | `[min, max]` seconds. |
| `speed` | `[min, max]` canvas heights per second. |
| `direction`, `spread` | Degrees. 0 = right, 90 = down. |
| `gravity`, `wind` | `[x, y]` canvas heights per second². |
| `turbulence`, `turbulenceScale` | Swirl strength and size. |
| `size` | `[min, max]` canvas heights. |
| `color`, `colorEnd` | Color over life. |
| `fade` | `[in, out]` as fractions of life. |
| `twinkle` | 0…1 brightness flicker. |
| `shape` | `dot`, `glow`, `streak`, `ring`, `petal`, `texture`. |
| `texture` | Sprite image for `shape: "texture"`. |
| `spin` | `[min, max]` radians per second (textures). |
| `stretch` | Streak length relative to speed. |
| `mouse` | Pointer repel (+) or attract (−) strength. |

### `shader`

```json
{ "id": "ripple", "type": "shader", "src": "shaders/ripple.metal",
  "params": {
    "strength": { "type": "float", "value": 0.4 },
    "tint":     { "type": "color", "value": "#9fd3ff" },
    "origin":   { "type": "float2", "value": [0.5, 0.7] }
  },
  "textures": { "mask": "masks/water.png" } }
```

Parameter types: `float`, `float2`, `float3`, `float4`, `color` (→ `float4`), `int`, `bool` (→ `int`).

## Shaders

A shader file contains one function named `effect` (plus any helpers you like). A file with several
effects can name the one a layer uses with the layer's `function` key (a plain MSL function name).

```metal
float4 effect(Pixel px, Frame frame, Params params, Inputs in) {
    float m = in.mask.sample(in.linear, px.uv).r;
    float2 wobble = float2(sin(px.uv.y * 40 + frame.time * 2), cos(px.uv.x * 40 + frame.time * 2)) * 0.002;
    float3 below = in.source.sample(in.linear, px.screen + wobble * m * params.strength).rgb;
    return float4(mix(below, below * params.tint.rgb, m * 0.2), 1);
}
```

Return straight (not premultiplied) RGBA. The app premultiplies, applies `opacity` and `blend`.

The app generates everything around your function, so the types always match:

```metal
struct Pixel {
    float2 uv;      // canvas position 0…1, origin top-left — use for your textures and procedural work
    float2 screen;  // position in `in.source` (everything drawn below this layer)
    float2 coord;   // output pixel coordinate
};

struct Frame {
    float  time;        // seconds since start, scaled by the user's speed setting
    float  delta;       // seconds since the previous frame
    float2 resolution;  // output size in pixels
    float2 canvas;      // manifest canvas size in pixels
    float2 mouse;       // pointer in canvas uv
    float2 parallax;    // -1…1, pointer + drift combined
    float  daylight;    // 0 night … 1 day
    float  dark;        // 1 in Dark Mode
    float  audioLevel;  // 0…1 system audio loudness (when audio-reactive is on)
    float4 audio[4];    // 16 spectrum bands, low → high
};

struct Params { /* your params, by name */ };

struct Inputs {
    texture2d<float> source;  // layers below, sample with px.screen
    texture2d<float> mask;    // …one member per entry in "textures", sample with px.uv
    sampler linear;           // linear, clamp
    sampler repeat;           // linear, repeat
    sampler nearest;          // nearest, clamp
};
```

Helpers available in every shader:

| Function | |
|---|---|
| `mp_hash(float2) → float`, `mp_hash2(float2) → float2` | Fast pseudo‑random 0…1. |
| `mp_noise(float2) → float` | Smooth value noise 0…1. |
| `mp_fbm(float2, int octaves) → float` | Fractal noise 0…1. |
| `mp_luma(float3) → float` | Perceived brightness. |
| `mp_rotate(float2 p, float angle) → float2` | |
| `mp_aspect(Frame) → float` | Canvas width / height — multiply `uv.x` by it for round shapes. |
| `mp_hsv2rgb(float3)`, `mp_rgb2hsv(float3)` | |

Rules of thumb:

- Read `in.source` only if you need what's below; layers that don't are cheaper.
- Keep loops bounded and small. A shader that faults or hangs the GPU three times within half a minute is
  switched off, and the rest of the wallpaper keeps playing without it.
- Shaders compile on import. Errors are reported against your file's own line numbers.

## Controls

Controls are knobs the *app* draws natively — in the inspector, and optionally in the menu bar.
The wallpaper only declares them and what they change. Values are stored per wallpaper by the app.

```json
"controls": [
  { "type": "section", "label": "Look", "controls": [
    { "id": "outfit", "type": "choice", "style": "gallery", "label": "Outfit", "quick": true,
      "target": "base.src",
      "options": [
        { "label": "After Dark", "value": "media/after-dark.mov", "thumb": "thumbs/after-dark.jpg" },
        { "label": "Holiday",    "value": "media/holiday.mov",    "thumb": "thumbs/holiday.jpg" }
      ] },
    { "id": "glow", "type": "color", "label": "Rim light", "target": "rim.params.tint" }
  ]},
  { "id": "mode", "type": "choice", "style": "segmented", "label": "Playback",
    "options": [
      { "label": "Play",   "value": "play",   "set": { "base.freeze": null } },
      { "label": "Freeze", "value": "freeze", "set": { "base.freeze": 0.5 } }
    ] },
  { "id": "freezeAt", "type": "slider", "label": "Freeze at", "min": 0, "max": 1, "unit": "%",
    "target": "base.freeze", "visibleWhen": { "mode": "freeze" } },
  { "id": "snow", "type": "toggle", "label": "Snow", "target": "snow.visible" },
  { "id": "light", "type": "point", "label": "Light position", "target": "rays.params.origin" }
]
```

| Field | Meaning |
|---|---|
| `id` | Unique. Values are stored under it. |
| `type` | `toggle`, `slider`, `choice`, `color`, `point`, `section`. |
| `label`, `help` | Text (or localized object). |
| `target` | A property path, or a list of paths, the value is written to. |
| `default` | Optional — defaults to the target's value in the manifest. |
| `visibleWhen` | `{ "otherControl": value }` or `{ "otherControl": [values] }`. A hidden control doesn't apply, so several controls can share a target — e.g. one "freeze at" slider per outfit. |
| `quick` | Also show in the menu bar. |
| slider: `min`, `max`, `step`, `unit` | `unit` is one of `%`, `x`, `s`, `°`, `px` or omitted. |
| choice: `options`, `style` | `style`: `menu`, `segmented`, `list`, `gallery`. Each option has `label`, `value`, optional `thumb` and optional `set` — extra `{path: value}` writes. |
| choice: `cycle` | Optional suggested auto‑change: `"clip"` (next option each time the video ends) or a number of minutes. The user can change or turn it off. |
| color: `alpha` | Allow transparency. |
| section: `controls`, `collapsed` | Groups controls. |

Property paths are `layerId.property`:

| Layer | Properties |
|---|---|
| any | `opacity`, `visible`, `parallax`, `blend`, `rect` |
| video | `src`, `rate`, `freeze`, `volume` |
| image | `src`, `depth`, `depthStrength` |
| shader | `params.<name>`, `textures.<name>` |
| particles | every field in the particles table |
| scene | `scene.drift`, `scene.background`, `audio.volume`, `captions.lang`, `captions.idleEvery`, `reactions.enabled`, `reactions.cooldown`, `reactions.crossfade` |

## Captions

A character's lines, shown over the wallpaper as they make an entrance on a video layer:

```json
"captions": {
  "video": "look",
  "speaker": "Mira",
  "lang": "en",
  "idleEvery": 240,
  "lines": {
    "media/look-01.mov": {
      "enter":    [{ "en": "…", "zh": "…" }],
      "held":     [{ "en": "…", "zh": "…" }],
      "restored": [{ "en": "…", "zh": "…" }],
      "idle":     [{ "en": "…", "zh": "…" }]
    }
  }
}
```

Lines are keyed by the clip (`src`) the layer is playing. `enter` shows when a clip starts from its
beginning; `held` replaces it once an `intro` clip settles at `freeze` — the n‑th entrance pairs with
the n‑th held line, and successive entrances rotate. `restored` shows when the wallpaper opens already
holding the pose, and while it holds, an `idle` line comes every `idleEvery` seconds (0 = never).
`lang` is a language code from the lines, `auto` (the system language) or `off`; point a choice
control at `captions.lang` to let people pick. Captions are drawn by the app over the live wallpaper,
so `render` and posters don't include them.

## Reactions

A character can react to the person at the Mac. Each event plays one short clip on a video layer,
fades back to the loop where it left off, and doesn't repeat for `cooldown` seconds:

```json
"reactions": {
  "video": "base",
  "crossfade": 0.8,
  "cooldown": 30,
  "events": [
    { "on": "unlock", "clips": ["media/react-wave.mov"] },
    { "on": "return", "idle": 300, "clips": ["media/react-welcome.mov"] },
    { "on": "click",  "clips": ["media/react-look.mov", "media/react-wink.mov"], "cooldown": 20 },
    { "on": "time",   "at": ["23:30"], "clips": ["media/react-yawn.mov"] },
    { "on": "random", "every": 600, "clips": ["media/react-stretch.mov"] }
  ]
}
```

| Field | Meaning |
|---|---|
| `video` | The video layer that plays the clips. |
| `crossfade` | Seconds to fade into a clip and back to the loop; default 0.8. |
| `cooldown` | Seconds after a reaction before another can start; default 30. An event can set its own. |
| `enabled` | `false` turns them all off; point a toggle at `reactions.enabled` to let people choose. |
| `on` | `unlock` (the Mac is unlocked), `wake` (the display wakes), `return` (input again after `idle` seconds without any, default 300), `click` (a click on the visible desktop), `time` (`at`: `"HH:MM"` or a list), `random` (about every `every` seconds, default 600). |
| `clips` | One or more clips; they take turns. |

A reaction only plays while the wallpaper is playing and in view. Make each clip start and end close to
the loop's look — generated from the same still, with the camera locked — so the fades are short and
invisible. Captions work for reaction clips too: key their lines by the clip's path. People can turn
reactions off per wallpaper and try each one from the inspector; `macpaper://react?event=click` plays one
from Shortcuts.

The app adds its own controls to every wallpaper: framing (fill the display, show all of the canvas
with bars, or span one picture across every display), crop focus per display, speed, frame‑rate cap,
brightness, contrast, saturation, warmth, parallax strength, volume and mute, plus auto‑cycling any
choice control on a timer or each time the video ends, through all options or a chosen few.

## Command line

The app binary doubles as a tool for authoring (and for AI agents checking their work):

```
MacPaper.app/Contents/MacOS/MacPaper validate <pkg>
MacPaper.app/Contents/MacOS/MacPaper render   <pkg> --out frame.png [--size 1920x1080] [--time 3] [--set outfit=holiday]
MacPaper.app/Contents/MacOS/MacPaper poster   <pkg>
MacPaper.app/Contents/MacOS/MacPaper bench    <pkg> [--size 5120x2880] [--frames 300]
```

`validate` checks paths, targets, types and compiles every shader, printing
`file:line:col: error: …` diagnostics. `bench` prints CPU and GPU milliseconds per frame.

## URL commands

`macpaper://apply?id=<uuid>`, `macpaper://set?control=outfit&value=holiday[&id=<uuid>]`,
`macpaper://link?path=/path/to/Thing.macpaper` (links the folder in place and applies it — edits then show up live),
`macpaper://play?playlist=<name or id>`, `macpaper://next` (the next wallpaper of a playing playlist, or a shuffle),
`macpaper://react?event=<on>`, `macpaper://pause`, `macpaper://resume`, `macpaper://toggle`.
Use them from Shortcuts with *Open URL*.

## Making wallpapers with AI

1. Generate a still at your display's aspect ratio, then upscale to at least the canvas size.
2. For motion, run image‑to‑video with the **same image as the first and last frame** — the clip
   then loops seamlessly. Upscale to 4K.
3. Drop the files into MacPaper's **Create** page. It converts video to HEVC, makes the poster,
   finds the subject for parallax, and lets you add effects and paint masks.
4. To write shaders or whole wallpapers with an AI, use **Copy AI Guide** in the app — it copies
   this document — and point the AI at a linked package folder. MacPaper reloads the wallpaper live
   whenever a file in it changes and shows compile errors with line numbers.
