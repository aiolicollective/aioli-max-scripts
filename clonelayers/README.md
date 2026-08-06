# clonelayers

Clone a selection in 3ds Max and get the **whole layer / sub-layer tree rebuilt**
alongside it, with a prefix, a suffix, or an auto-incremented number.

- **File:** `aioli-clonelayers.ms` — single file, no dependency
- **Compatibility:** 3ds Max 2016 → 2026+
- **Version:** 1.0

---

## The problem

Native cloning (`Ctrl+V` / `Clone`) drops the copies into the current layer or
the source layer. It never duplicates the layer structure. On a scene organised
as a tree — `Building > Floor_01 > Joinery` — producing a variant (a low-poly
pass, an export version, a design alternative) means rebuilding the hierarchy by
hand and moving objects into it one at a time.

This does it in one click. Every source layer is mapped to a target layer
carrying the modified name, and the chain of parents is rebuilt **recursively**.

---

## Install and run

Drag `aioli-clonelayers.ms` into a 3ds Max window, or `Scripting > Run Script…`.
The panel opens and a macro is registered under the **`aiolicollective`** category
(action `clonelayers`) for a toolbar button or a keyboard shortcut.

The path to this file is baked into the macro when you drag it in, so the button
survives a restart of Max and follows `git pull`. Move the clone and you just drag
the `.ms` in once more — see the [root README](../README.md#toolbar-buttons).

Settings are remembered between sessions in an `.ini` in `getDir #plugcfg`.

---

## How far up the tree it goes

The rebuild is bounded by the **lowest common ancestor** of the source layers —
the smallest subtree that contains them all. That subtree is duplicated whole,
including intermediate grouping layers that hold no object of their own. Above
it, nothing is recreated, and the new tree lands at the root of the scene. This
is automatic, there is no setting for it.

On `Project > Building > Floor_01 > (Walls, Floors)`, cloning objects from
`Walls` and `Floors`: the common ancestor is `Floor_01`, the result is
`Floor_01_LP > (Walls_LP, Floors_LP)` at the root. `Floor_01` is duplicated even
though it holds no object itself, while `Project` and `Building` are ignored.

If the cloned objects come from disjoint branches with no common ancestor, the
walk goes up to the scene root and each branch is rebuilt from its own head
layer.

---

## Naming

Two mutually exclusive modes.

**Prefix / suffix** — the two fields wrap the source name.

**Increment trailing number** — the number at the end of the name is
incremented: `Floor_001` becomes `Floor_002`, `Floor001` becomes `Floor002`, and
the original zero-padding width is kept (`Wall_099` → `Wall_100`). A name with no
trailing number is treated as carrying an implicit 001 and gets `_002`. The
prefix and suffix fields are disabled in this mode.

The step is **shared across the whole batch**: the script looks for the smallest
step for which *every* target name is free. That avoids an inconsistent set like
`Floor_002` / `Walls_004` just because `Walls_002` was already taken somewhere
else in the scene. The search runs on layer names; object name collisions are
handled by the dedup option.

| Control | Effect |
|---|---|
| Apply to layers | Target layers carry the modified name. Unticked, the clones stay in the original layers. |
| Apply to objects | Clones carry the modified name. Unticked, they keep Max's automatic numbering. |
| Avoid duplicate object names | The wanted name is used as-is when it is free; `uniqueName` only kicks in on an actual collision. |

---

## Clone mode

| Mode | Behaviour |
|---|---|
| Copy | Fully independent of the original. |
| Instance | Two-way link: any edit propagates both ways. |
| Reference | The bottom of the modifier stack is shared with the original; modifiers added above the separator stay local to the clone. Useful for LODs and for variants built on a common base. |

---

## Options

| Control | Effect |
|---|---|
| Copy layer properties | Copies colour, renderable, box mode, backface cull, shadows, atmospherics, plus the visible / hidden / frozen states, from the source layer to the created one. |
| Force new layers visible / unfrozen | Overrides the option above for those three states. Useful when the source layers are hidden. |
| Include linked children | Passes `expandHierarchy:true` to `cloneNodes`: the descendants of the selected objects (object hierarchy links) are cloned and filed too. |
| Select the clones when done | Leaves the new selection active so you can chain another operation. |

A live counter shows the size of the selection (`#selectionSetChanged` callback)
and disables the button when nothing is selected. After a run it reports how many
objects were cloned, how many layers were created or reused, and how many objects
could not be filed.

---

## Behaviour and edge cases

- **Nothing is written to the source scene.** Source objects and layers are only
  ever read.
- **An existing target layer is reused**, not duplicated, and its properties are
  not overwritten. It is only reparented if it currently sits at the root — a
  layer you filed by hand is never moved by a second run.
- **Empty prefix and suffix with layer renaming on**: the target layer would be
  the source layer, so the clones would stay put. A confirmation is asked.
- **Layer names** are unique scene-wide in 3ds Max, sub-layers included. The
  source → target mapping relies on that guarantee.
- **Duplicate object names** do not affect instancing, which is a link between
  objects rather than a name lookup. They do break `$node` resolution in
  MaxScript and upset FBX / glTF / USD exports and XRefs — hence the dedup
  option, on by default.
- **Placement failure**: if a layer cannot be created (invalid name), the clone
  stays in its original layer and is counted in the end report.
- **Undo**: `Ctrl+Z` removes the cloned objects, but layer creation is not
  reliably undoable in 3ds Max — empty layers can survive and have to be deleted
  by hand in the Layer Explorer. That is an application limitation, not a script
  one.

---

## How it works

1. Clones the selection through `maxOps.cloneNodes`, retrieving the real list of
   processed nodes (`actualNodeList`) and of created nodes (`newNodes`), which
   match index for index.
2. Analyses the batch before creating anything: collects the source layers
   actually involved, works out the lowest common ancestor that bounds the walk
   up, and computes the shared step in number mode — over every layer that will
   be recreated, intermediates included.
3. For each (source, clone) pair: renames the clone, resolves the target layer
   through a recursive function that walks the source layer's `getParent()` chain
   up to a batch root, creating missing layers and linking them with `setParent`,
   then adds the clone through `addNode`.
4. A lookup table (source layer name → target layer) stops a layer being
   processed twice and guards against loops.
5. The whole thing sits inside an `undo` block, with
   `disableSceneRedraw` / `enableSceneRedraw` for large selections.

---

## Origin

Rewrite of a short script found online, which set out the basic idea but only
walked up one level of parent, passed its selection to `actualNodeList` by value
instead of by reference (`&`), and hard-coded its suffix and clone mode. This
version adds full recursion, the configuration UI, name deduplication, layer
property copying, the undo block and the edge case handling.

MIT licence — © /ai.oli collective.
