"""Adds a release to Prism's Sparkle appcast (newest first), creating the feed if it doesn't exist.

    python3 -I scripts/appcast.py docs/appcast.xml <version> <build> <signature file> <notes.md>

The signature file is sign_update's output (`sparkle:edSignature="…" length="…"`).
"""
import email.utils
import html
import sys
from pathlib import Path

feed, version, build, signature, notes = sys.argv[1:6]
FEED = Path(feed)
HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Prism</title>
    <link>https://prism.mattfalconer.com/</link>
    <description>Updates to Prism</description>
    <language>en</language>
"""
FOOTER = """  </channel>
</rss>
"""


def to_html(markdown: str) -> str:
    """Paragraphs and "- " bullet lists, which is all release notes need."""
    parts, bullets = [], []
    for block in markdown.strip().split("\n\n"):
        for line in block.splitlines():
            line = line.strip()
            if line.startswith("- "):
                bullets.append(f"<li>{html.escape(line[2:])}</li>")
                continue
            if bullets:
                parts.append("<ul>" + "".join(bullets) + "</ul>")
                bullets = []
            if line:
                parts.append(f"<p>{html.escape(line)}</p>")
        if bullets:
            parts.append("<ul>" + "".join(bullets) + "</ul>")
            bullets = []
    return "".join(parts)


attributes = Path(signature).read_text().strip()
assert attributes.startswith("sparkle:edSignature=") and "length=" in attributes, "unexpected signature file"
item = f"""    <item>
      <title>Prism {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{to_html(Path(notes).read_text())}]]></description>
      <enclosure url="https://github.com/mattfalconer/prism/releases/download/v{version}/Prism-{version}.zip" type="application/octet-stream" {attributes}/>
    </item>
"""
text = FEED.read_text() if FEED.exists() else HEADER + FOOTER
assert f"<sparkle:version>{build}</sparkle:version>" not in text, f"build {build} is already in the feed"
marker = "    <language>en</language>\n"
assert marker in text
FEED.write_text(text.replace(marker, marker + item, 1))
print("added", version, f"({build})", "to", FEED)
