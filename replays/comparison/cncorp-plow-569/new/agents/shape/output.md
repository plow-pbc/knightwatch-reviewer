## shape findings

### Surveyed
- Volume icon removal from staging and direct `ULFO` DMG creation — clean
- Mandatory final-artifact verifier before upload — clean
- `just app dmg-verify` as a thin verifier alias — clean
- Cross-platform fake-`hdiutil` verifier tests plus Darwin real-`hdiutil` guard — clean
- Finder layout recorder introduced with checked-in `.DS_Store` — see Finding 1
- Mountpoint parsing shape across release, verifier, and recorder scripts — see Finding 1

### Finding 1 — medium
Will `hdiutil attach` output stay stable enough across macOS versions for this PR to maintain multiple independent parsers? The PR establishes the `awk '$NF ~ /^\//'` parser in both the release script and verifier, but the new recorder immediately uses the older `sed -n 's|.*\(/Volumes/.*\)$|\1|p'` shape in both mount passes. Under `Name the Shape`, this is a same-problem parallel construct; Broken-Glass Test favors collapsing duplicate parsing. Remedy cost is a small shared shell helper or one parser shape, not extra defensive branches.
Files: app/plowd/scripts/plowd-record-dmg-layout:160, app/plowd/scripts/plowd-record-dmg-layout:186, app/plowd/scripts/plowd-verify-dmg:89, app/plowd/scripts/plowd-beta-package-signed:276