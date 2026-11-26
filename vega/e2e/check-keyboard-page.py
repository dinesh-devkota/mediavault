"""Classify the Silverstone Done control in a complete native UI snapshot."""

import sys
from xml.etree import ElementTree


def done_state(root, app_name, field_id):
    if root.tag != 'root':
        return 2
    fixture_fields = (
        node.get('test_id')
        for app in root.findall('app') if app.get('appName') == app_name
        for window in app.findall('window')
        for node in window.iter('child')
    )
    if field_id not in fixture_fields:
        return 2
    if any(
        node.get('test_id') == 'key_Done'
        for app in root.findall('app') if app.get('appName') == 'com.amazon.silverstone'
        for node in app.iter()
    ):
        return 10
    return 0


try:
    snapshot = ElementTree.parse(sys.stdin.buffer).getroot()
except ElementTree.ParseError:
    sys.exit(2)
sys.exit(done_state(snapshot, *sys.argv[1:]))
