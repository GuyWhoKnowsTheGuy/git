#!/bin/sh
# Tau-native remote helper shipped by the Hermes Ark Git fork.
#
# tau:// repositories are Tau-native: published refs point at tau:<hash> values
# in the manifest.  The helper currently stores git-raw-v1 payloads so the forked
# Git client can import/export through Git's fast-import protocol.

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

json_escape () {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

object_path () {
	hash=$1
	printf '%s/%s/%s' "$objects_dir" "$(printf '%s' "$hash" | cut -c1-2)" "$(printf '%s' "$hash" | cut -c3-)"
}

store_git_object () {
	oid=$1
	type=$(git --git-dir="$cache_git" cat-file -t "$oid") || return 1
	size=$(git --git-dir="$cache_git" cat-file -s "$oid") || return 1
	tmp=$repo_dir/object-$$-$oid.tmp
	{
		printf '%s %s\0' "$type" "$size" &&
		git --git-dir="$cache_git" cat-file "$type" "$oid"
	} >"$tmp" || return 1
	hash=$(sha256sum "$tmp" | sed 's/ .*//') || return 1
	path=$(object_path "$hash")
	mkdir -p "$(dirname "$path")" || return 1
	if ! test -f "$path"
	then
		mv "$tmp" "$path" || return 1
	else
		rm -f "$tmp"
	fi
	printf '%s %s %s %s\n' "$hash" "$oid" "$type" "$size"
}

publish_manifest () {
	refs_tmp=$repo_dir/refs-$$.tmp
	objects_tmp=$repo_dir/objects-$$.tmp
	manifest_tmp=$repo_dir/latest-$$.json
	: >"$refs_tmp"
	: >"$objects_tmp"

	git --git-dir="$cache_git" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags |
	while read ref oid
	do
		test -n "$ref" || continue
		rec=$(store_git_object "$oid") || exit 1
		tau_hash=${rec%% *}
		printf '%s %s %s\n' "$ref" "$tau_hash" "$oid" >>"$refs_tmp"
	done || return 1

	git --git-dir="$cache_git" rev-list --objects --all |
	while read oid rest
	do
		test -n "$oid" || continue
		store_git_object "$oid" >>"$objects_tmp" || exit 1
	done || return 1

	{
		echo '{'
		echo '  "schema_version": 1,'
		echo "  \"repository\": \"$(json_escape "$repo")\","
		echo '  "identity_mode": "tau-native",'
		echo '  "payload_codec": "git-raw-v1",'
		echo '  "refs": {'
		sep=''
		while read ref tau_hash oid
		do
			test -n "$ref" || continue
			printf '%s    "%s": "tau:%s"' "$sep" "$(json_escape "$ref")" "$tau_hash"
			sep=',
'
		done <"$refs_tmp"
		test -z "$sep" || echo
		echo '  },'
		echo '  "objects": {'
		sep=''
		sort -u "$objects_tmp" |
		while read tau_hash oid type size
		do
			test -n "$tau_hash" || continue
			printf '%s    "%s": {"kind": "%s", "payload_codec": "git-raw-v1", "size": %s, "git": {"hash_algorithm": "sha1", "oid": "%s"}}' "$sep" "$tau_hash" "$type" "$size" "$oid"
			sep=',
'
		done
		test -z "$sep" || echo
		echo '  },'
		echo '  "git_to_tau": {'
		sep=''
		sort -u "$objects_tmp" |
		while read tau_hash oid type size
		do
			test -n "$tau_hash" || continue
			printf '%s    "git:sha1:%s": "%s"' "$sep" "$oid" "$tau_hash"
			sep=',
'
		done
		test -z "$sep" || echo
		echo '  },'
		echo '  "signing": {"algorithm": null, "signature": null}'
		echo '}'
	} >"$manifest_tmp" || return 1
	mv "$manifest_tmp" "$latest" || return 1
	rm -f "$refs_tmp" "$objects_tmp"
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
		test -n "$object_format" && echo ":object-format $(git --git-dir="$cache_git" rev-parse --show-object-format=storage)"
		git --git-dir="$cache_git" for-each-ref --format='? %(refname)' refs/heads refs/tags
		head=$(git --git-dir="$cache_git" symbolic-ref HEAD 2>/dev/null || true)
		test -n "$head" && echo "@$head HEAD"
		echo
		;;
	import*)
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
