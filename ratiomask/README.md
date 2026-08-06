# ratiomask

Composition guide for 3ds Max: shows a **crop matte in the viewport** so you can
preview different image ratios **without ever touching the render settings**.

- **File:** `aioli-ratiomask.ms` — single file, no dependency
- **Compatibility:** 3ds Max 2026, and earlier versions with a Nitrous viewport
- **Renderer:** irrelevant (V-Ray, Corona…) — this only draws in the viewport
- **Version:** 1.3

---

## Why

The workflow it serves: **always render 1:1 (square)**, so you keep the freedom
to crop the image afterwards to any ratio — 16:9, 9:16, 4:5, 3:2.

While framing the camera you want to *see* the final crop without changing the
render ratio, which is what most helpers do by writing into `renderWidth` /
`renderHeight`. This one simply masks whatever falls outside the chosen ratio,
inside the render square. The render stays 1:1. It is a composition guide,
nothing more.

---

## Install and run

Drag `aioli-ratiomask.ms` into a 3ds Max window, or `Scripting > Run Script…`.
A "Ratio Crop Mask" window opens.

For a permanent button: `Customize > Customize User Interface > Toolbars`,
category **`aiolicollective`**, drag the **ratiomask** action onto a toolbar.

The path to this file is baked into the macro when you drag it in, so the button
survives a restart of Max and follows `git pull`. Move the clone and you just drag
the `.ms` in once more — see the [root README](../README.md#toolbar-buttons).

---

## Use

1. Get into the camera view (or perspective).
2. Tick **Enable overlay** — the viewport switches to safe frame display (see
   *Safe frame*) and the matte appears.
3. Pick a ratio from the list, or **Custom** for a free one.
4. Adjust **Offset** if you want the frame off-centre.

| Control | Role |
|---|---|
| **Enable overlay** | Turns the display on and off. |
| **Ratio** (list) | Crop ratio: fixed presets plus a **Custom** entry. |
| **Flip** | Swaps the orientation (16:9 ↔ 9:16, 4:5 ↔ 5:4…). Falls back to Custom when no preset matches. |
| **W / H** | Width / height of the **Custom** ratio. Live only while "Custom" is selected. |
| **Offset** | Shifts the frame on the free axis (vertical in landscape, horizontal in portrait). Expressed as a % of the slack: `0` = centred, `±100` = against an edge. Always clamped to the 1:1 square. |
| **C** | Recentres the offset (back to 0). |
| **Matte** | Shows/hides the matte bands, plus a colour picker (default near-black grey). |
| **Rule of thirds** | Thirds grid computed **inside the cropped ratio** (exact divisions), plus its colour (default white). |
| **Safe frame auto** | Lets the tool drive Max's safe frame (see below). Untick it to keep `Shift+F` entirely to yourself. |

---

## Pinning the overlay to one viewport

MAXScript can only draw into the **active** viewport, so an overlay follows every
click by nature: there is no way to paint into a viewport you are not looking at.
What the tool can do is stay quiet everywhere else.

It reads Max's own **render lock** — the padlock next to the viewport list in
Render Setup:

- **Lock closed** (`rendUseActiveView == false`): the overlay only shows in the
  viewport that will be rendered (`rendViewIndex`). Click another viewport and it
  simply does not appear there — the frame you are composing stays intact.
- **Lock open**: original behaviour, the overlay follows the active viewport.
- **One viewport** (single layout *or* a maximized viewport — both report
  `viewport.numViews == 1`): no ambiguity, it always draws.

Nothing to set in the tool: close the padlock on the view you render and the
overlay stops hopping around. The info line at the bottom of the window recalls
the locked index when you enable the overlay.

---

## Safe frame

The overlay lines up with the render area, which Max only displays correctly when
the safe frame is on. But `displaySafeFrames` is a **single global flag** —
MAXScript exposes no per-viewport safe frame — so turning it on for the locked
view turns it on everywhere.

With **Safe frame auto** ticked (the default) the tool flips that flag **when the
active viewport changes**: on when you enter the viewport the overlay draws in,
off when you leave it. Between two viewport changes it never writes to the flag,
so a manual `Shift+F` in another viewport holds until you switch viewports again.

Untick it and the tool stops writing to `displaySafeFrames` altogether. Bear in
mind the overlay is only aligned while the safe frame is on.

The "rezoom" you see when the safe frame comes on is normal — Max letterboxes the
viewport towards the 1:1 square — and it does not touch the camera.

---

## The matte is solid, and there is no opacity setting

The graphics window has **no alpha and no blend mode**: a colour is laid down at
full strength and the alpha of the colour you pick is ignored. The only way to
fake transparency is to **thin the fill out** — draw one row in two, in three —
which v1.2 offered as an `Opacity` slider. It was **removed in v1.3**: in use, a
solid matte is what the job wants.

If anything the matte still reads slightly translucent at full density, so the
open question is the opposite one: how to lay down *more* than 100 %. Two things
to try next time — a second pass of vertical lines over the same rectangle, and
checking what UI scaling on a high-DPI display does to 1 px lines.

---

## How it works

A **redraw callback** (`registerRedrawViewsCallback`) paints over the viewport on
every refresh:

1. `rcm_viewAllowed()` decides whether this viewport is the one to draw in (see
   above), `rcm_syncSafeFrame()` aligns the safe frame with that answer, and the
   callback bails out at once if this is not the viewport.
2. `rcm_field()` works out, in screen pixels, the rectangle matching the render
   area inside the viewport — same logic as the safe frame. On a 1:1 render, that
   is a centred square.
3. Inside it, the **target ratio rectangle** (`W/H`) is computed at full width
   (landscape ratio) or full height (portrait ratio), then the **offset** is
   applied on whichever axis has slack.
4. The **matte** is painted (4 bands around the rectangle), then the ratio
   outline, the rule of thirds and the ratio label.
5. UI handlers update global variables and fire a single `completeRedraw()` — no
   permanent redraw loop, so no CPU drain.

**Filling the matte:** the graphics window's filled primitives (`gw.wPolygon`,
`gw.triangle`) turned out to be unstable in Nitrous — missing triangles, stray
geometry. The matte is therefore painted with **abutting 1 px horizontal lines**
through `gw.wPolyline`, the only primitive that proved reliable here.

### Code landmarks (for picking this back up)

- State globals: `RCM_active`, `RCM_aspect`, `RCM_label`, `RCM_showMask`,
  `RCM_maskColor`, `RCM_showThirds`, `RCM_cropColor`, `RCM_offset`,
  `RCM_sfAuto`, `RCM_lastVP`.
- Functions: `rcm_viewAllowed()`, `rcm_syncSafeFrame()`, `rcm_field()`,
  `rcm_fillRect`, `rcm_rectOutline`, `rcm_draw` (the callback), `rcm_register` /
  `rcm_unregister`; on the UI side `pushState()`, `lockText()`, `setAspect`,
  `applyCustom()`, `isCustom()`.
- `rcm_syncSafeFrame` writes `displaySafeFrames` only when the active viewport
  index differs from `RCM_lastVP`. That guard is what stops the write from
  looping (writing triggers a redraw, which re-enters the callback) **and** what
  makes a manual `Shift+F` survive. Do not "simplify" it into a plain assignment.
- The tool body sits in a plain block; `aioli_ratiomask_open` is the global the
  macro calls. Keep it that way — a macroScript that carries the code instead of
  calling into it is a macroScript that ignores `git pull`.

---

## Notes and limits

- **No transparency**, see above.
- **Custom ratios are not persistent** between sessions.
- **1:1 render expected.** The tool adapts to any render ratio, but it is
  designed around a square render.

---

## Ideas

- Make the matte read as *fully* opaque (see above).
- Persist settings (last ratio, colours, offset) in an `.ini`.
- Grey out the W/H fields outside Custom mode.
- Several ratios at once (nested outlines, no matte, for comparison).
- A frame buffer (VFB) version alongside the viewport one.

---

## Changelog

- **1.3** — the `Opacity` slider is gone: the matte is solid again.
- **1.2** — matte opacity (simulated by thinning the fill) and **Safe frame
  auto**: the safe frame follows the viewport the overlay draws in instead of
  staying on everywhere.
- **1.1** — the overlay follows Max's render viewport lock instead of hopping to
  whichever viewport you click. Removed the "Render frame (1:1)" outline toggle
  and its colour picker (the matte already reads the render square).
- **1.0** — first version in use.

---

## Credits

Overlay mechanism inspired by **Image Comp Helper** (Warren Wnuk / C. Buelter).

MIT licence — © /ai.oli collective.
