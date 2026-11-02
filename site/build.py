"""Builds prism.mattfalconer.com from site/ into docs/, which GitHub Pages serves.

site/index.html is a page fragment (so it can also be previewed on its own); this wraps it in a full document,
points the download buttons at the latest GitHub release, adds link-preview tags, and copies the media alongside.
The film (media/film.mp4, 20 MB) lives only in docs/media; it's kept there between builds.

    python3 -I site/build.py
"""
import shutil
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else SITE.parent / "docs"
URL = "https://prism.mattfalconer.com/"
DOWNLOAD = "https://github.com/mattfalconer/prism/releases/latest/download/Prism.dmg"
DESCRIPTION = "Prism is a realtime stem-splitter for Mac, allowing you to take vocals out of any audio, as it plays."

page = (SITE / "index.html").read_text()
assert page.count('href="Prism.dmg"') == 3, "expected three download buttons"
page = page.replace('href="Prism.dmg"', f'href="{DOWNLOAD}"')

head, body = page.split('<header class="nav">', 1)
preview = f"""<link rel="canonical" href="{URL}">
<meta property="og:type" content="website">
<meta property="og:url" content="{URL}">
<meta property="og:title" content="Prism: take the vocals out of anything">
<meta property="og:description" content="{DESCRIPTION}">
<meta property="og:image" content="{URL}media/og.jpg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="{URL}media/og.jpg">
<link rel="apple-touch-icon" href="media/icon-512.png">
"""
head = head.replace('<meta name="claude:viewport-fit-sides" content="cover">\n', "")
html = f"""<!doctype html>
<html lang="en">
<head>
{head.rstrip()}
{preview}</head>
<body>
<header class="nav">{body.rstrip()}
</body>
</html>
"""

OUT.mkdir(parents=True, exist_ok=True)
(OUT / "index.html").write_text(html)
shutil.copy(SITE / "meters.json", OUT / "meters.json")
shutil.copytree(SITE / "media", OUT / "media", dirs_exist_ok=True)
(OUT / "CNAME").write_text("prism.mattfalconer.com\n")
(OUT / ".nojekyll").write_text("")
print("built", OUT, sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file()) // 1_000_000, "MB")
