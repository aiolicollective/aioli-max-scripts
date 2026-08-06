# ratiomask

Composition guide for 3ds Max: shows a **crop matte in the viewport** so you can
preview different image ratios **without ever touching the render settings**.

- **File:** `aioli-ratiomask.ms` — single file, no dependency
- **Compatibility:** 3ds Max 2026, and earlier versions with a Nitrous viewport
- **Renderer:** irrelevant (V-Ray, Corona…) — this only draws in the viewport
- **Version:** 1.1

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
   *Notes*) and the matte appears.
3. Pick a ratio from the list, or **Custom** for a free one.
4. Adjust **Offset** if you want the frame off-centre.

| Control | Role |
|---|---|
| **Enable overlay** | Turns the display on and off. Also turns Max's safe frame on. |
| **Ratio** (list) | Crop ratio: fixed presets plus a **Custom** entry. |
| **Flip** | Swaps the orientation (16:9 ↔ 9:16, 4:5 ↔ 5:4…). Falls back to Custom when no preset matches. |
| **W / H** | Width / height of the **Custom** ratio. Live only while "Custom" is selected. |
| **Offset** | Shifts the frame on the free axis (vertical in landscape, horizontal in portrait). Expressed as a % of the slack: `0` = centred, `±100` = against an edge. Always clamped to the 1:1 square. |
| **C** | Recentres the offset (back to 0). |
| **Matte** | Shows/hides the matte bands, plus a colour picker (default near-black grey). |
| **Rule of thirds** | Thirds grid computed **inside the cropped ratio** (exact divisions), plus its colour (default white). |
| **Max safe frame** | Mirrors and drives Max's native safe frame. |

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

## How it works

A **redraw callback** (`registerRedrawViewsCallback`) paints over the viewport on
every refresh:

1. `rcm_viewAllowed()` decides whether this viewport is the one to draw in (see
   above); if not, the callback bails out at once.
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
through `gw.wPolyline`, the only primitive that proved reliable here. Visually it
reads as a solid fill.

### Code landmarks (for picking this back up)

- State globals: `RCM_active`, `RCM_aspect`, `RCM_label`, `RCM_showMask`,
  `RCM_maskColor`, `RCM_showThirds`, `RCM_cropColor`, `RCM_offset`.
- Functions: `rcm_viewAllowed()`, `rcm_field()`, `rcm_fillRect`,
  `rcm_rectOutline`, `rcm_draw` (the callback), `rcm_register` /
  `rcm_unregister`; on the UI side `pushState()`, `lockText()`, `setAspect`,
  `applyCustom()`, `isCustom()`.
- The tool body sits in a plain block; `aioli_ratiomask_open` is the global the
  macro calls. Keep it that way — a macroScript that carries the code instead of
  calling into it is a macroScript that ignores `git pull`.

---

## Notes and limits

- **Safe frame required.** The overlay lines up with the render area, which Max
  only displays correctly when the safe frame is on, so it is turned on
  automatically. The "rezoom" you see when enabling is normal — Max letterboxes
  the viewport towards the 1:1 square — and it does not touch the camera.
- **The matte is opaque.** No alpha in the graphics window, so it is a flat fill.
  Picking a dark grey rather than black keeps a bit of visual context.
- **Custom ratios are not persistent** between sessions.
- **1:1 render expected.** The tool adapts to any render ratio, but it is
  designed around a square render.

---

## Ideas

- Persist settings (last ratio, colours, offset) in an `.ini`.
- Adjustable fill step (a line every 2 px) to lighten drawing on large viewports.
- Grey out the W/H fields outside Custom mode.
- Semi-transparent darkening, if a blend method ever becomes available.
- Several ratios at once (nested outlines, no matte, for comparison).
- A frame buffer (VFB) version alongside the viewport one.

---

## Changelog

- **1.1** — the overlay follows Max's render viewport lock instead of hopping to
  whichever viewport you click. Removed the "Render frame (1:1)" outline toggle
  and its colour picker (the matte already reads the render square).
- **1.0** — first version in use.

---

## Credits

Overlay mechanism inspired by **Image Comp Helper** (Warren Wnuk / C. Buelter).

MIT licence — © /ai.oli collective.
