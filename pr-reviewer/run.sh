#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

function main {
	if [[ $(uname --nodename) == sandbox ]]
	then
		echo "Do not run this inside the AI sandbox."

		exit 1
	fi

	local closed_prs=""
	local command=${1:-}
	local dry_run=false
	local pr_number=${2:-}

	if [[ ${command} == --dry-run ]]
	then
		dry_run=true

		shift

		command=${1:-}
		pr_number=${2:-}
	fi

	if [[ ${command} == check ]]
	then
		if [[ -z ${pr_number} ]]
		then
			while true
			do
				local count=0
				local reviewed=false

				for pr_number in $(gh api --paginate "repos/${_REPO}/pulls?state=open" | jq --raw-output ".[].number")
				do
					if _check_pr
					then
						count=$((count + 1))
					fi
				done

				if [[ ${count} -eq 1 ]]
				then
					echo "Closed 1 PR at $(date +"%-l:%M %P")."
				else
					echo "Closed ${count} PRs at $(date +"%-l:%M %P")."
				fi

				if ! ${reviewed}
				then
					sleep 5m
				fi
			done
		else
			local reviewed=false

			_check_pr
		fi
	elif [[ ${command} == review ]]
	then
		if [[ -z ${pr_number} ]]
		then
			_print_help
		fi

		_get_automatic_code_review_json
	else
		_print_help
	fi
}

function _check_pr {
	if [[ " ${closed_prs} " == *" ${pr_number} "* ]]
	then
		return 1
	fi

	echo -n "Checking ${pr_number}."

	local i mergeable mergeable_state rebaseable state

	for ((i = 0; i < 5; i++))
	do
		local pr_json

		if ! pr_json=$(gh api "repos/${_REPO}/pulls/${pr_number}" 2>&1)
		then
			echo ""
			echo "${pr_json}"

			exit 1
		fi

		state=$(echo "${pr_json}" | jq --raw-output ".state")

		if [[ ${state} != open ]]
		then
			closed_prs+=" ${pr_number}"

			echo ""
			echo ""
			echo "Skipping ${pr_number}."
			echo ""

			return 1
		fi

		mergeable=$(echo "${pr_json}" | jq --raw-output ".mergeable")
		mergeable_state=$(echo "${pr_json}" | jq --raw-output ".mergeable_state")
		rebaseable=$(echo "${pr_json}" | jq --raw-output ".rebaseable")

		if [[ ${mergeable} != null ]]
		then
			echo ""

			break
		fi

		echo -n .

		sleep $((5 * (i + 1)))
	done

	if [[ ${mergeable} == false ]] || \
	   [[ ${mergeable_state} == dirty ]] || \
	   [[ ${rebaseable} == false ]]
	then
		echo ""
		echo "Closing unmergeable ${pr_number}:"

		local base_ref=$(echo "${pr_json}" | jq --raw-output ".base.ref")

		_fetch_pr

		local conflicts

		conflicts=$(git merge-tree --name-only --write-tree origin/${base_ref} FETCH_HEAD 2> /dev/null | sed --quiet "2,/^$/{/^$/!p}" | head --lines=30) || true

		if [[ -n ${conflicts} ]]
		then
			echo "${conflicts}" | sed "s/^/    /"
		fi

		echo ""

		if ! ${dry_run}
		then
			gh pr close ${pr_number} --comment "Resend this PR because it has rebase errors." --repo ${_REPO}

			closed_prs+=" ${pr_number}"
		fi

		echo ""

		return 0
	fi

	if gh api "repos/${_REPO}/issues/${pr_number}/comments" \
		--jq ".[].body" 2>&1 | grep --quiet "#bchan-bot-pr-review"
	then
		return 1
	fi

	reviewed=true

	local automatic_code_review_json

	automatic_code_review_json=$(_get_automatic_code_review_json)

	local count=$(echo "${automatic_code_review_json}" | jq "length")
	local index
	local max_chance=$(echo "${automatic_code_review_json}" | jq "map(.chance) | max")

	local usernames

	usernames=$(
		{
			gh api "repos/${_REPO}/issues/${pr_number}/comments" --jq ".[].user.login | select(. != null)" 2> /dev/null
			gh api "repos/${_REPO}/pulls/${pr_number}/comments" --jq ".[].user.login | select(. != null)" 2> /dev/null
			gh api "repos/${_REPO}/pulls/${pr_number}/commits" --jq ".[].author.login | select(. != null)" 2> /dev/null
			gh api "repos/${_REPO}/pulls/${pr_number}/reviews" --jq ".[].user.login | select(. != null)" 2> /dev/null
		} | grep --invert-match liferay-continuous-integration | sort --unique | tr "[:upper:]" "[:lower:]"
	)

	local at_usernames=$(echo "${usernames}" | sed "s/^/@/" | tr "\n" " " | sed "s/ *$//")

	local body="${at_usernames}"$'\n\n'"There is $(_get_indefinite_article_for_number "${max_chance}") ${max_chance}% chance that Brian will reject this PR."

	for ((index = 0; index < count; index++))
	do
		local chance=$(echo "${automatic_code_review_json}" | jq --raw-output ".[${index}].chance")

		if [[ ${chance} -eq 0 ]]
		then
			continue
		fi

		local model=$(echo "${automatic_code_review_json}" | jq --raw-output ".[${index}].model")
		local violations=$(echo "${automatic_code_review_json}" | jq --raw-output ".[${index}].violations[]" | sed "s/^/- /")

		if [[ -n ${body} ]]
		then
			body+=$'\n\n'
		fi

		body+="${model} (${chance}% chance of rejection):"$'\n'"${violations}"
	done

	echo ""
	echo "${body}"
	echo ""

	if ! ${dry_run}
	then
		gh pr comment ${pr_number} \
			--body "${body}"$'\n\n'"#bchan-bot-pr-review" \
			--repo ${_REPO}

		echo ""
	fi

	if true
	then
		return 1
	elif [[ ${max_chance} -gt 50 ]]
	then
		echo "Closing ${pr_number} (${max_chance}% dirty)."
		echo ""

		if ! ${dry_run}
		then
			gh pr close ${pr_number} \
				--comment "Closing PR because ${max_chance}% dirty exceeds the 50% threshold. ${at_usernames} lose 5 points."$'\n\n'"#bchan-bot-pr-review" \
				--repo ${_REPO}

			closed_prs+=" ${pr_number}"

			echo ""

			_update_points -5 "${usernames}"
		fi
	elif [[ ${max_chance} -lt 10 ]]
	then
		if ! ${dry_run}
		then
			gh pr comment ${pr_number} \
				--body "${at_usernames} gain 1 point for a clean PR."$'\n\n'"#bchan-bot-pr-review" \
				--repo ${_REPO}

			echo ""

			_update_points 1 "${usernames}"
		fi
	fi

	return 1
}

function _fetch_pr {
	timeout 60 git fetch --quiet origin pull/${pr_number}/head || true
}

function _get_automatic_code_review_json {
	_fetch_pr

	local diff_file

	local diff_range=FETCH_HEAD..FETCH_HEAD

	local from_commit=$(git cherry master FETCH_HEAD | grep "^+" | head --lines=1 | cut --delimiter=" " --fields=2)

	if [[ -n ${from_commit} ]]
	then
		diff_range="${from_commit}^..FETCH_HEAD"
	fi

	local generated_files=""

	for diff_file in $(git diff --name-only ${diff_range} || true)
	do
		if git grep --ignore-case --quiet "@generated" FETCH_HEAD -- ":(top)${diff_file}" 2> /dev/null
		then
			generated_files+="|${diff_file}"
		fi
	done

	git diff ${diff_range} | awk -v generated_files="${generated_files}|" -v ignored_suffixes="${_IGNORED_SUFFIXES}" '
		BEGIN {
			split(ignored_suffixes, suffixes, " ")
		}
		/^diff --git / {
			file = substr($3, 3)

			skip = index(generated_files, "|" file "|") > 0 || file ~ /(^|\/)yarn\.lock$/

			for (i in suffixes) {
				if (file ~ ("\\." suffixes[i] "$")) {
					skip = 1
				}
			}
		}
		! skip
	' > /tmp/pr-${pr_number}.diff

	local pids=()

	for model in "${_MODELS[@]}"
	do
		_write_model_json_file ${model} &

		pids+=($!)
	done

	for pid in "${pids[@]}"
	do
		wait "${pid}" || true
	done

	rm --force /tmp/pr-${pr_number}.diff

	local automatic_code_review_json="[]"

	for model in "${_MODELS[@]}"
	do
		local model_json=$(cat /tmp/pr-${pr_number}-${model}.json 2> /dev/null) || model_json=""

		if ! ${dry_run}
		then
			rm --force /tmp/pr-${pr_number}-${model}.json
		fi

		if ! echo "${model_json}" | jq . > /dev/null 2>&1
		then
			model_json="{\"chance\": 0, \"seconds\": 0, \"violations\": []}"
		fi

		automatic_code_review_json=$(echo "${automatic_code_review_json}" | jq --arg model "${model}" --argjson model_json "${model_json}" ". + [\$model_json + {model: \$model}]")
	done

	echo "${automatic_code_review_json}"
}

function _get_indefinite_article_for_number {
	local number=${1}

	if [[ ${number} =~ ^(8|11|18|8[0-9])$ ]]
	then
		echo an
	else
		echo a
	fi
}

function _print_help {
	echo "Usage:"
	echo "    ${0} [--dry-run] check [pr]    Check all open PRs or just [pr]"
	echo "    ${0} [--dry-run] review <pr>   Review <pr> and print JSON"

	exit 1
}

function _review_in_sandbox {
	timeout \
		--kill-after=10s 15m \
		\
		bwrap \
			--as-pid-1 \
			--bind /home/me/.ai_sandbox/home /home/me \
			--chdir /tmp \
			--clearenv \
			--dev /dev \
			--die-with-parent \
			--hostname sandbox \
			--proc /proc \
			--ro-bind "$(pwd)/STYLE.md" /review/STYLE.md \
			--ro-bind "$(pwd)/rules" /review/rules \
			--ro-bind "$(pwd)/sandbox-bin" /review/sandbox-bin \
			--ro-bind /home/me/dev/projects/liferay-portal /review/liferay-portal \
			--ro-bind /tmp/pr-${pr_number}.diff /review/pr.diff \
			--ro-bind /etc /etc \
			--ro-bind /usr /usr \
			--setenv HOME /home/me \
			--setenv LANG en_US.UTF-8 \
			--setenv PATH /review/sandbox-bin:/home/me/.local/bin:/home/me/.npm-global/bin:/usr/bin:/bin \
			--setenv TERM xterm-256color \
			--setenv USER me \
			--symlink usr/bin /bin \
			--symlink usr/lib /lib \
			--symlink usr/lib64 /lib64 \
			--symlink usr/sbin /sbin \
			--tmpfs /run \
			--tmpfs /tmp \
			--ro-bind $(readlink --canonicalize /etc/resolv.conf) $(readlink --canonicalize /etc/resolv.conf) \
			--unshare-cgroup \
			--unshare-ipc \
			--unshare-pid \
			--unshare-uts \
			"$@"
}

function _update_points {
	local delta=${1}
	local usernames=${2}

	for username in ${usernames}
	do
		local current_points=$(grep "^${username}=" points.properties 2> /dev/null | cut --delimiter== --fields=2)

		if [[ -z ${current_points} ]]
		then
			current_points=80
		fi

		local new_points=$((current_points + delta))

		if [[ ${new_points} -lt 0 ]]
		then
			new_points=0
		elif [[ ${new_points} -gt 100 ]]
		then
			new_points=100
		fi

		if grep --quiet "^${username}=" points.properties 2> /dev/null
		then
			sed --in-place "s/^${username}=.*/${username}=${new_points}/" points.properties
		else
			echo "${username}=${new_points}" >> points.properties
		fi
	done

	sort --output points.properties points.properties

	truncate --size=-1 points.properties
}

function _write_model_json_file {
	local model=${1}

	local prompt='Use `git grep --cached <pattern>` inside /review/liferay-portal to verify identifiers and conventions. Always pass --cached: plain `git grep` hangs the VM (it is auto rewritten by a wrapper, but do not rely on that — pass --cached yourself).

Output ONLY valid JSON: {"chance": <0-100>, "violations": ["brief description of each rule broken (append `verify against <source>` if uncertain)"]} where chance is your confidence that Brian Chan would close this PR for these violations.'
	local response
	local seconds=$(date +%s)

	if [[ ${model} == sonnet-4.6 ]]
	then
		response=$(_review_in_sandbox \
			env \
				HTTPS_PROXY=localhost:8118 \
				HTTP_PROXY=localhost:8118 \
				\
				claude \
					--add-dir /review \
					--dangerously-skip-permissions \
					--model sonnet \
					--output-format json \
					--print "Read the PR diff at /review/pr.diff, every rule file under /review/rules, and the style guide /review/STYLE.md, then review the diff against every rule. ${prompt}" \
			| jq --raw-output ".result" \
			| sed '/^```/d')
	else
		response=$(_review_in_sandbox \
			opencode run \
				--dangerously-skip-permissions \
				--file /review/STYLE.md \
				--file /review/pr.diff \
				--file /review/rules \
				--format json \
				--model "opencode-go/${model}" \
				"Review this PR diff against every attached rule. ${prompt}" \
			| jq --raw-output --slurp "map(select(.type == \"text\")) | last | .part.text" \
			| sed '/^```/d')
	fi

	local model_json=$(echo "${response}" | grep --null-data --only-matching --perl-regexp "(?s)\{.*\}" | tr --delete "\0")

	if model_json=$(echo "${model_json}" | jq --argjson seconds "$(($(date +%s) - seconds))" --slurp "(.[-1] // empty) | {chance: (.chance // 0), seconds: \$seconds, violations: (.violations // [])}" 2> /dev/null) && [[ -n ${model_json} ]]
	then
		echo "${model_json}" > "/tmp/pr-${pr_number}-${model}.json"
	else
		jq --null-input --arg error "${response}" --argjson seconds "$(($(date +%s) - seconds))" "{chance: 0, error: \$error, seconds: \$seconds, violations: []}" > "/tmp/pr-${pr_number}-${model}.json"
	fi
}

_IGNORED_SUFFIXES="js macro path scss snap testcase ts tsx"
_MODELS=(deepseek-v4-pro kimi-k2.6 sonnet-4.6)
_REPO=brianchandotcom/liferay-portal

main "${@}"