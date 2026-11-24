#!/bin/bash
# 対象リポジトリにファイルを足さずに使う場合の動作を確かめる。
# 設定をリポジトリの外に置くこと、状態の置き場を .gitignore なしで無視させること、
# テストが変更を検出するかを承認の時点で記録すること、手元でマージの可否を判定することが対象である。
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 実装の前は落ち、src/feature.js を足すと通る検査にする。
CONFIG='{
  "base": "main",
  "checks": { "verify": ["test -f src/feature.js"] },
  "paths": { "tests": ["tests/*"], "no_spec": ["docs/*"] }
}'

# 設定をコミットしていないリポジトリを作る。
new_repo_without_config() {
  REPO="$(mktemp -d "$WORK_ROOT/repo.XXXXXX")"
  cd "$REPO" || exit 1
  git init -q -b main
  mkdir -p src tests
  echo "export const add = (a, b) => a + b" >src/add.js
  echo "test('add', () => {})" >tests/add.test.js
  git add -A
  git commit -q -m init
  git switch -q -c work
}

save_config() {
  printf '%s\n' "$1" | "$SCRIPTS/config.sh" set >/dev/null
}

edit_input() {
  jq -n --arg path "$1" --arg cwd "${2:-$REPO}" '{tool_name: "Edit", tool_input: {file_path: $path}, cwd: $cwd}'
}

expect_ask() {
  expect_status 0
  [ "$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "ask" ] ||
    fail "利用者への確認を期待した。出力: $OUTPUT"
}

expect_clean_worktree() {
  local status
  status="$(git status --porcelain)"
  [ -z "$status" ] || fail "作業ツリーに変更が残っている: $status"
}

# ---- config.sh

it "設定を保存しても、対象リポジトリの作業ツリーは変わらない"
new_repo_without_config
run "$SCRIPTS/config.sh" set <<EOF
$CONFIG
EOF
expect_status 0
expect_clean_worktree
run "$SCRIPTS/config.sh" show
expect_status 0
expect_output_contains "test -f src/feature.js"

it "設定がないリポジトリでは、show が終了コード 1 を返す"
new_repo_without_config
run "$SCRIPTS/config.sh" show
expect_status 1

it "検査のコマンドがない設定は保存しない"
new_repo_without_config
run "$SCRIPTS/config.sh" set <<EOF
{"checks": {"verify": []}}
EOF
expect_status 2
run "$SCRIPTS/config.sh" show
expect_status 1

it "JSON として読めない設定は保存しない"
new_repo_without_config
run "$SCRIPTS/config.sh" set <<EOF
{"checks":
EOF
expect_status 2

it "リポジトリに設定がコミットされていれば、外への保存を受け付けない"
new_repo "$CONFIG"
run "$SCRIPTS/config.sh" set <<EOF
{"checks": {"verify": ["true"]}}
EOF
expect_status 2
run "$SCRIPTS/config.sh" show
expect_output_contains "test -f src/feature.js"

it "worktree からも、同じ設定が使われる"
new_repo_without_config
save_config "$CONFIG"
git worktree add -q -b other "$WORK_ROOT/wt.$$" main
cd "$WORK_ROOT/wt.$$" || exit 1
run "$SCRIPTS/config.sh" show
expect_status 0
expect_output_contains "test -f src/feature.js"
cd "$REPO" || exit 1
git worktree remove --force "$WORK_ROOT/wt.$$"

# ---- runbook.sh

it "動作確認の手引きを保存しても、対象リポジトリの作業ツリーは変わらない"
new_repo_without_config
run "$SCRIPTS/runbook.sh" set <<EOF
起動: make dev
EOF
expect_status 0
expect_clean_worktree
run "$SCRIPTS/runbook.sh" show
expect_status 0
expect_output_contains "make dev"

it "手引きがないリポジトリでは、show が終了コード 1 を返す"
new_repo_without_config
run "$SCRIPTS/runbook.sh" show
expect_status 1
expect_output_empty

it "空の手引きは保存しない"
new_repo_without_config
run "$SCRIPTS/runbook.sh" set <<EOF

EOF
expect_status 2
run "$SCRIPTS/runbook.sh" show
expect_status 1

it "worktree からも、同じ手引きが読める"
new_repo_without_config
echo "起動: make dev" | "$SCRIPTS/runbook.sh" set >/dev/null
git worktree add -q -b other "$WORK_ROOT/wt-runbook.$$" main
cd "$WORK_ROOT/wt-runbook.$$" || exit 1
run "$SCRIPTS/runbook.sh" show
expect_status 0
expect_output_contains "make dev"
cd "$REPO" || exit 1
git worktree remove --force "$WORK_ROOT/wt-runbook.$$"

it "手引きの編集は、検査の設定と違って確認なしで通す"
new_repo_without_config
save_config "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$("$SCRIPTS/runbook.sh" path)")"
expect_status 0
expect_output_empty

# ---- hook

it "設定がどこにもないリポジトリでは、Stop hook は何もしない"
new_repo_without_config
echo "change" >>src/add.js
run_hook stop.sh "$(stop_input)"
expect_status 0
expect_output_empty

it "リポジトリの外の設定だけでも、Stop hook が検査を実行して止める"
new_repo_without_config
save_config "$CONFIG"
echo "change" >>src/add.js
run_hook stop.sh "$(stop_input)"
expect_status 2
expect_output_contains "test -f src/feature.js"

it "リポジトリの外の設定の編集は、利用者に確認する"
new_repo_without_config
save_config "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$("$SCRIPTS/config.sh" path)")"
expect_ask

it "リポジトリの外の設定の新規作成も、利用者に確認する"
new_repo_without_config
run_hook pre-edit.sh "$(edit_input "$REPO/.git/merge-gate/config.json")"
expect_ask

it "worktree からの、リポジトリの外の設定の編集も、利用者に確認する"
new_repo_without_config
save_config "$CONFIG"
config_path="$("$SCRIPTS/config.sh" path)"
git worktree add -q -b other "$WORK_ROOT/wt-edit.$$" main
run_hook pre-edit.sh "$(edit_input "$config_path" "$WORK_ROOT/wt-edit.$$")"
expect_ask
git worktree remove --force "$WORK_ROOT/wt-edit.$$"

it "設定があるリポジトリでは、SessionStart hook が仕様の承認から始めるよう伝える"
new_repo_without_config
save_config "$CONFIG"
run_hook session-start.sh "$(jq -n --arg cwd "$REPO" '{cwd: $cwd}')"
expect_status 0
expect_output_contains "acceptance-first"

it "設定がないリポジトリでは、SessionStart hook は何も出力しない"
new_repo_without_config
run_hook session-start.sh "$(jq -n --arg cwd "$REPO" '{cwd: $cwd}')"
expect_status 0
expect_output_empty

# ---- 状態の置き場を git の管理から外す

it "承認を記録すると、状態の置き場が .gitignore なしで無視される"
new_repo_without_config
save_config "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
[ -d .merge-gate ] || fail "状態の置き場が作られていない"
expect_clean_worktree
[ ! -f .gitignore ] || fail ".gitignore が作られている"

it "無視の登録は、繰り返しても 1 行だけである"
new_repo_without_config
save_config "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
run_hook stop.sh "$(stop_input)"
run_hook session-start.sh "$(jq -n --arg cwd "$REPO" '{cwd: $cwd}')"
count="$(grep -cxF -- ".merge-gate/" .git/info/exclude)"
[ "$count" -eq 1 ] || fail "登録が $count 行ある"

it "無視の登録は、改行で終わっていない既存の行を壊さない"
new_repo_without_config
mkdir -p .git/info
printf 'local-notes.txt' >.git/info/exclude
save_config "$CONFIG"
grep -qxF -- "local-notes.txt" .git/info/exclude || fail "既存の行が変わっている: $(cat .git/info/exclude)"
grep -qxF -- ".merge-gate/" .git/info/exclude || fail "登録されていない: $(cat .git/info/exclude)"

# ---- 承認の時点で、テストが変更を検出するかを記録する

it "実装の前に検査が落ちれば、検出したと記録する"
new_repo "$CONFIG"
echo "test('feature', () => {})" >tests/feature.test.js
run "$SCRIPTS/lock.sh" add tests/feature.test.js
expect_status 0
[ "$(sed -n 1p .merge-gate/red)" = "detected" ] || fail "記録: $(cat .merge-gate/red 2>&1)"

it "実装の前に検査がすべて通れば、検出していないと記録して知らせる"
new_repo '{"base": "main", "checks": {"verify": ["true"]}, "paths": {"tests": ["tests/*"]}}'
echo "test('feature', () => {})" >tests/feature.test.js
run "$SCRIPTS/lock.sh" add tests/feature.test.js
expect_status 0
expect_output_contains "検査がすべて通った"
[ "$(sed -n 1p .merge-gate/red)" = "undetected" ] || fail "記録: $(cat .merge-gate/red 2>&1)"

it "確認が設定で無効にされていれば、無効と記録する"
new_repo '{"base": "main", "checks": {"verify": ["true"], "red": false}, "paths": {"tests": ["tests/*"]}}'
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
[ "$(sed -n 1p .merge-gate/red)" = "disabled" ] || fail "記録: $(cat .merge-gate/red 2>&1)"

it "実装のあとで記録し直しても、承認の時点の結果を保つ"
new_repo "$CONFIG"
echo "test('feature', () => {})" >tests/feature.test.js
"$SCRIPTS/lock.sh" add tests/feature.test.js >/dev/null
echo "export const feature = 1" >src/feature.js
"$SCRIPTS/lock.sh" add tests/feature.test.js >/dev/null
[ "$(sed -n 1p .merge-gate/red)" = "detected" ] || fail "記録: $(cat .merge-gate/red 2>&1)"

it "承認の記録を消すと、検出の記録も消える"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
"$SCRIPTS/lock.sh" clear
[ ! -f .merge-gate/red ] || fail "記録が残っている"

it "別のブランチで取った検出の記録は、引き継がない"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
echo "export const feature = 1" >src/feature.js
commit_all
git switch -q -c next
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
[ "$(sed -n 1p .merge-gate/red)" = "undetected" ] || fail "記録: $(cat .merge-gate/red 2>&1)"

# ---- gate.sh

it "承認の時点で落ち、確認に回す変更がなければ、diff を読まずにマージしてよいと判定する"
new_repo "$CONFIG"
echo "test('feature', () => {})" >tests/feature.test.js
"$SCRIPTS/lock.sh" add tests/feature.test.js >/dev/null
echo "export const feature = 1" >src/feature.js
commit_all
run "$SCRIPTS/checks/gate.sh"
expect_status 0
expect_output_contains "理由は見つからなかった"
expect_output_contains "test -f src/feature.js"

it "承認の記録がない変更は、人間の確認に回す"
new_repo "$CONFIG"
echo "export const feature = 1" >src/feature.js
commit_all
run "$SCRIPTS/checks/gate.sh"
expect_status 3
expect_output_contains "承認の記録が、このブランチにない"

it "実装の前に検査が通っていた変更は、人間の確認に回す"
new_repo '{"base": "main", "checks": {"verify": ["true"]}, "paths": {"tests": ["tests/*"]}}'
echo "test('feature', () => {})" >tests/feature.test.js
"$SCRIPTS/lock.sh" add tests/feature.test.js >/dev/null
echo "export const feature = 1" >src/feature.js
commit_all
run "$SCRIPTS/checks/gate.sh"
expect_status 3
expect_output_contains "この変更を検出するテストがない"

it "既存のテストの変更は、理由として報告する"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null 2>&1
echo "test('add', () => { /* 緩めた */ })" >tests/add.test.js
echo "export const feature = 1" >src/feature.js
commit_all
run "$SCRIPTS/checks/gate.sh"
expect_status 3
expect_output_contains "既存のテストを変更している: tests/add.test.js"

it "仕様を要しないパスだけの変更は、承認の記録がなくても確認に回さない"
new_repo "$CONFIG"
mkdir -p docs
echo "説明" >docs/guide.md
commit_all
run "$SCRIPTS/checks/gate.sh"
expect_status 0

it "秘密の値が追加されていれば、マージしてはいけないと判定する"
new_repo "$CONFIG"
echo "test('feature', () => {})" >tests/feature.test.js
"$SCRIPTS/lock.sh" add tests/feature.test.js >/dev/null
# 検査に掛かる形の文字列を、このテストのファイル自体には書かないよう、分けて組み立てる
printf 'export const feature = "%s%s"\n' "AKIA" "ABCDEFGHIJKLMNOP" >src/feature.js
commit_all
run "$SCRIPTS/checks/gate.sh"
expect_status 1
expect_output_contains "マージしてはいけない"

it "リポジトリの外の設定を使ったときは、レビューを通っていない設定であることを報告する"
new_repo_without_config
save_config "$CONFIG"
echo "test('feature', () => {})" >tests/feature.test.js
"$SCRIPTS/lock.sh" add tests/feature.test.js >/dev/null
echo "export const feature = 1" >src/feature.js
commit_all
run "$SCRIPTS/checks/gate.sh"
expect_status 0
expect_output_contains "PR のレビューを通っていない"

finish
