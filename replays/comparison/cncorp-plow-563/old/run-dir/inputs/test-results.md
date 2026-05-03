**Result:** FAILED (exit 1)

Last 500 lines of `just test` output:
```
cd api && uv sync --reinstall-package plow-schemas
Using CPython 3.12.3 interpreter at: /usr/bin/python3
Creating virtual environment at: .venv
Resolved 112 packages in 0.67ms
   Building plow-schemas @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/api/schemas
      Built plow-schemas @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/api/schemas
Prepared 1 package in 241ms
warning: Failed to hardlink files; falling back to full copy. This may lead to degraded performance.
         If the cache and target directories are on different filesystems, hardlinking may not be supported.
         If this is intentional, set `export UV_LINK_MODE=copy` or use `--link-mode=copy` to suppress this warning.
Installed 109 packages in 474ms
 + aiohappyeyeballs==2.6.1
 + aiohttp==3.13.3
 + aiosignal==1.4.0
 + alembic==1.18.4
 + annotated-doc==0.0.4
 + annotated-types==0.7.0
 + anyio==4.12.1
 + attrs==25.4.0
 + backoff==2.2.1
 + basedpyright==1.38.2
 + bc-detect-secrets==1.5.46
 + boto3==1.42.97
 + botocore==1.42.97
 + certifi==2026.2.25
 + cffi==2.0.0
 + charset-normalizer==3.4.5
 + click==8.3.1
 + cryptography==46.0.7
 + distro==1.9.0
 + dnspython==2.8.0
 + email-validator==2.3.0
 + fastapi==0.135.1
 + fastapi-cli==0.0.24
 + fastapi-cloud-cli==0.15.0
 + fastar==0.8.0
 + fastuuid==0.14.0
 + filelock==3.25.2
 + frozenlist==1.8.0
 + fsspec==2026.2.0
 + greenlet==3.3.2
 + h11==0.16.0
 + hf-xet==1.4.2
 + httpcore==1.0.9
 + httptools==0.7.1
 + httpx==0.28.1
 + huggingface-hub==1.7.1
 + idna==3.11
 + importlib-metadata==8.7.1
 + iniconfig==2.3.0
 + itsdangerous==2.2.0
 + jinja2==3.1.6
 + jiter==0.13.0
 + jmespath==1.1.0
 + jsonschema==4.26.0
 + jsonschema-specifications==2025.9.1
 + linq-python==0.2.3
 + litellm==1.82.2
 + mako==1.3.10
 + markdown-it-py==4.0.0
 + markdown-to-mrkdwn==0.3.2
 + markupsafe==3.0.3
 + mdurl==0.1.2
 + multidict==6.7.1
 + nodejs-wheel-binaries==24.14.0
 + numpy==2.4.3
 + openai==2.28.0
 + packaging==26.0
 + pgvector==0.4.2
 + phonenumbers==9.0.27
 + plow-schemas==0.1.1 (from file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/api/schemas)
 + pluggy==1.6.0
 + posthog==7.13.1
 + propcache==0.4.1
 + psycopg==3.3.3
 + psycopg-binary==3.3.3
 + pycparser==3.0
 + pydantic==2.12.5
 + pydantic-core==2.41.5
 + pydantic-extra-types==2.11.0
 + pydantic-settings==2.13.1
 + pygments==2.19.2
 + pytest==9.0.2
 + pytest-asyncio==1.3.0
 + pytest-timeout==2.4.0
 + python-dateutil==2.9.0.post0
 + python-dotenv==1.2.2
 + python-multipart==0.0.22
 + pyyaml==6.0.3
 + referencing==0.37.0
 + regex==2026.2.28
 + requests==2.32.5
 + rich==14.3.3
 + rich-toolkit==0.19.7
 + rignore==0.7.6
 + rpds-py==0.30.0
 + ruff==0.15.6
 + s3transfer==0.16.1
 + sentry-sdk==2.54.0
 + shellingham==1.5.4
 + six==1.17.0
 + slack-sdk==3.41.0
 + sniffio==1.3.1
 + sqlalchemy==2.0.48
 + starlette==0.52.1
 + stripe==15.0.0
 + tiktoken==0.12.0
 + tokenizers==0.22.2
 + tqdm==4.67.3
 + typer==0.24.1
 + typing-extensions==4.15.0
 + typing-inspection==0.4.2
 + unidiff==0.7.5
 + urllib3==2.6.3
 + uvicorn==0.41.0
 + uvloop==0.22.1
 + watchfiles==1.1.1
 + websockets==16.0
 + yarl==1.23.0
 + zipp==3.23.0
── basedpyright (api) ──
cd api && uv run basedpyright
0 errors, 0 warnings, 0 notes
── basedpyright (cli) ──
cd cli && uv run basedpyright
Using CPython 3.12.3 interpreter at: /usr/bin/python3
Creating virtual environment at: .venv
   Building plow-cli @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/cli
      Built plow-cli @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/cli
warning: Failed to hardlink files; falling back to full copy. This may lead to degraded performance.
         If the cache and target directories are on different filesystems, hardlinking may not be supported.
         If this is intentional, set `export UV_LINK_MODE=copy` or use `--link-mode=copy` to suppress this warning.
Installed 21 packages in 401ms
0 errors, 0 warnings, 0 notes
── basedpyright (plow-ops) ──
cd cli/plow-ops && uv run basedpyright
Using CPython 3.12.3 interpreter at: /usr/bin/python3
Creating virtual environment at: .venv
   Building plow-ops @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/cli/plow-ops
      Built plow-ops @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/cli/plow-ops
warning: Failed to hardlink files; falling back to full copy. This may lead to degraded performance.
         If the cache and target directories are on different filesystems, hardlinking may not be supported.
         If this is intentional, set `export UV_LINK_MODE=copy` or use `--link-mode=copy` to suppress this warning.
Installed 9 packages in 376ms
0 errors, 0 warnings, 0 notes
── basedpyright (dtu/linq) ──
cd dtu/linq && uv run basedpyright
Using CPython 3.12.3 interpreter at: /usr/bin/python3
Creating virtual environment at: .venv
   Building plow-linq-twin @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/dtu/linq
      Built plow-linq-twin @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/dtu/linq
warning: Failed to hardlink files; falling back to full copy. This may lead to degraded performance.
         If the cache and target directories are on different filesystems, hardlinking may not be supported.
         If this is intentional, set `export UV_LINK_MODE=copy` or use `--link-mode=copy` to suppress this warning.
Installed 50 packages in 400ms
0 errors, 0 warnings, 0 notes
── basedpyright (dtu/gmail) ──
cd dtu/gmail && uv run basedpyright
Using CPython 3.12.3 interpreter at: /usr/bin/python3
Creating virtual environment at: .venv
   Building plow-gmail-twin @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/dtu/gmail
      Built plow-gmail-twin @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/dtu/gmail
warning: Failed to hardlink files; falling back to full copy. This may lead to degraded performance.
         If the cache and target directories are on different filesystems, hardlinking may not be supported.
         If this is intentional, set `export UV_LINK_MODE=copy` or use `--link-mode=copy` to suppress this warning.
Installed 50 packages in 403ms
0 errors, 0 warnings, 0 notes
── basedpyright (dtu/google-oauth) ──
cd dtu/google-oauth && uv run basedpyright
Using CPython 3.12.3 interpreter at: /usr/bin/python3
Creating virtual environment at: .venv
   Building plow-google-oauth-twin @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/dtu/google-oauth
      Built plow-google-oauth-twin @ file:///home/odio/.pr-reviewer/workdirs/cncorp_plow__563/dtu/google-oauth
warning: Failed to hardlink files; falling back to full copy. This may lead to degraded performance.
         If the cache and target directories are on different filesystems, hardlinking may not be supported.
         If this is intentional, set `export UV_LINK_MODE=copy` or use `--link-mode=copy` to suppress this warning.
Installed 50 packages in 405ms
0 errors, 0 warnings, 0 notes
# TODO(@plucas): re-enable basedpyright for plowd once plow-schemas dependency is wired up
# @echo "── basedpyright (plowd) ──"
# cd app/plowd && uv run basedpyright
── ruff ──
cd api && uv run ruff check .
All checks passed!
cd cli/plow-ops && uv run ruff check .
All checks passed!
── fmt-check ──
uv run ruff format --check .
284 files already formatted
error: Recipe `lint-extras` could not be run because of an IO error while trying to create a temporary directory or write a file to that directory: No such file or directory (os error 2) at path "/tmp/just-bAMK4i"
error: Recipe `lint` failed on line 334 with exit code 1
error: Recipe `test-fast` failed on line 17 with exit code 1
```