#!/bin/sh
# Tau-native remote helper shipped by the Hermes Ark Git fork.
#
# tau:// repositories store a Tau-native object graph.  Objects in Tau refer to
# other objects by tau:<sha256> identity only.  Git object IDs are used only in
# the local bridge cache needed to speak Git fast-import/fast-export to the
# client; they are never written to Tau manifests or Tau objects.

alias=$1
url=$2

case "$url" in
tau://*) repo=${url#tau://} ;;
*) echo "error unsupported tau url: $url"; exit 1 ;;
esac

repo=${repo#/}
repo=${repo%/}
case "$repo" in
""|*..*|*//*|/*) echo "error invalid tau repository name: $repo"; exit 1 ;;
esac

store=${GIT_TAU_STORE:-$HOME/.git-tau/store}
repo_dir=$store/repos/$repo
objects_dir=$store/objects
cache_git=$repo_dir/cache.git
latest=$repo_dir/latest.json
latest_addr=$repo_dir/latest.addr
tau_client=${GIT_TAU_CLIENT:-ant}
tau_manifest=${GIT_TAU_DEVNET_MANIFEST:-}
tau_network=${GIT_TAU_EVM_NETWORK:-local}

mkdir -p "$repo_dir" "$objects_dir"
if ! test -d "$cache_git"
then
	git init --bare "$cache_git" >/dev/null || exit 1
fi

h_refspec="refs/heads/*:refs/tau/$alias/heads/*"
t_refspec="refs/tags/*:refs/tau/$alias/tags/*"
client_git_dir=$(git rev-parse --git-dir 2>/dev/null || printf %s "$repo_dir/client")
mark_dir=$client_git_dir/tau-remote/$alias
mkdir -p "$mark_dir"
gitmarks="$mark_dir/git.marks"
taumarks="$mark_dir/tau.marks"
test -e "$gitmarks" || >"$gitmarks"
test -e "$taumarks" || >"$taumarks"
force=
object_format=

use_taustorage () {
	test -n "$tau_manifest"
}

object_path () {
	hash=$1
	printf '%s/%s/%s' "$objects_dir" "$(printf '%s' "$hash" | cut -c1-2)" "$(printf '%s' "$hash" | cut -c3-)"
}

tau_upload () {
	file=$1
	"$tau_client" file upload "$file" \
		--public \
		--devnet-manifest "$tau_manifest" \
		--allow-loopback \
		--evm-network "$tau_network" |
	tr ' 	' '\n\n' |
	sed -n 's/^\(tau:\/\/.*\)$/\1/p; s/^\(tau:.*\)$/\1/p' |
	tail -n 1
}

publish_manifest () {
	GIT_TAU_HELPER_REPO="$repo" \
	GIT_TAU_HELPER_CACHE="$cache_git" \
	GIT_TAU_HELPER_OBJECTS="$objects_dir" \
	GIT_TAU_HELPER_LATEST="$latest" \
	GIT_TAU_HELPER_LATEST_ADDR="$latest_addr" \
	GIT_TAU_HELPER_USE_STORAGE="$(use_taustorage && echo 1 || echo 0)" \
	GIT_TAU_HELPER_CLIENT="$tau_client" \
	GIT_TAU_HELPER_MANIFEST="$tau_manifest" \
	GIT_TAU_HELPER_NETWORK="$tau_network" \
	python3 - <<'PY'
import base64
import hashlib
import json
import os
import subprocess
from pathlib import Path

repo = os.environ["GIT_TAU_HELPER_REPO"]
cache = os.environ["GIT_TAU_HELPER_CACHE"]
objects_dir = Path(os.environ["GIT_TAU_HELPER_OBJECTS"])
latest = Path(os.environ["GIT_TAU_HELPER_LATEST"])
latest_addr = Path(os.environ["GIT_TAU_HELPER_LATEST_ADDR"])
use_storage = os.environ["GIT_TAU_HELPER_USE_STORAGE"] == "1"
client = os.environ["GIT_TAU_HELPER_CLIENT"]
manifest_path = os.environ["GIT_TAU_HELPER_MANIFEST"]
network = os.environ["GIT_TAU_HELPER_NETWORK"]

def git(*args, input=None):
	return subprocess.check_output(["git", f"--git-dir={cache}", *args], input=input)

def canonical(obj):
	return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()

def path_for(tau):
	return objects_dir / tau[:2] / tau[2:]

def upload(path):
	out = subprocess.check_output([
		client, "file", "upload", str(path),
		"--public",
		"--devnet-manifest", manifest_path,
		"--allow-loopback",
		"--evm-network", network,
	], text=True)
	addr = ""
	for part in out.replace("\t", " ").split():
		if part.startswith("tau://") or part.startswith("tau:"):
			addr = part
	if not addr:
		raise SystemExit(f"TauStorage upload returned no tau address: {out!r}")
	return addr

memo = {}
manifest_objects = {}

def write_obj(obj):
	data = canonical(obj)
	tau = hashlib.sha256(data).hexdigest()
	path = path_for(tau)
	path.parent.mkdir(parents=True, exist_ok=True)
	if not path.exists():
		path.write_bytes(data)
	entry = {"kind": obj["kind"], "size": len(data)}
	if use_storage:
		entry["taustorage"] = {"address": upload(path)}
	manifest_objects[tau] = entry
	return tau

def encode(oid):
	if oid in memo:
		return memo[oid]
	kind = git("cat-file", "-t", oid).decode().strip()
	body = git("cat-file", kind, oid)
	if kind == "blob":
		obj = {
			"schema_version": 1,
			"codec": "tau-native-v1",
			"kind": "blob",
			"content_b64": base64.b64encode(body).decode(),
		}
	elif kind == "tree":
		entries = []
		data = git("ls-tree", "-z", oid)
		for rec in data.split(b"\0"):
			if not rec:
				continue
			meta, name = rec.split(b"\t", 1)
			mode, child_kind, child_oid = meta.decode().split(" ")
			child_tau = encode(child_oid)
			entries.append({
				"mode": mode,
				"name_b64": base64.b64encode(name).decode(),
				"kind": child_kind,
				"object": f"tau:{child_tau}",
			})
		obj = {
			"schema_version": 1,
			"codec": "tau-native-v1",
			"kind": "tree",
			"entries": entries,
		}
	elif kind == "commit":
		headers_raw, message = (body.split(b"\n\n", 1) + [b""])[:2] if b"\n\n" in body else (body, b"")
		blocks = []
		for line in headers_raw.split(b"\n"):
			if line.startswith(b" ") and blocks:
				blocks[-1] += b"\n" + line
			else:
				blocks.append(line)
		tree_tau = None
		parents = []
		other_headers = []
		for block in blocks:
			if block.startswith(b"tree "):
				tree_tau = encode(block.split(b" ", 1)[1].decode())
			elif block.startswith(b"parent "):
				parents.append(f"tau:{encode(block.split(b' ', 1)[1].decode())}")
			elif block:
				other_headers.append(base64.b64encode(block).decode())
		if not tree_tau:
			raise SystemExit(f"commit {oid} has no tree")
		obj = {
			"schema_version": 1,
			"codec": "tau-native-v1",
			"kind": "commit",
			"tree": f"tau:{tree_tau}",
			"parents": parents,
			"headers_b64": other_headers,
			"message_b64": base64.b64encode(message).decode(),
		}
	elif kind == "tag":
		headers_raw, message = (body.split(b"\n\n", 1) + [b""])[:2] if b"\n\n" in body else (body, b"")
		blocks = headers_raw.split(b"\n")
		target_tau = None
		target_kind = None
		other_headers = []
		for block in blocks:
			if block.startswith(b"object "):
				target_tau = encode(block.split(b" ", 1)[1].decode())
			elif block.startswith(b"type "):
				target_kind = block.split(b" ", 1)[1].decode()
			elif block:
				other_headers.append(base64.b64encode(block).decode())
		if not target_tau or not target_kind:
			raise SystemExit(f"tag {oid} missing target")
		obj = {
			"schema_version": 1,
			"codec": "tau-native-v1",
			"kind": "tag",
			"object": f"tau:{target_tau}",
			"object_kind": target_kind,
			"headers_b64": other_headers,
			"message_b64": base64.b64encode(message).decode(),
		}
	else:
		raise SystemExit(f"unsupported Git object kind for tau://: {kind}")
	tau = write_obj(obj)
	memo[oid] = tau
	return tau

refs = {}
ref_lines = subprocess.check_output([
	"git", f"--git-dir={cache}", "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads", "refs/tags"
], text=True)
for line in ref_lines.splitlines():
	if not line:
		continue
	ref, oid = line.split(" ", 1)
	refs[ref] = f"tau:{encode(oid)}"

manifest = {
	"schema_version": 2,
	"repository": repo,
	"identity_mode": "tau-native",
	"object_codec": "tau-native-v1",
	"refs": refs,
	"objects": dict(sorted(manifest_objects.items())),
	"signing": {"algorithm": None, "signature": None},
}
latest.parent.mkdir(parents=True, exist_ok=True)
latest.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
if use_storage:
	latest_addr.write_text(upload(latest) + "\n")
PY
}

materialize_cache_from_manifest () {
	test -f "$latest" || return 0
	git --git-dir="$cache_git" show-ref --quiet && return 0
	GIT_TAU_HELPER_CLIENT="$tau_client" \
	GIT_TAU_HELPER_MANIFEST="$tau_manifest" \
	GIT_TAU_HELPER_NETWORK="$tau_network" \
	GIT_TAU_HELPER_CACHE="$cache_git" \
	GIT_TAU_HELPER_LATEST="$latest" \
	GIT_TAU_HELPER_OBJECTS="$objects_dir" \
	GIT_TAU_HELPER_USE_STORAGE="$(use_taustorage && echo 1 || echo 0)" \
	python3 - <<'PY'
import base64
import hashlib
import json
import os
import subprocess
from pathlib import Path

client = os.environ["GIT_TAU_HELPER_CLIENT"]
manifest_path = os.environ["GIT_TAU_HELPER_MANIFEST"]
network = os.environ["GIT_TAU_HELPER_NETWORK"]
cache = os.environ["GIT_TAU_HELPER_CACHE"]
latest = Path(os.environ["GIT_TAU_HELPER_LATEST"])
objects_dir = Path(os.environ["GIT_TAU_HELPER_OBJECTS"])
use_storage = os.environ["GIT_TAU_HELPER_USE_STORAGE"] == "1"
manifest = json.loads(latest.read_text())
manifest_objects = manifest.get("objects", {})

def path_for(tau):
	return objects_dir / tau[:2] / tau[2:]

def download(tau):
	path = path_for(tau)
	if path.exists():
		return path.read_bytes()
	if not use_storage:
		raise SystemExit(f"missing Tau object {tau}")
	addr = manifest_objects[tau].get("taustorage", {}).get("address")
	if not addr:
		raise SystemExit(f"missing TauStorage address for {tau}")
	path.parent.mkdir(parents=True, exist_ok=True)
	subprocess.run([
		client, "file", "download", addr, "-o", str(path),
		"--devnet-manifest", manifest_path,
		"--allow-loopback",
		"--evm-network", network,
	], check=True, stdout=subprocess.DEVNULL)
	return path.read_bytes()

def load(tau):
	data = download(tau)
	if hashlib.sha256(data).hexdigest() != tau:
		raise SystemExit(f"Tau object hash mismatch for {tau}")
	obj = json.loads(data)
	if obj.get("codec") != "tau-native-v1":
		raise SystemExit(f"unsupported Tau object codec for {tau}")
	return obj

memo = {}

def write_git(kind, body):
	return subprocess.check_output([
		"git", f"--git-dir={cache}", "hash-object", "-w", "-t", kind, "--stdin"
	], input=body).decode().strip()

def decode(tau_ref):
	tau = tau_ref.removeprefix("tau:")
	if tau in memo:
		return memo[tau]
	obj = load(tau)
	kind = obj["kind"]
	if kind == "blob":
		oid = write_git("blob", base64.b64decode(obj["content_b64"]))
	elif kind == "tree":
		data = b""
		for entry in obj["entries"]:
			child_oid = decode(entry["object"])
			name = base64.b64decode(entry["name_b64"])
			data += f"{entry['mode']} {entry['kind']} {child_oid}\t".encode() + name + b"\0"
		oid = subprocess.check_output([
			"git", f"--git-dir={cache}", "mktree", "-z"
		], input=data).decode().strip()
	elif kind == "commit":
		tree_oid = decode(obj["tree"])
		body = f"tree {tree_oid}\n".encode()
		for parent in obj.get("parents", []):
			body += f"parent {decode(parent)}\n".encode()
		for header in obj.get("headers_b64", []):
			body += base64.b64decode(header) + b"\n"
		body += b"\n" + base64.b64decode(obj.get("message_b64", ""))
		oid = write_git("commit", body)
	elif kind == "tag":
		target_oid = decode(obj["object"])
		body = f"object {target_oid}\ntype {obj['object_kind']}\n".encode()
		for header in obj.get("headers_b64", []):
			body += base64.b64decode(header) + b"\n"
		body += b"\n" + base64.b64decode(obj.get("message_b64", ""))
		oid = write_git("tag", body)
	else:
		raise SystemExit(f"unsupported Tau object kind {kind}")
	memo[tau] = oid
	return oid

for ref, tau_ref in manifest.get("refs", {}).items():
	oid = decode(tau_ref)
	subprocess.run(["git", f"--git-dir={cache}", "update-ref", ref, oid], check=True)
PY
}

while read line
do
	case $line in
	capabilities)
		echo 'import'
		echo 'export'
		echo "refspec $h_refspec"
		echo "refspec $t_refspec"
		echo "*import-marks $gitmarks"
		echo "*export-marks $gitmarks"
		echo 'option'
		echo 'object-format'
		echo
		;;
	list)
		materialize_cache_from_manifest || exit 1
		test -n "$object_format" && echo ":object-format $(git --git-dir="$cache_git" rev-parse --show-object-format=storage)"
		git --git-dir="$cache_git" for-each-ref --format='? %(refname)' refs/heads refs/tags
		head=$(git --git-dir="$cache_git" symbolic-ref HEAD 2>/dev/null || true)
		test -n "$head" && echo "@$head HEAD"
		echo
		;;
	import*)
		materialize_cache_from_manifest || exit 1
		refs=
		while true
		do
			ref="${line#* }"
			refs="$refs $ref"
			read line || break
			test "${line%% *}" != "import" && break
		done
		echo "feature import-marks=$gitmarks"
		echo "feature export-marks=$gitmarks"
		echo "feature done"
		git --git-dir="$cache_git" fast-export \
			--refspec="$h_refspec" \
			--refspec="$t_refspec" \
			--import-marks="$taumarks" \
			--export-marks="$taumarks" \
			$refs
		echo "done"
		;;
	export)
		before=$(git --git-dir="$cache_git" for-each-ref --format=' %(refname) %(objectname) ' refs/heads refs/tags)
		git --git-dir="$cache_git" fast-import \
			${force:+--force} \
			--import-marks="$taumarks" \
			--export-marks="$taumarks" \
			--quiet || exit 1
		publish_manifest || exit 1
		git --git-dir="$cache_git" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags |
		while read ref oid
		do
			case "$before" in
			*" $ref $oid "*) continue ;;
			esac
			echo "ok $ref"
		done
		echo
		;;
	option\ *)
		read cmd opt val <<-EOF
		$line
		EOF
		case $opt in
		force)
			test "$val" = true && force=true || force=
			echo ok
			;;
		object-format)
			test "$val" = true && object_format=true || object_format=
			echo ok
			;;
		*)
			echo unsupported
			;;
		esac
		;;
	'')
		exit
		;;
	esac
done
