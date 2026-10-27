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
expected = {
    'platform-application': True,
    'com.apple.private.persona-mgmt': True,
    'com.apple.private.security.no-sandbox': True,
    'com.apple.private.security.storage.AppDataContainers': True,
    'com.apple.private.security.storage.AppBundles': True,
}
assert extra == expected, 'dedicated GUI entitlement overlay mismatch'
helper_expected = {'platform-application': True, 'com.apple.private.security.no-sandbox': True,
                   'com.apple.private.security.container-required': False}
assert helper == helper_expected, 'helper entitlement set mismatch'
assert all(k not in base for k in expected), 'common app entitlements gained privileges'
for p in ['src/ios/ShareExtension/ShareExtension.entitlements', 'src/ios/FileProvider/FileProvider.entitlements']:
    data = read(root / p)
    assert all(k not in data for k in expected), f'extension gained privileged permissions: {p}'
if len(sys.argv) == 3:
    signed_app = read(sys.argv[1]); signed_helper = read(sys.argv[2])
    merged = dict(base); merged.update(expected)
    assert signed_app == merged, 'final GUI entitlements mismatch'
    assert signed_helper == helper_expected, 'final helper entitlements mismatch'
print('PASS: dedicated GUI storage grants verified; base app and extensions stay unchanged.')
