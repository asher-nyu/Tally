# Tally icon — paired folds

The current icon replaces the literal five tally marks with two opposing, rounded folds. The ivory form turns inward at the top; the jade form turns inward at the bottom. Together they leave a continuous open channel through the center: a compact identity for money arriving, leaving, and remaining in balance.

The two forms share their weight and corner language. Their asymmetry comes from direction, not from arbitrary differences in size. The result is intended to stay recognizable as a silhouette, including in a single color.

## Current app asset

The application uses [`Sources/TallyIcon.icon`](../../Sources/TallyIcon.icon), the existing native Icon Composer document. Its asset references, colors, and native material parameters have been updated for this design; no new document format was invented. Open this document in Icon Composer for the final material and appearance review.

The compiler resource name is `TallyIcon` in both build configurations. The original `AppIcon` resource name retained a stale five-mark Dock presentation during development even though the compiled catalog, ICNS, and system icon lookup all returned the paired folds. The resource rename and app registration refresh preserve the native composition; a subsequent automated Mac launch was visually verified with the current Dock icon.

The foreground source files are:

- `01-Incoming-Fold.svg` — ivory **#F5FFF9**, the upper-left fold, front layer.
- `02-Outgoing-Fold.svg` — pale jade **#B3EED1**, the opposing lower-right fold, back layer.

Identical copies are installed in the `.icon/Assets` directory. Both SVGs have a transparent **1024 × 1024** canvas. They contain only filled paths, with no masks, filters, strokes, text, embedded bitmaps, gradients, or baked shadows. The enclosing app-icon shape remains the system's responsibility.

## Saved native composition

The saved `icon.json` uses the existing document schema:

- One group, with the incoming fold above the outgoing fold.
- Solid deep-forest background **#075244**, stored as `extended-srgb:0.02745,0.32157,0.26667,1.00000`.
- Native neutral shadow, opacity **0.22**.
- Native translucency enabled, value **0.18**.
- Shared square-platform artwork and the existing watchOS circle support.
- Explicit Dark fill **#F5FFF9** for the incoming fold, stored in its native `fill-specializations`. This preserves the ivory surface after Icon Composer's automatic Dark treatment made that fold too dark. The outgoing fold and Mono treatment remain automatic; there are no transform overrides.

These restrained material values leave broad surfaces for Icon Composer's light and glass treatment while keeping the geometry clear. They are design settings, not an Apple-provided preset.

## Optical geometry and checks

The mark occupies coordinates **244–780** in both axes. The fold body is **160 units** wide. The two narrow openings are **64 units** wide, equivalent to two pixels in a 32-pixel icon. The center channel is wider, and the corners use separate convex and concave radii so the turns stay open.

The following local previews show source geometry only:

- `Tally-geometry-proof.svg` and `.svg.png`: full-size flat proof with an approximate enclosing shape.
- `Tally-small-size-proof.svg` and `.svg.png`: color and one-color comparisons, with 128-, 64-, 32-, and 16-unit icons in each row.
- `Tally-proof-128.png`, `Tally-proof-64.png`, `Tally-proof-32.png`, and `Tally-proof-16.png`: actual pixel-size rasterizations for thumbnail inspection.

The geometry and one-color proofs were visually checked. They do **not** simulate Icon Composer's rendered glass, native masks, Dark appearance, or Mono appearance. The paired-fold composition was subsequently inspected in Icon Composer's Default, Mono, and Dark previews, including the saved explicit Dark fill. Xcode builds the app icon directly from the layered `.icon` document.

The older files under `Design/Previews` depict the superseded tally-mark design and are not the current icon.

## Editing and final review

Open `Sources/TallyIcon.icon` in Icon Composer. Preserve the full 1024 × 1024 layer canvases and their existing registration when replacing artwork. Set background and material effects in Composer. Review Default, Dark, Mono, square-platform, and small-size previews after saving; check that the two openings remain clear when native lighting and shadows are applied.

## Apple references

- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [Icon Composer](https://developer.apple.com/icon-composer/)
- [App icons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons)
