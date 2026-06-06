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
	test_grep '"payload_codec": "git-raw-v1"' "$manifest" &&
	test_grep "\"$refname\": \"tau:" "$manifest"
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

test_expect_success 'git client includes tau:// push clone fetch transport' '
	GIT_TAU_STORE="$PWD/tau-store" &&
	export GIT_TAU_STORE &&
	git init source &&
	(
		cd source &&
		test_commit initial file one &&
		git remote add origin tau://demo &&
		git push origin main
	) &&
	assert_tau_manifest_has_native_ref tau-store/repos/demo/latest.json refs/heads/main &&
	git clone tau://demo clone &&
	test_cmp source/file clone/file &&
	(
		cd source &&
		test_commit second file two &&
		git push origin main
	) &&
	(
		cd clone &&
		git fetch origin &&
		git merge --ff-only origin/main
	) &&
	test_cmp source/file clone/file
'

test_expect_success 'tau:// helper stores and retrieves objects through TauStorage client API' '
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
		test_commit network file alpha &&
		git remote add origin tau://networked &&
		git push origin main
	) &&
	assert_tau_manifest_has_native_ref network-store/repos/networked/latest.json refs/heads/main &&
	test_path_is_file network-store/repos/networked/latest.addr &&
	test_grep "\"taustorage\": {\"address\": \"tau://" network-store/repos/networked/latest.json &&
	test_grep "file upload" fake-tau/calls.log &&
	rm -rf network-store/repos/networked/cache.git network-store/objects &&
	git clone tau://networked network-clone &&
	test_cmp network-source/file network-clone/file &&
	test_grep "file download" fake-tau/calls.log
'

test_done
