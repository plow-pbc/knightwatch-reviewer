### app/justfile
4edb5796 PLO-29: drop custom DMG volume icon
7dd69f55 Switch release signing from cncorp to The Plow Collective Apple team (#555)
e247b5bf skills: prefer Plow team signing in plow-{dev,prod}-install, ad-hoc fallback (#521)
b2be15e3 feat: Slack Participate mode, VMStartupOrchestrator refactor, iMessage debounce, and related fixes (#437)
f5f9fa2f merge: integrate released-main into main with compatibility fixes (#420)

### app/plowd/dmg/volume.icns
4edb5796 PLO-29: drop custom DMG volume icon
06caf4a3 Update macOS app icons and add custom ~/Plow folder icon (#100)
80e32146 Improve DMG packaging (#10)

### app/plowd/scripts/plowd-beta-package-signed
f75802c5 PLO-29 r1: wire dmg-verify into the release path
4edb5796 PLO-29: drop custom DMG volume icon
7dd69f55 Switch release signing from cncorp to The Plow Collective Apple team (#555)
b2be15e3 feat: Slack Participate mode, VMStartupOrchestrator refactor, iMessage debounce, and related fixes (#437)
6d37d484 hotfix(release): drop stale --gatekeeper-manifest flag (#390)

### app/plowd/scripts/plowd-verify-dmg
dcb80a5a PLO-29 r2: run dmg-verify on macOS CI; fail loud on detach failure
4edb5796 PLO-29: drop custom DMG volume icon

### app/plowd/tests/test_release_scripts.py
dcb80a5a PLO-29 r2: run dmg-verify on macOS CI; fail loud on detach failure
f75802c5 PLO-29 r1: wire dmg-verify into the release path
4edb5796 PLO-29: drop custom DMG volume icon
7dd69f55 Switch release signing from cncorp to The Plow Collective Apple team (#555)
80f5110f test(plow-install): regression coverage for launch_and_wait_ready prod port discovery (#540)

### .github/workflows/test.yml
dcb80a5a PLO-29 r2: run dmg-verify on macOS CI; fail loud on detach failure
68b7e25b remove watchmepivot to standalone repo (#564)
0b0da5e1 feat(tutorials): add tutorial library renderer + Vercel routes (#547)
7da6f550 Wire up Vercel Analytics on plow.co + add /private-preview alias (#543)
082f285c watchmepivot.com: per-repo breakdown on Development cards (#520)

