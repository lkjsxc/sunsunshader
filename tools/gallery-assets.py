#!/usr/bin/env python3
"""Make an SDR review sheet or compress selected gallery screenshots."""
import argparse
import hashlib
import json
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image, ImageDraw, ImageFont

CATALOGUE = Path(__file__).with_name("gallery-scenes.json")


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def load_capture(folder, scene):
    png = folder / f"{scene}.png"
    receipt = json.loads((folder / f"{scene}.capture.json").read_text())
    if receipt["format"] != "SDR" or receipt["sha256"] != digest(png):
        raise ValueError(f"Capture receipt mismatch for {scene}")
    with Image.open(png) as source:
        if list(source.size) != receipt["size"] or source.mode not in ("RGBA", "RGB"):
            raise ValueError(f"Invalid frame for {scene}")
        return source.convert("RGB")


def fit(image, size):
    return image.resize(size, Image.Resampling.LANCZOS) if image.size != tuple(size) else image


def write_sheet(args, images, inputs):
    width, height = 320, 180
    header = 33
    row = height + 25
    columns = 3 if len(images) < 10 else 5
    rows = (len(images) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * width, rows * row + header), "#151515")
    labels = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    version = inputs.get("pack_version", "")
    labels.text((8, 9), f"Sunsun Shader {version} / SDR / {inputs['renderer']}", font=font, fill="white")
    for index, (scene, image) in enumerate(images):
        x = (index % columns) * width
        y = header + (index // columns) * row
        sheet.paste(fit(image, (width, height)), (x, y))
        labels.text((x + 8, y + height + 5), scene, font=font, fill="white")
    sheet.save(args.sheet, quality=90, optimize=True)


def write_gallery(args, cfg, images, inputs):
    if list(inputs["size"]) != cfg["capture_size"]:
        raise ValueError("Gallery assets require full-resolution captures")
    args.gallery.mkdir(parents=True)
    manifest = {
        "nightly": inputs["nightly"], "pack_sha256": inputs["pack_sha256"],
        "backend": inputs["backend"], "format": inputs["format"],
        "renderer": inputs["renderer"], "capture_size": cfg["capture_size"],
        "thumbnail_size": cfg["thumbnail_size"], "scenes": [],
    }
    if version := inputs.get("pack_version"):
        manifest["pack_version"] = version
    files = []
    for scene, image in images:
        image_name, thumb_name = f"{scene}.jpg", f"{scene}-thumb.jpg"
        image.save(args.gallery / image_name, quality=90, optimize=True, subsampling=0)
        fit(image, cfg["thumbnail_size"]).save(
            args.gallery / thumb_name, quality=84, optimize=True, subsampling=0,
        )
        manifest["scenes"].append({"id": scene, "image": image_name, "thumbnail": thumb_name})
        files.extend([image_name, thumb_name])
    (args.gallery / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if args.archive:
        with ZipFile(args.archive, "x", compression=ZIP_DEFLATED) as archive:
            for name in ["manifest.json", *files]:
                archive.write(args.gallery / name, name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path, nargs="+", help="Completed runs, with later reruns replacing matching scenes")
    output = parser.add_mutually_exclusive_group(required=True)
    output.add_argument("--sheet", type=Path)
    output.add_argument("--gallery", type=Path)
    parser.add_argument("--archive", type=Path, help="Also create a release ZIP from the gallery assets")
    parser.add_argument("--scene", action="append", help="Include a reviewed scene (repeatable)")
    args = parser.parse_args()
    if args.archive and args.gallery is None:
        parser.error("--archive requires --gallery")
    if args.gallery and not args.scene:
        parser.error("--gallery requires explicit --scene selections")
    cfg = json.loads(CATALOGUE.read_text())
    sources = {}
    identity_keys = ("nightly", "pack_sha256", "backend", "format", "size")
    inputs = json.loads((args.captures[0] / "inputs.json").read_text())
    for folder in args.captures:
        run = json.loads((folder / "inputs.json").read_text())
        if any(run[key] != inputs[key] for key in identity_keys):
            raise ValueError("Use completed runs with matching pack, Nightly, size and backend")
        if "pack_version" in run:
            inputs.setdefault("pack_version", run["pack_version"])
        complete = json.loads((folder / "complete.json").read_text())
        sources.update((scene, folder) for scene in complete["scenes"])
    selections = args.scene or list(sources)
    if len(selections) != len(set(selections)) or any(
        not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", scene) or scene not in sources
        for scene in selections
    ):
        parser.error("each scene must be unique and listed in the completed runs")
    renderers = {
        json.loads((sources[scene] / f"{scene}.state.json").read_text())["status"]["renderer"]["gpu"]
        for scene in selections
    }
    if len(renderers) != 1:
        raise ValueError("Use captures from the same renderer")
    inputs["renderer"] = renderers.pop()
    images = [(scene, load_capture(sources[scene], scene)) for scene in selections]
    if args.sheet:
        write_sheet(args, images, inputs)
    else:
        write_gallery(args, cfg, images, inputs)


if __name__ == "__main__":
    main()
