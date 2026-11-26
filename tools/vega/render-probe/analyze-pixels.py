"""Measure native capture pixels without editing or synthesizing screenshots."""
import json
import sys
from pathlib import Path
from PIL import Image

root = Path(sys.argv[1] if len(sys.argv) > 1 else '.artifacts/vega-render-probe/runtime')
report = {'diagnosticOnly': True, 'captures': [], 'interpretation':
          'Native events and pixel samples are separate evidence. Compare both consecutive screenshots; '
          'this isolated fixture cannot verify production devices or remote artwork.'}
colors = [(225, 55, 65), (45, 180, 95), (50, 110, 220), (235, 195, 65)]

def fraction(image, rect, color, region=(.15, .15, .85, .85)):
    x, y, w, h = (rect[k] for k in ('x', 'y', 'width', 'height'))
    box = (round(x + w * region[0]), round(y + h * region[1]),
           round(x + w * region[2]), round(y + h * region[3]))
    if w <= 0 or h <= 0 or box[0] < 0 or box[1] < 0 or box[2] > image.width or box[3] > image.height:
        return {'outOfBounds': True, 'box': box}
    crop = image.crop(box)
    pixels = list(crop.getdata())
    close = sum(all(abs(a-b) <= 3 for a, b in zip(pixel, color)) for pixel in pixels)
    return {'expectedRGB': color, 'matchingFraction': round(close / len(pixels), 5), 'box': box}

for states_file in sorted(root.glob('*.states.json')):
    state = json.loads(states_file.read_text())
    for suffix in ('.png', '.next.png'):
        path = root / (state['name'] + suffix)
        if not path.is_file():
            continue
        image = Image.open(path).convert('RGB')
        observations = []
        for target in state['states']:
            name, rect = target['testID'], target['rect']
            if name.startswith('swatch-'):
                samples = [fraction(image, rect, colors[0])]
            elif name in ('image-plain', 'image-clipped'):
                regions = [(.15,.15,.35,.35), (.65,.15,.85,.35), (.15,.65,.35,.85), (.65,.65,.85,.85)]
                samples = [fraction(image, rect, color, area) for color, area in zip(colors, regions)]
            elif name.startswith('focus-'):
                samples = [fraction(image, rect, (255,255,255) if target['nativeFocused'] else (39,51,68))]
            else:
                continue
            observations.append({'testID': name, 'samples': samples})
        report['captures'].append({'image': path.name, 'imageStatus': state['imageStatus'],
                                   'focusStatus': state['focusStatus'], 'observations': observations})
(root/'pixel-analysis.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({'analyzedScreenshots': len(report['captures']), 'output': str(root/'pixel-analysis.json')}))
