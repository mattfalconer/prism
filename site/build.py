"""Builds prism.mattfalconer.com from site/ into docs/, which GitHub Pages serves.

site/index.html is a page fragment (so it can also be previewed on its own); this wraps it in a full document,
points the download buttons at the latest GitHub release, adds link-preview tags (Open Graph, X card) and structured
data (JSON-LD), writes robots.txt, sitemap.xml and llms.txt, and copies the media alongside. The structured data and
llms.txt quote the page's own words, so they change when the page does.
The film (media/film.mp4, 20 MB) lives only in docs/media; it's kept there between builds.
The link-preview card, media/og.jpg, is rendered from site/og/card.html (how is noted at its top).

    python3 -I site/build.py
"""
import hashlib
import html
import json
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

SITE = Path(__file__).resolve().parent
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else SITE.parent / "docs"
URL = "https://prism.mattfalconer.com/"
REPO = "https://github.com/mattfalconer/prism"
DOWNLOAD = f"{REPO}/releases/latest/download/Prism.dmg"
LICENSE = "https://www.gnu.org/licenses/gpl-3.0.html"
AUTHOR, AUTHOR_URL = "Matt Falconer", "https://github.com/mattfalconer"
DESCRIPTION = "Prism is a realtime stem-splitter for Mac, allowing you to take vocals out of any audio, as it plays."
PREVIEW_TITLE = "Prism: take the vocals out of anything"
PREVIEW_ALT = ("Prism’s panel playing “Love Deadline” from Spotify with the Instrumental preset on and the vocals muted, "
               "beside the words “Take the vocals out of anything.”")

page = (SITE / "index.html").read_text()
assert page.count('href="Prism.dmg"') == 3, "expected three download buttons"
page = page.replace('href="Prism.dmg"', f'href="{DOWNLOAD}"')


# The page's own words.
def text(fragment):
    return " ".join(html.unescape(re.sub(r"<[^>]+>", "", fragment)).split())


def find(pattern, count):
    found = [tuple(map(text, m)) if isinstance(m, tuple) else text(m) for m in re.findall(pattern, page, re.S)]
    assert len(found) == count, f"expected {count} of {pattern!r} in index.html, found {len(found)}"
    return found


[(headline, lede)] = find(r'<h1>(.*?)</h1>\s*<p class="lede">(.*?)</p>', 1)
assert lede.startswith(DESCRIPTION + " "), "the hero lede should open with DESCRIPTION"
presets_section, sources_section, menubar_section = find(r'<h2>(.*?)</h2>\s*<p class="lede">(.*?)</p>', 3)
presets = find(r'data-preset="[^"]+" aria-current="[^"]+"><b>(.*?)</b><span>(.*?)</span>', 5)
[aside] = find(r'<p class="aside">(.*?)</p>', 1)
[apps] = re.findall(r'<div class="apps"[^>]*>(.*?)</div>', page, re.S)
apps = ", ".join(text(app) for app in re.findall(r"<span[^>]*>(.*?)</span>", apps))
assert apps.startswith("Spotify") and apps.endswith("All Mac Audio"), apps
facts = find(r"<h3>(.*?)</h3><p>(.*?)</p>", 3)
faq = find(r"<details[^>]*><summary>(.*?)</summary>\s*<p>(.*?)</p></details>", 6)

# Link previews: one card for X, iMessage, Slack, LinkedIn, Discord and Facebook. Its URL carries a hash of the image,
# so a new card is fetched afresh instead of served from their caches.
card = (SITE / "media" / "og.jpg").read_bytes()
sof = re.search(rb"\xff[\xc0-\xc3\xc5-\xc7\xc9-\xcb\xcd-\xcf]..\x08(..)(..)", card, re.S)
assert (int.from_bytes(sof[2], "big"), int.from_bytes(sof[1], "big")) == (1200, 630), "og.jpg should be 1200x630"
CARD = f"{URL}media/og.jpg?v={hashlib.sha256(card).hexdigest()[:10]}"
attr = lambda s: html.escape(s, quote=True)
preview = f"""<link rel="canonical" href="{URL}">
<meta name="author" content="{AUTHOR}">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#0b0a11">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Prism">
<meta property="og:url" content="{URL}">
<meta property="og:title" content="{attr(PREVIEW_TITLE)}">
<meta property="og:description" content="{attr(DESCRIPTION)}">
<meta property="og:image" content="{CARD}">
<meta property="og:image:type" content="image/jpeg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{attr(PREVIEW_ALT)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{attr(PREVIEW_TITLE)}">
<meta name="twitter:description" content="{attr(DESCRIPTION)}">
<meta name="twitter:image" content="{CARD}">
<meta name="twitter:image:alt" content="{attr(PREVIEW_ALT)}">
<link rel="apple-touch-icon" href="media/icon-512.png">
"""

# Structured data for search and answer engines.
author = {"@type": "Person", "@id": f"{URL}#author", "name": AUTHOR, "url": AUTHOR_URL}
app = {
    "@type": "SoftwareApplication", "@id": f"{URL}#app", "name": "Prism", "url": URL, "description": DESCRIPTION,
    "applicationCategory": "MultimediaApplication", "operatingSystem": "macOS 26 or later",
    "processorRequirements": "Apple silicon", "downloadUrl": DOWNLOAD, "isAccessibleForFree": True,
    "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"}, "license": LICENSE,
    "author": {"@id": author["@id"]}, "image": f"{URL}media/icon-512.png", "screenshot": f"{URL}media/menubar.webp",
    "featureList": [f"{name}: {what}" for name, what in presets] + [aside] + [" ".join(s) for s in
                    (sources_section, menubar_section, *facts)],
    "sameAs": [REPO],
}
code = {"@type": "SoftwareSourceCode", "@id": f"{URL}#code", "name": "Prism", "codeRepository": REPO,
        "license": LICENSE, "author": {"@id": author["@id"]}, "targetProduct": {"@id": app["@id"]}}
website = {"@type": "WebSite", "@id": f"{URL}#website", "url": URL, "name": "Prism", "description": DESCRIPTION,
           "inLanguage": "en", "author": {"@id": author["@id"]}}
questions = {"@type": "FAQPage", "@id": f"{URL}#faq", "url": URL, "mainEntity": [
    {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in faq]}
graph = {"@context": "https://schema.org", "@graph": [website, app, code, author, questions]}
ld = json.dumps(graph, ensure_ascii=False, indent=1).replace("<", "\\u003c")

head, body = page.split('<header class="nav">', 1)
head = head.replace('<meta name="claude:viewport-fit-sides" content="cover">\n', "")
icon = '<link rel="icon" href="media/icon.png">\n'
assert head.count(icon) == 1
head = head.replace(icon, icon + preview)  # ahead of the stylesheet, where link unfurlers find them first
html_doc = f"""<!doctype html>
<html lang="en">
<head>
{head.rstrip()}
<script type="application/ld+json">
{ld}
</script>
</head>
<body>
<header class="nav">{body.rstrip()}
</body>
</html>
"""

# llms.txt (llmstxt.org): a plain summary for language models, in the page's words.
lines = [
    "# Prism", "", f"> {DESCRIPTION}", "",
    f"{headline} {lede[len(DESCRIPTION):].strip()}", "",
    "- Price: free and open source (GPL-3.0)",
    f"- Requirements: {dict(faq)['Which Macs does it run on?']}",
    f"- Made by: {AUTHOR}",
    f"- Download: {DOWNLOAD}", "",
    f"**{presets_section[0]}** {presets_section[1]}", "",
    *[f"- {name}: {what}" for name, what in presets], "",
    aside, "",
    f"**{sources_section[0]}** {sources_section[1]} Sources: {apps}.", "",
    f"**{menubar_section[0]}** {menubar_section[1]}", "",
    *[f"**{h}** {p}\n" for h, p in facts],
    "Questions and answers:", "",
    *[f"**{q}** {a}\n" for q, a in faq],
    "## Links", "",
    f"- [Prism website]({URL}): the page this summarises",
    f"- [Download Prism for Mac]({DOWNLOAD}): the latest release, as a disk image",
    f"- [Source code]({REPO}): the GitHub repository, under the GPL-3.0 licence", "",
]

edited = max((SITE / "index.html").stat().st_mtime, Path(__file__).stat().st_mtime)
sitemap = f"""<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>{URL}</loc>
    <lastmod>{datetime.fromtimestamp(edited, timezone.utc).date().isoformat()}</lastmod>
  </url>
</urlset>
"""
robots = f"""# Everyone is welcome to everything here: search engines and AI crawlers alike.
User-agent: *
Allow: /

Sitemap: {URL}sitemap.xml
"""

OUT.mkdir(parents=True, exist_ok=True)
(OUT / "index.html").write_text(html_doc)
(OUT / "llms.txt").write_text("\n".join(lines))
(OUT / "sitemap.xml").write_text(sitemap)
(OUT / "robots.txt").write_text(robots)
shutil.copy(SITE / "favicon.ico", OUT / "favicon.ico")
shutil.copy(SITE / "meters.json", OUT / "meters.json")
shutil.copy(SITE / "model.json", OUT / "model.json")  # model mirrors the app checks on first run
shutil.copytree(SITE / "media", OUT / "media", dirs_exist_ok=True)
(OUT / "CNAME").write_text("prism.mattfalconer.com")  # as GitHub writes it
(OUT / ".nojekyll").write_text("")
print("built", OUT, sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file()) // 1_000_000, "MB")
