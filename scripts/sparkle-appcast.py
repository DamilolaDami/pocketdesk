#!/usr/bin/env python3
"""Add a signed, notarized release ZIP to the stable Sparkle feed. Never uploads."""
import argparse
import base64
import datetime
import email.utils
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def app_metadata(archive):
    with zipfile.ZipFile(archive) as bundle:
        paths = [p for p in bundle.namelist() if p.count('/') == 2 and p.endswith('.app/Contents/Info.plist')]
        # app root / Contents / Info.plist has two slashes.
        if len(paths) != 1:
            raise ValueError('Update ZIP must contain exactly one root .app bundle')
        info = plistlib.loads(bundle.read(paths[0]))
        if info.get('CFBundleIdentifier') != 'app.pocketdesk.host':
            raise ValueError('Update must be the official PocketDesk host')
        if not str(info.get('CFBundleVersion', '')).isdigit():
            raise ValueError('Archive must contain its actual numeric build number')
        return info


def prepare(feed, archive, url, tool):
    if not re.fullmatch(r'https://github\.com/DamilolaDami/pocketdesk/releases/download/[^/\s?#]+/[^/\s?#]+\.zip', url):
        raise ValueError('Use the versioned official GitHub release ZIP URL')
    info = app_metadata(archive)
    public_key = subprocess.check_output([str(tool.with_name('generate_keys')), '--account', 'pocketdesk', '-p'], text=True).strip()
    if info.get('SUPublicEDKey') != public_key:
        raise ValueError('Archive public key does not match the PocketDesk signing key in Keychain')
    signature = subprocess.check_output([str(tool), '--account', 'pocketdesk', '-p', str(archive)], text=True).strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid Ed25519 signature output')
    tree = ET.parse(feed)
    channel = tree.getroot().find('channel')
    if channel is None:
        raise ValueError('Missing appcast channel')
    build = str(info['CFBundleVersion'])
    for item in channel.findall('item'):
        previous = item.findtext(f'{{{SPARKLE}}}version')
        if previous is None or not previous.isdigit() or int(previous) >= int(build):
            raise ValueError('New archive build must be greater than all published builds')
    item = ET.Element('item')
    ET.SubElement(item, 'title').text = f"PocketDesk {info['CFBundleShortVersionString']}"
    ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = info['CFBundleShortVersionString']
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info.get('LSMinimumSystemVersion', '26.0')
    ET.SubElement(item, 'enclosure', {'url': url, 'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
                                    f'{{{SPARKLE}}}edSignature': signature})
    first_item = next((index for index, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first_item, item)
    # Build the complete new file beside the destination, then replace only after signing.
    temporary = feed.with_suffix('.pending.xml')
    try:
        tree.write(temporary, encoding='utf-8', xml_declaration=True)
        subprocess.run([str(tool), '--account', 'pocketdesk', str(temporary)], check=True)
        subprocess.run([str(tool), '--account', 'pocketdesk', '--verify', str(temporary)], check=True)
        temporary.replace(feed)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=pathlib.Path)
    parser.add_argument('url')
    parser.add_argument('--feed', type=pathlib.Path, default=pathlib.Path('site/public/updates/appcast.xml'))
    parser.add_argument('--sign-tool', type=pathlib.Path, default=pathlib.Path('Packages/PocketDeskKit/.build/artifacts/sparkle/Sparkle/bin/sign_update'))
    args = parser.parse_args()
    prepare(args.feed, args.archive, args.url, args.sign_tool)


if __name__ == '__main__':
    main()
