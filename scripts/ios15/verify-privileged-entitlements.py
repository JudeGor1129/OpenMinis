import plistlib
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
def read(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)

base = read(root / 'src/ios/Minis.entitlements')
extra = read(root / 'tools/privileged-helper/TrollStoreApp.extra.entitlements')
helper = read(root / 'tools/privileged-helper/Helper.entitlements')
extra_expected = {
    'platform-application': True,
    'com.apple.private.persona-mgmt': True,
    'com.apple.private.security.no-sandbox': True,
    'com.apple.private.security.storage.AppDataContainers': True,
    'com.apple.private.security.storage.AppBundles': True,
}
helper_expected = {
    'platform-application': True,
    'com.apple.private.security.no-sandbox': True,
    'com.apple.private.security.container-required': False,
}
assert extra == extra_expected, 'dedicated GUI entitlement overlay mismatch'
assert helper == helper_expected, 'helper entitlement set mismatch'
for key in set(extra_expected) | set(helper_expected):
    assert key not in base, f'common app entitlements gained privilege: {key}'
for path in ['src/ios/ShareExtension/ShareExtension.entitlements', 'src/ios/FileProvider/FileProvider.entitlements']:
    data = read(root / path)
    for key in set(extra_expected) | set(helper_expected):
        assert key not in data, f'extension gained privileged permission: {path}: {key}'
if len(sys.argv) == 3:
    signed_app = read(sys.argv[1]); signed_helper = read(sys.argv[2])
    merged = dict(base); merged.update(extra_expected)
    assert signed_app == merged, 'final GUI entitlements mismatch'
    assert signed_helper == helper_expected, 'final helper entitlements mismatch'
print('PASS: GUI no-sandbox/persona plus explicit own-container grants; no privileged claims in base app or extensions.')
