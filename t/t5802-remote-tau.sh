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

test_done
