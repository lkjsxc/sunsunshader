#!/usr/bin/env python3
"""Deterministic CPU reference for the rc6 lantern colour-emission mask.

Requires the unchanged prepared assets of the pinned 26.3 gallery. This is
shader arithmetic evaluation, NOT a rendering or pixel-identical halo test.
"""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import tomllib
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LANTERN_MASK = 1 << 4
TRIAL_CAGE_MASK = 1 << 3


def smooth(a, b, x):
    t = max(0.0, min(1.0, (x-a)/(b-a)))
    return t*t*(3-2*t)


def linear(c):
    x = c/255.0
    return x/12.92 if x <= 0.04045 else ((x+0.055)/1.055)**2.4


def factor(rgb, distance, tags, emission=1.0):
    if not tags & LANTERN_MASK:
        return emission
    c = [linear(v) for v in rgb]
    brightness = (sum(x*y for x,y in zip(c, (.2126,.7152,.0722)))+max(c))/2
    glass = smooth(.12,.35,brightness)
    near = 1.0-smooth(12.0,24.0,distance)
    return emission * (1.0+(glass-1.0)*near)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--resources', type=Path, required=True)
    args = p.parse_args()
    sprites = args.resources/'assets/minecraft/textures/block'
    manifest = tomllib.loads((ROOT/'pack/horizon-shaders.toml').read_text())
    tags = manifest['tags']
    assert tags[3] == {'id': 'trial_spawner_cage', 'sprites': ['block/trial_spawner_*']}, tags
    assert len(tags) == 5 and tags[4] == {
        'id':'framed_emitter', 'sprites':['block/lantern','block/soul_lantern']}, tags
    shader = (ROOT/'pack/shaders/material.wgsl').read_text()
    assert 'if (input.tags & 16u) != 0u' in shader
    assert 'let inward = (input.tags & 8u) != 0u && ss_haze_inward_cage_face' in shader
    assert 'let texel = input.albedo.rgb;' in shader
    assert 'let near = 1.0 - smoothstep(12.0, 24.0, length(input.position));' in shader
    assert shader.count('foliage, colour_emission);') == 1
    assert shader.count('ss_surface_emission(albedo, colour_emission);') == 1
    assert shader.count('clamp(colour_emission, 0.0, 1.0)') == 1
    assert shader.count('ss_surface_data(input.light, emission, sources)') == 1
    assert shader.count('ss_world_bound(color), coverage') == 1
    assert shader.count('select(input.albedo.a, input.albedo.a * input.shaded_tint.a, input.translucent)') == 1
    assert factor((62,68,83), 4, LANTERN_MASK) == 0.0
    assert factor((73,80,101), 4, LANTERN_MASK) == 0.0
    assert factor((255,255,213), 4, LANTERN_MASK) == 1.0
    assert factor((42,201,207), 4, LANTERN_MASK) == 1.0
    assert factor((255,255,213), 4, 0) == 1.0
    assert factor((62,68,83), 4, 1) == 1.0
    assert factor((62,68,83), 4, 4) == 1.0
    assert factor((62,68,83), 4, TRIAL_CAGE_MASK) == 1.0
    assert factor((62,68,83), 4, LANTERN_MASK, 0.0) == 0.0
    assert factor((62,68,83), 24, LANTERN_MASK) == 1.0
    assert factor((62,68,83), 18, LANTERN_MASK) == .5
    assert 0 < factor((62,68,83), 13, LANTERN_MASK) < factor((62,68,83), 20, LANTERN_MASK) < 1
    results = {}
    for name in ('lantern','soul_lantern'):
        texture = sprites/f'{name}.png'
        image = Image.open(texture).convert('RGBA')
        assert image.size == (16,48)
        count = Counter()
        for r,g,b,a in image.getdata():
            if not a:
                count['transparent'] += 1
                continue
            count['opaque'] += 1
            v = factor((r,g,b), 4, LANTERN_MASK)
            if v < .01:
                count['dark_iron'] += 1
            elif v >= .99:
                count['bright_glass'] += 1
            else:
                count['transition'] += 1
            assert factor((r,g,b), 24, LANTERN_MASK) == 1.0
            assert factor((r,g,b), 4, 0) == 1.0
        assert count['dark_iron'] >= 150 and count['bright_glass'] >= 20
        results[name] = dict(count)
    print(json.dumps({'status':'PASS', 'type':'CPU arithmetic / static source assertions',
        'not_render_proof':True, 'textures':results},indent=2))


if __name__ == '__main__':
    main()
