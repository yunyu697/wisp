"""粗查跨文件符号引用是否都有对应 import。
只看项目内自定义类型，忽略 Flutter/Dart 自带符号。
"""
import re
from pathlib import Path

ROOT = Path(r"C:/Users/Tyler Zhang/WorkBuddy AI/2026-10-27-20-51-53/wisp/lib")

DEFS = {
    'WispColors': 'core/design/app_colors.dart',
    'WispMotion': 'core/design/app_motion.dart',
    'WispTheme': 'core/design/app_theme.dart',
    'WispProtocol': 'core/constants.dart',
    'Format': 'core/utils/format.dart',
    'FileKind': 'core/utils/format.dart',
    'Pickers': 'core/utils/pickers.dart',
    'WispDevice': 'models/device.dart',
    'DeviceKind': 'models/device.dart',
    'TransferFile': 'models/transfer.dart',
    'TransferSession': 'models/transfer.dart',
    'TransferStatus': 'models/transfer.dart',
    'TransferDirection': 'models/transfer.dart',
    'TransferRecord': 'models/transfer.dart',
    'WispSettings': 'services/settings_service.dart',
    'SettingsService': 'services/settings_service.dart',
    'HistoryService': 'services/history_service.dart',
    'DiscoveryService': 'services/discovery_service.dart',
    'ReceiverService': 'services/receiver_service.dart',
    'SenderService': 'services/sender_service.dart',
    'SendFailure': 'services/sender_service.dart',
    'IncomingRequest': 'services/receiver_service.dart',
    'ReceiveDecision': 'services/receiver_service.dart',
    'AppState': 'state/app_state.dart',
    'WispCard': 'ui/widgets/wisp_card.dart',
    'StaggeredItem': 'ui/widgets/wisp_card.dart',
    'PressableScale': 'ui/widgets/wisp_card.dart',
    'WispBottomNav': 'ui/widgets/wisp_bottom_nav.dart',
    'RadarView': 'ui/widgets/radar_view.dart',
    'DeviceAvatar': 'ui/widgets/device_tile.dart',
    'DeviceTile': 'ui/widgets/device_tile.dart',
    'GradientButton': 'ui/widgets/gradient_button.dart',
    'GhostButton': 'ui/widgets/gradient_button.dart',
    'ProgressRing': 'ui/widgets/progress_ring.dart',
    'SlimProgress': 'ui/widgets/progress_ring.dart',
    'EmptyState': 'ui/widgets/empty_state.dart',
    'SectionHeader': 'ui/widgets/empty_state.dart',
    'IdentityCard': 'ui/widgets/identity_card.dart',
    'HomeShell': 'ui/shell/home_shell.dart',
    'TransferPage': 'ui/pages/transfer_page.dart',
    'startSendFlow': 'ui/flows/send_flow.dart',
    'showDeviceSheet': 'ui/pages/nearby_page.dart',
    'WispApp': 'app.dart',
}

problems = []
for path in sorted(ROOT.rglob('*.dart')):
    rel = path.relative_to(ROOT).as_posix()
    src = path.read_text(encoding='utf-8')
    body = '\n'.join(l for l in src.splitlines() if not l.strip().startswith('import '))
    imports = re.findall(r"import\s+'([^']+)'", src)
    imported_names = {Path(i).name for i in imports}
    for symbol, target in DEFS.items():
        if target == rel:
            continue
        if not re.search(rf'\b{symbol}\b', body):
            continue
        if Path(target).name in imported_names:
            continue
        # 同目录相对引用也可能用别的文件名，但本项目一对一，直接报
        problems.append(f'{rel}: 用到 {symbol}，但没 import {target}')

print('\n'.join(problems) if problems else '所有跨文件引用都有对应 import')
print(f'--- 共 {len(problems)} 处待确认')
