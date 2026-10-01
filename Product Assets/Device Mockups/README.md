# Tally device mockup

**Canvas: 4000 × 2662 pixels.** The SVG, its viewBox, and the PNG export all use those exact dimensions.

- **`Tally-Devices.svg`** — portable, self-contained artwork. All three screenshots and the background are embedded. Send or import this single file.
- **`Tally-Devices-Editable.svg`** — the same artwork with linked screen images and background. Keep it beside the `assets` folder.
- **`Tally-Devices.png`** — full-resolution rendered preview, ready to use as a raster image.
- **`assets/`** — the three source screenshots and a separate editable vector background.
- **`replace-assets.py`** — a small Python 3 utility to replace screens/background and rebuild both SVG versions. It requires no additional packages.

The composition uses a shared ground plane: the laptop anchors the back, with the iPhone at the front left and the iPad at the front right. The devices overlap while leaving the central Mac app window and both mobile interfaces visible. The replaceable background is a cool graphite studio gradient.

## Chosen screens

| Device | Screenshot | Scenario |
| --- | --- | --- |
| Silver 16-inch MacBook Pro | `Tally-Mac-01.png` | Maya Chen’s **Cash Flow**, showing the September overview for an independent designer. |
| Burgundy iPhone 18 Pro Max | `Tally-iPhone-01.png` | Jordan Ellis’s **My Money**, showing salary, rent, and monthly commitments. |
| Purple 13-inch iPad Air | `Tally-iPad-03.png` | Sam Rivera’s **Family Finances**, showing the annual view with a bonus, insurance, and a trip deposit. |

The screenshots come from `../Product Screenshots`. These are the existing fictional product scenarios. Their files were copied byte-for-byte, embedded without recompression, and fitted without stretching or cropping the interface. The vector hardware adds the screen corners, camera housings, frames, and shadows; the original screenshots are untouched. `Sources.json` records their SHA-256 hashes.

## Replace a screen or the background

The easiest option is to replace `assets/mac-screen.png`, `assets/iphone-screen.png`, or `assets/ipad-screen.png` with your new screenshot. Then run:

```sh
python3 replace-assets.py
```

For a file elsewhere on your Mac, run any combination of:

```sh
python3 replace-assets.py \
  --mac "/path/to/new-mac-screen.png" \
  --iphone "/path/to/new-iphone-screen.png" \
  --ipad "/path/to/new-ipad-screen.png" \
  --background "/path/to/new-background.svg"
```

Use the original aspect ratios for an edge-to-edge display fit:

- Mac: **3456 × 2234**
- iPhone: **1320 × 2868**
- iPad: **2732 × 2048**, landscape
- Background: **4000 × 2662**

Screen images use `preserveAspectRatio="xMidYMid meet"`, so another aspect ratio is fitted without distortion. The background uses `slice`, so another ratio fills the canvas and may crop at its edges. PNG, JPEG, WebP, and AVIF replacements are supported; the background also accepts SVG. PNG retains the sharpest app text.

The replacement script updates both SVGs. Export the updated portable SVG again when you want a refreshed PNG; the existing PNG is a snapshot, not a live preview.

## Edit in a vector application

Import the self-contained SVG. The four top-level groups are:

1. `background`
2. `macbook-pro-16-silver`
3. `ipad-air-13-purple`
4. `iphone-18-pro-max-burgundy`

Each device has a separately named display group. The replaceable image IDs are `mac-screen`, `iphone-screen`, and `ipad-screen`; `background-image` controls the background. Device materials use named gradients. Every frame and camera housing remains vector artwork. Hide the `background` group for a transparent composition, or edit `assets/background.svg` and regenerate the portable file.

The linked SVG opens directly in desktop browsers. When embedding an SVG in a website’s `<img>`, use the self-contained version so browser restrictions on external SVG image resources do not hide the screens.

## Hardware references

The artwork is an original front-facing illustration, with approximate metal finishes and hardware details. It is not an Apple-supplied marketing template. Screen proportions follow the supplied native captures and Apple’s specifications:

- [iPhone 18 Pro and Pro Max specifications](https://www.apple.com/iphone-18-pro/specs/)
- [MacBook Pro specifications](https://www.apple.com/macbook-pro/specs/)
- [iPad Air specifications](https://www.apple.com/ipad-air/specs/)

The silhouettes are scaled independently for the composition. They are not a physical size comparison. The Mac screenshot retains its original desktop and normal-size Tally window.
