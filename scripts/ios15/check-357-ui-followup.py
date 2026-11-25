#!/usr/bin/env python3
"""Source and catalog checks for the iOS 15 UI follow-up (not a UI test)."""
import json
import re
from pathlib import Path

IOS = Path(__file__).resolve().parents[2] / 'src/ios'


def read(path):
    return (IOS / path).read_text(encoding='utf-8')


def check(ok, message):
    if not ok:
        raise SystemExit(f'FAIL: {message}')
    print(f'PASS: {message}')


def no_duplicates(pairs):
    obj = dict(pairs)
    if len(obj) != len(pairs):
        raise ValueError('Duplicate catalog key')
    return obj


keys = [
    'User questions', 'Wait for answer', '%lld minutes', 'Background reminders',
    'Question behavior and reminders', 'AOJIT Optimization', 'Ready', 'Partial',
    'AOT coverage: %@ of %lld blocks', 'Prepaid balance', 'Balance · %@',
    'Available', 'Relay type', 'Relay billing', 'OpenAI-compatible billing',
    'Shared by all models on this account', 'Relay account quota (relay-reported)',
    'Response idle timeout', '2 minutes (default)', '5 minutes', '10 minutes',
    '30 minutes', '60 minutes', '%lld seconds', 'Custom…', 'Seconds (30–3600)',
]
provider = read('Views/Providers/ProviderInstanceDetailView.swift')
footer, = re.findall(r'AppLocalized\("(How long to wait for the first response[^"\n]+)"\)', provider)
keys.append(footer)
catalog = json.loads(read('Localizable.xcstrings'), object_pairs_hook=no_duplicates)['strings']
for key in keys:
    try:
        text = catalog[key]['localizations']['zh-Hans']['stringUnit']['value']
    except KeyError:
        raise SystemExit(f'FAIL: no zh-Hans value for {key}') from None
    if not re.search('[\u4e00-\u9fff]', text):
        raise SystemExit(f'FAIL: no Chinese text for {key}')
    if re.findall(r'%(?:lld|@)', key) != re.findall(r'%(?:lld|@)', text):
        raise SystemExit(f'FAIL: format placeholders changed for {key}')
print(f'PASS: {len(keys)} zh-Hans strings and format placeholders')

tools = read('Views/Settings/ToolsSettingsView.swift')
question = tools.split('NavigationLink { UserAskSettingsView() } label: {', 1)[-1].split('toolRow(AppLocalized("Browser Use")', 1)[0]
check('Image(systemName: "questionmark.circle")' in question and
      'Text(AppLocalized("Question behavior and reminders"))' in question,
      'question settings navigation has its own icon and localized label')

chat = read('Views/Chat/AIChatView.swift')
header = chat.split('private var titleView: some View', 1)[-1].split('private var thinkingLevelBadge', 1)[0]
check(chat.count('ModelQuotaMemberPill(') == 1 and
      bool(re.search(r'thinkingLevelBadge[\s\S]*ModelQuotaMemberPill\(', header)) and
      'chatQuotaTarget = QuotaSheetTarget' in header,
      'chat balance follows thinking strength and opens quota detail')
check(all(fragment in chat for fragment in (
    'quotaInstanceID: quotaEntry?.providerInstanceId', 'quotaModelID: quotaEntry?.model.id',
    'activeGroupSoul.name ?? globalSoulName', 'Text(sessionTitle ?? soulName)',
    'titlePillSession?.folderId == folderID', 'next?.folderId != titlePillSession?.folderId',
    'AssistantSoulName(overrideName: groupSoul?.name)', 'lhs.groupSoul == rhs.groupSoul',
)) and chat.count('groupSoul: activeGroupSoul') == 2,
      'chat cache, group override, global fallback and legacy transcript wiring')
modern = read('Agent/MessageList/CollectionViewMessageListV3.swift')
check('coord.updateGroupSoul(groupSoul)' in modern and
      'snapshot.reconfigureItems(headers)' in modern and
      'Text(groupSoul.name ?? GroupSoulIdentity.nonBlank(soulMeta.name) ?? "Minis")' in modern,
      'modern transcript refreshes assistant headers on group identity changes')
print('NOTE: source checks only; Swift build and device UI not verified.')
