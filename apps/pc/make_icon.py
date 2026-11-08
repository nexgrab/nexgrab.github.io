from pathlib import Path
from PIL import Image

BASE = Path(__file__).resolve().parent
ASSETS = BASE / "assets"
PNG = ASSETS / "nexgrab_logo.png"
ICO = ASSETS / "nexgrab.ico"

if not PNG.exists():
    raise SystemExit(f"Logo not found: {PNG}")

img = Image.open(PNG).convert("RGBA")

size = max(img.width, img.height)
canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
canvas.paste(
    img,
    ((size - img.width) // 2, (size - img.height) // 2),
    img
)

canvas.save(
    ICO,
    format="ICO",
    sizes=[
        (16, 16),
        (24, 24),
        (32, 32),
        (48, 48),
        (64, 64),
        (128, 128),
        (256, 256),
    ]
)

print("Created:", ICO)
