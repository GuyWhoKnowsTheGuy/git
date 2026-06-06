#!/bin/sh

test_description='Tau native remote helper shipped with Git'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

PATH="$GIT_BUILD_DIR:$PATH"
export PATH

assert_tau_manifest_has_native_ref () {
	manifest="$1"
	refname="$2"
	test_path_is_file "$manifest" &&
	test_grep '"identity_mode": "tau-native"' "$manifest" &&
	test_grep '"object_codec": "tau-native-v1"' "$manifest" &&
	test_grep "\"$refname\": \"tau:" "$manifest"
}

assert_no_git_identity_in_tau_manifest () {
	manifest="$1"
	! test_grep 'sha1' "$manifest" &&
	! test_grep 'git_to_tau' "$manifest" &&
	! test_grep '"git"' "$manifest" &&
	! test_grep '"oid"' "$manifest" &&
	! test_grep 'git-raw-v1' "$manifest"
}

walk_tau_history () {
	GIT_TAU_WALK_STORE="$1" GIT_TAU_WALK_REPO="$2" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

store = Path(os.environ["GIT_TAU_WALK_STORE"])
repo = os.environ["GIT_TAU_WALK_REPO"]
manifest = json.loads((store / "repos" / repo / "latest.json").read_text())
assert manifest["identity_mode"] == "tau-native"
assert manifest["object_codec"] == "tau-native-v1"
blob_count = 0
commit_count = 0
seen = set()

def path_for(tau):
	assert re.fullmatch(r"[0-9a-f]{64}", tau), tau
	return store / "objects" / tau[:2] / tau[2:]

def load(tau):
	obj = json.loads(path_for(tau).read_bytes())
	assert "git" not in obj
	assert "oid" not in obj
	return obj

def walk(tau):
	global blob_count, commit_count
	if tau in seen:
		return
	seen.add(tau)
	obj = load(tau)
	kind = obj["kind"]
	if kind == "commit":
		commit_count += 1
		walk(obj["tree"].removeprefix("tau:"))
		for parent in obj.get("parents", []):
			walk(parent.removeprefix("tau:"))
	elif kind == "tree":
		for entry in obj["entries"]:
			walk(entry["object"].removeprefix("tau:"))
	elif kind == "blob":
		blob_count += 1
	elif kind == "tag":
		walk(obj["object"].removeprefix("tau:"))
	else:
		raise AssertionError(kind)

for ref, tau_ref in manifest["refs"].items():
	assert tau_ref.startswith("tau:"), (ref, tau_ref)
	walk(tau_ref.removeprefix("tau:"))
assert commit_count >= 2, commit_count
assert blob_count >= 1, blob_count
print(f"walked {commit_count} commits and {blob_count} blobs exclusively by Tau hash")
PY
}

write_fake_tau_client () {
	cat >fake-ant <<-'EOF'
	#!/usr/bin/env python3
	import hashlib
	import os
	import shutil
	import sys
	from pathlib import Path

	root = Path(os.environ["FAKE_TAU_ROOT"])
	files = root / "files"
	files.mkdir(parents=True, exist_ok=True)
	with (root / "calls.log").open("a") as log:
	    log.write(" ".join(sys.argv[1:]) + "\n")
	args = sys.argv[1:]
	if args[:2] == ["file", "upload"]:
	    src = Path(args[2])
	    data = src.read_bytes()
	    digest = hashlib.sha256(data).hexdigest()
	    shutil.copyfile(src, files / digest)
	    print(f"Uploaded file address: tau://{digest}")
	elif args[:2] == ["file", "download"]:
	    address = args[2]
	    out = Path(args[args.index("-o") + 1])
	    digest = address.rsplit("/", 1)[-1]
	    shutil.copyfile(files / digest, out)
	    print(f"Downloaded {address}")
	else:
	    print("unsupported fake ant args", args, file=sys.stderr)
	    sys.exit(1)
	EOF
	chmod +x fake-ant
}

test_expect_success 'git client stores tau:// history as a Tau-native object graph' '
	GIT_TAU_STORE="$PWD/tau-store" &&
	export GIT_TAU_STORE &&
	git init source &&
	(
		cd source &&
		test_commit initial file one &&
		test_commit second file two &&
		git remote add origin tau://demo &&
		git push origin main
	) &&
	assert_tau_manifest_has_native_ref tau-store/repos/demo/latest.json refs/heads/main &&
	assert_no_git_identity_in_tau_manifest tau-store/repos/demo/latest.json &&
	walk_tau_history tau-store demo &&
	git clone tau://demo clone &&
	test_cmp source/file clone/file &&
	(
		cd clone &&
		test $(git rev-list --count HEAD) -eq 2
	)
'

test_expect_success 'tau:// helper stores and retrieves Tau-native objects through TauStorage client API' '
	GIT_TAU_STORE="$PWD/network-store" &&
	FAKE_TAU_ROOT="$PWD/fake-tau" &&
	GIT_TAU_CLIENT="$PWD/fake-ant" &&
	GIT_TAU_DEVNET_MANIFEST="$PWD/devnet-manifest.json" &&
	GIT_TAU_EVM_NETWORK=local &&
	export GIT_TAU_STORE FAKE_TAU_ROOT GIT_TAU_CLIENT GIT_TAU_DEVNET_MANIFEST GIT_TAU_EVM_NETWORK &&
	write_fake_tau_client &&
	touch "$GIT_TAU_DEVNET_MANIFEST" &&
	git init network-source &&
	(
		cd network-source &&
		test_commit network-one file alpha &&
		test_commit network-two file beta &&
		git remote add origin tau://networked &&
		git push origin main
	) &&
	assert_tau_manifest_has_native_ref network-store/repos/networked/latest.json refs/heads/main &&
	assert_no_git_identity_in_tau_manifest network-store/repos/networked/latest.json &&
	walk_tau_history network-store networked &&
	test_path_is_file network-store/repos/networked/latest.addr &&
	test_grep "\"address\": \"tau://" network-store/repos/networked/latest.json &&
	test_grep "file upload" fake-tau/calls.log &&
	rm -rf network-store/repos/networked/cache.git network-store/objects &&
	git clone tau://networked network-clone &&
	test_cmp network-source/file network-clone/file &&
	(
		cd network-clone &&
		test $(git rev-list --count HEAD) -eq 2
	) &&
	test_grep "file download" fake-tau/calls.log
'

test_done
