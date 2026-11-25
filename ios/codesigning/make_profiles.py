#!/usr/bin/env python3
# Genera los perfiles de firma de prueba de SFS App a partir de los de Telegram-iOS (`build-system/fake-codesigning`):
# cambia el bundle ID de Telegram por el de SFS App (para que no reemplace al Telegram oficial en el iPhone),
# les pone fecha nueva y los vuelve a firmar con el mismo certificado de prueba, igual que `GenerateProfiles.py`
# de Telegram. Corre en la Mac de GitHub, con el certificado ya importado en el llavero.
#
# Uso: make_profiles.py <fake-codesigning de Telegram> <carpeta de salida> <bundle ID nuevo> <llavero>

import datetime
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

TELEGRAM_BUNDLE_ID = 'ph.telegra.Telegraph'
SIGNING_IDENTITY = 'Apple Distribution: Telegram FZ-LLC (C67CF9S4VU)'
VALID_DAYS = 3650


def replace_bundle_id(value, new_bundle_id):
    if isinstance(value, str):
        return value.replace(TELEGRAM_BUNDLE_ID, new_bundle_id)
    if isinstance(value, list):
        return [replace_bundle_id(item, new_bundle_id) for item in value]
    if isinstance(value, dict):
        return {key: replace_bundle_id(item, new_bundle_id) for key, item in value.items()}
    return value


def make_profile(source, destination, new_bundle_id, keychain):
    decoded = subprocess.check_output(['security', 'cms', '-D', '-i', source])
    profile = replace_bundle_id(plistlib.loads(decoded), new_bundle_id)

    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0, tzinfo=None)
    profile.pop('DER-Encoded-Profile', None)
    profile['CreationDate'] = now
    profile['ExpirationDate'] = now + datetime.timedelta(days=VALID_DAYS)
    profile['TimeToLive'] = VALID_DAYS
    profile['UUID'] = str(uuid.uuid4()).upper()

    with tempfile.NamedTemporaryFile(suffix='.plist', delete=False) as file:
        plistlib.dump(profile, file)
        plist_path = file.name
    try:
        subprocess.check_call(['security', 'cms', '-S', '-k', keychain, '-N', SIGNING_IDENTITY, '-i', plist_path, '-o', destination])
    finally:
        os.unlink(plist_path)

    app_id = profile['Entitlements']['application-identifier']
    print('{} -> {}'.format(os.path.basename(destination), app_id))


def main():
    if len(sys.argv) != 5:
        sys.exit('Uso: make_profiles.py <fake-codesigning> <salida> <bundle ID> <llavero>')
    source_path, destination_path, new_bundle_id, keychain = sys.argv[1:]

    os.makedirs(os.path.join(destination_path, 'profiles'), exist_ok=True)
    shutil.copytree(os.path.join(source_path, 'certs'), os.path.join(destination_path, 'certs'), dirs_exist_ok=True)

    profiles_path = os.path.join(source_path, 'profiles')
    names = sorted(name for name in os.listdir(profiles_path) if name.endswith('.mobileprovision'))
    if not names:
        sys.exit('No hay perfiles en {}'.format(profiles_path))
    for name in names:
        make_profile(os.path.join(profiles_path, name), os.path.join(destination_path, 'profiles', name), new_bundle_id, keychain)


if __name__ == '__main__':
    main()
