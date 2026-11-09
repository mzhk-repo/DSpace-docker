#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/dspace/config"
cp "$root/scripts/patch-submission-forms.sh" "$tmp/scripts/"
cp "$root/dspace/config/submission-forms.xml" "$tmp/dspace/config/"
cp "$root/dspace/config/submission-forms-10.1-additions.xml" "$tmp/dspace/config/"
python3 - "$tmp/dspace/config/submission-forms.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
tree = ET.parse(sys.argv[1])
forms = tree.getroot().find('./form-definitions')
for form in list(forms):
    if form.get('name') in ('owner', 'datasetStep'):
        forms.remove(form)
ET.indent(tree, space='    ')
tree.write(sys.argv[1], encoding='unicode', xml_declaration=True)
PY
printf 'DSPACE_REST_VER=dspace-9_x\n' > "$tmp/env"
before="$(sha256sum "$tmp/dspace/config/submission-forms.xml")"
ORCHESTRATOR_ENV_FILE="$tmp/env" bash "$tmp/scripts/patch-submission-forms.sh" >/dev/null
[[ "$before" == "$(sha256sum "$tmp/dspace/config/submission-forms.xml")" ]]
printf 'DSPACE_REST_VER=dspace-10.1\n' > "$tmp/env"
cp "$tmp/dspace/config/submission-forms.xml" "$tmp/before.xml"
ORCHESTRATOR_ENV_FILE="$tmp/env" DSPACE_BACKEND_RESTART_FLAG_FILE="$tmp/restart" bash "$tmp/scripts/patch-submission-forms.sh" >/dev/null
python3 - "$tmp/dspace/config/submission-forms.xml" "$tmp/before.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
forms = root.findall('./form-definitions/form[@name="owner"]')
assert len(forms) == 1
assert len(root.findall('./form-definitions/form[@name="datasetStep"]')) == 1
before = ET.parse(sys.argv[2]).getroot()
for form in before.findall('./form-definitions/form'):
    current = root.find(f'./form-definitions/form[@name="{form.get("name")}"]')
    assert ET.tostring(form) == ET.tostring(current)
field = forms[0].find('./row/field')
assert [field.findtext(tag) for tag in ('dc-schema', 'dc-element', 'dc-qualifier')] == ['dspace', 'object', 'owner']
PY
[[ -s "$tmp/restart" ]]
rm "$tmp/restart"
before="$(sha256sum "$tmp/dspace/config/submission-forms.xml")"
ORCHESTRATOR_ENV_FILE="$tmp/env" DSPACE_BACKEND_RESTART_FLAG_FILE="$tmp/restart" bash "$tmp/scripts/patch-submission-forms.sh" >/dev/null
[[ "$before" == "$(sha256sum "$tmp/dspace/config/submission-forms.xml")" && ! -e "$tmp/restart" ]]
printf 'DSpace 10 forms added once; restart flag is idempotent\n'
