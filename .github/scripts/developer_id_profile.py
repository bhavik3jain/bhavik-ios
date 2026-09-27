"""Make a fresh Developer ID provisioning profile for the Mac release, through the App Store Connect API.

    developer_id_profile.py KEY_ID ISSUER_ID KEY_PATH CERT_SERIAL OUT_PATH [OUT_PATH ...]

Mac Release used to install a profile downloaded from the developer portal by hand and kept in the
MAC_DEVELOPER_ID_PROFILE secret. A profile's entitlements are frozen when it's generated, so when the
app gained CloudKit pushes (com.apple.developer.aps-environment) that profile could no longer sign it,
and every new capability meant another trip to the portal. Xcode's own -allowProvisioningUpdates
can't help: cloud-managed signing refuses Developer ID outright. The App Store Connect API has no such
restriction, so this deletes the old profile and creates a new one on every run, always carrying the
App ID's current capabilities.

The certificate is picked by the serial number of the one the workflow imported, so the profile and
the signing identity always match. Needs PyJWT with the crypto extra; standard library otherwise.
"""

from __future__ import annotations

import base64
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.bhavikjain.trackers"
# The workflow's ExportOptions and PROVISIONING_PROFILE_SPECIFIER name the profile, not its UUID.
PROFILE_NAME = "Multitrack Developer ID"


class Api:
    def __init__(self, key_id: str, issuer_id: str, key_path: str):
        now = int(time.time())
        with open(key_path) as f:
            private_key = f.read()
        self.token = jwt.encode(
            {"iss": issuer_id, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
            private_key,
            algorithm="ES256",
            headers={"kid": key_id, "typ": "JWT"},
        )

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(API + path, data=data, method=method)
        request.add_header("Authorization", f"Bearer {self.token}")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            print(f"App Store Connect {method} {path} failed: HTTP {error.code}\n{detail}", file=sys.stderr)
            if error.code in (401, 403):
                print(
                    "The API key can't manage provisioning profiles. In App Store Connect › Users and "
                    "Access › Integrations, give this key the Admin role (or one allowed to manage "
                    "certificates, identifiers and profiles), then run the workflow again.",
                    file=sys.stderr,
                )
            sys.exit(1)
        return json.loads(raw) if raw else {}


def normalized_serial(serial: str) -> str:
    return serial.strip().upper().lstrip("0")


def main(argv: list[str]) -> int:
    if len(argv) < 6:
        print(__doc__, file=sys.stderr)
        return 2
    key_id, issuer_id, key_path, cert_serial, *out_paths = argv[1:]
    api = Api(key_id, issuer_id, key_path)

    query = urllib.parse.urlencode({"filter[identifier]": BUNDLE_ID, "limit": 200})
    bundles = [b for b in api.call("GET", f"/bundleIds?{query}")["data"]
               if b["attributes"]["identifier"] == BUNDLE_ID]
    # The App ID is shared with the iOS app; a Mac profile needs one that covers macOS.
    bundles.sort(key=lambda b: {"UNIVERSAL": 0, "MAC_OS": 1}.get(b["attributes"].get("platform"), 2))
    if not bundles:
        print(f"No App ID {BUNDLE_ID} in this team.", file=sys.stderr)
        return 1
    bundle = bundles[0]

    query = urllib.parse.urlencode({
        "filter[certificateType]": "DEVELOPER_ID_APPLICATION,DEVELOPER_ID_APPLICATION_G2",
        "limit": 200,
    })
    wanted = normalized_serial(cert_serial)
    certificates = [c for c in api.call("GET", f"/certificates?{query}")["data"]
                    if normalized_serial(c["attributes"].get("serialNumber", "")) == wanted]
    if not certificates:
        print(f"No Developer ID Application certificate with serial {cert_serial} in this team — "
              "is MAC_DEVELOPER_ID_P12 an expired or revoked certificate?", file=sys.stderr)
        return 1

    query = urllib.parse.urlencode({"filter[name]": PROFILE_NAME, "limit": 200})
    for old in api.call("GET", f"/profiles?{query}")["data"]:
        api.call("DELETE", f"/profiles/{old['id']}")
        print(f"Deleted the old profile {old['attributes'].get('uuid')}")

    created = api.call("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": PROFILE_NAME, "profileType": "MAC_APP_DIRECT"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": certificates[0]["id"]}]},
        },
    }})["data"]["attributes"]

    content = base64.b64decode(created["profileContent"])
    for path in out_paths:
        with open(path, "wb") as f:
            f.write(content)
    print(f"Created {PROFILE_NAME} {created.get('uuid')} (expires {created.get('expirationDate')})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
