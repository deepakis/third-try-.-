"""Prepares the Android project that `flutter create` generates, for a phone build.

Run after `flutter create --platforms=android .`. It makes three changes to
android/app/src/main/AndroidManifest.xml:

  * INTERNET permission. The generated release manifest does not include it,
    and a release build without it cannot reach OBS at all.
  * usesCleartextTraffic. OBS speaks plain ws:// on the LAN.
  * The launcher label "Open Flutter" instead of the project name.
"""

import pathlib
import re
import sys

MANIFEST = pathlib.Path("android/app/src/main/AndroidManifest.xml")


def main() -> int:
    xml = MANIFEST.read_text(encoding="utf-8")

    if "android.permission.INTERNET" not in xml:
        xml = xml.replace(
            "<application",
            '    <uses-permission android:name="android.permission.INTERNET" />\n\n'
            "    <application",
            1,
        )

    app_tag = re.search(r"<application\b[^>]*>", xml)
    if app_tag is None:
        print("no <application> tag found", file=sys.stderr)
        return 1
    tag = app_tag.group(0)
    new_tag = tag
    if "usesCleartextTraffic" not in tag:
        new_tag = new_tag.replace("<application", '<application\n        android:usesCleartextTraffic="true"', 1)
    new_tag = re.sub(r'android:label="[^"]*"', 'android:label="Open Flutter"', new_tag)
    xml = xml.replace(tag, new_tag, 1)

    MANIFEST.write_text(xml, encoding="utf-8")
    print("patched", MANIFEST)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
