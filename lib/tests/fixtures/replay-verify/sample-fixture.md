---
repo: srosro/knightwatch-reviewer
pr: 50
sha: 9a91536000000000000000000000000000000000
exercise: synthetic for smoke parser test
canary_class: positive
---

## expected_verdict

COMMENT

## expected_findings

- name: simplification-surfaces
  keywords_all: [simplification]
  keywords_any: [substrate, replacement]
  severity_min: medium
  class_any: [simplification]

## expected_NOT

- name: no-spurious-security-blocking
  keywords_any: [credential, secret, exfiltration]
  severity_min: blocking
