#!/usr/bin/env python3
"""Replace mockup screens/background and rebuild the portable SVG. Python 3; no packages."""
from pathlib import Path
import argparse
import base64
import hashlib
import html
import json
import mimetypes
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parent
EDITABLE = ROOT / 'Tally-Devices-Editable.svg'
PORTABLE = ROOT / 'Tally-Devices.svg'
KEYS = {'mac': 'mac-screen', 'iphone': 'iphone-screen', 'ipad': 'ipad-screen', 'background': 'background-image'}
MIME = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.avif': 'image/avif'}


def element(svg, image_id):
    matches = list(re.finditer(r'<image\b[^>]*\bid="' + re.escape(image_id) + r'"[^>]*/>', svg))
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one image with id {image_id!r}.')
    return matches[0]


def update_image(svg, image_id, relative_path):
    match = element(svg, image_id)
    updated = re.sub(r'xlink:href="[^"]*"', 'xlink:href="' + html.escape(relative_path, quote=True) + '"', match.group(0))
    return svg[:match.start()] + updated + svg[match.end():]


def embed(svg):
    def replace(match):
        reference = html.unescape(match.group(1))
        if reference.startswith('data:'):
            return match.group(0)
        path = (ROOT / reference).resolve()
        if ROOT not in path.parents:
            raise ValueError(f'Asset must be inside this mockup folder: {reference}')
        mime = MIME.get(path.suffix.lower())
        if not mime:
            raise ValueError(f'Unsupported image extension: {path.suffix}')
        data = base64.b64encode(path.read_bytes()).decode('ascii')
        return f'xlink:href="data:{mime};base64,{data}"'
    return re.sub(r'xlink:href="([^"]+)"', replace, svg)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in KEYS:
        parser.add_argument('--' + key, type=Path, help=f'Replace the {key} image. Keep the source screen aspect ratio for edge-to-edge fit.')
    args = parser.parse_args()
    svg = EDITABLE.read_text()
    updates = {}
    for key, image_id in KEYS.items():
        source = getattr(args, key)
        if source is None:
            continue
        source = source.expanduser().resolve()
        extension = source.suffix.lower()
        if extension not in MIME or (key != 'background' and extension == '.svg'):
            raise ValueError(f'{key}: use PNG, JPEG, WebP, or AVIF; SVG is also supported for the background.')
        if not source.is_file():
            raise FileNotFoundError(source)
        target = ROOT / 'assets' / (('background' if key == 'background' else key + '-screen') + extension)
        if source != target.resolve():
            shutil.copy2(source, target)
        svg = update_image(svg, image_id, target.relative_to(ROOT).as_posix())
        updates[key] = {'source_filename': source.name, 'asset': target.relative_to(ROOT).as_posix(), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
    portable = embed(svg)
    EDITABLE.write_text(svg)
    PORTABLE.write_text(portable)
    if updates:
        history_file = ROOT / 'Replacements.json'
        history = json.loads(history_file.read_text()) if history_file.exists() else {}
        history.update(updates)
        history_file.write_text(json.dumps(history, indent=2) + '\n')
    print('Updated Tally-Devices-Editable.svg and Tally-Devices.svg (4000 × 2662).')
    print('The PNG is a separate export; export the updated SVG to refresh it.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
