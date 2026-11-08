"""Copy ffmpeg + deno (from the pip packages in this venv) next to the built EXE.

Usage: python collect_tools.py "<release folder>\\tools"
"""
import glob
import os
import shutil
import sys

dest = sys.argv[1]
os.makedirs(dest, exist_ok=True)
ok = True


def copy(src, name, min_mb):
    global ok
    if not src or not os.path.isfile(src) or os.path.getsize(src) < min_mb * 1024 * 1024:
        print(f"  [WARNING] {name} nahi mila (app Settings se install kar legi)")
        ok = False
        return
    with open(src, "rb") as a, open(os.path.join(dest, name), "wb") as b:
        shutil.copyfileobj(a, b, 4 * 1024 * 1024)
    print(f"  {name}: {os.path.getsize(src) // (1024 * 1024)} MB  <- {src}")


# ffmpeg: the binary shipped inside the imageio-ffmpeg wheel (not whatever is on PATH)
try:
    import imageio_ffmpeg

    bins = glob.glob(os.path.join(os.path.dirname(imageio_ffmpeg.__file__), "binaries", "ffmpeg-win*.exe"))
    bins.sort(key=os.path.getsize, reverse=True)
    copy(bins[0] if bins else None, "ffmpeg.exe", 20)
except Exception as exc:  # noqa: BLE001
    print("  [WARNING] ffmpeg:", exc)
    ok = False

# deno: the binary installed by the "deno" pip package
try:
    import deno

    copy(deno.find_deno_bin(), "deno.exe", 30)
except Exception as exc:  # noqa: BLE001
    print("  [WARNING] deno:", exc)
    ok = False

sys.exit(0 if ok else 2)
