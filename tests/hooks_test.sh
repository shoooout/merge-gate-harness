#!/bin/bash
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG='{
  "base": "main",
  "checks": {
    "verify": ["test ! -f BROKEN"],
    "on_edit": [
      { "pattern": "*.js", "command": "sh -c '"'"'! grep -q FIXME \"$1\"'"'"' _" }
    ]
  },
  "paths": {
    "tests": ["tests/*"],
    "dependencies": ["package.json"]
  }
}'

edit_input() {
  jq -n --arg path "$1" --arg cwd "$REPO" '{tool_name: "Edit", tool_input: {file_path: $path}, cwd: $cwd}'
}

expect_ask() {
  expect_status 0
  [ "$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "ask" ] ||
    fail "利用者への確認を期待した。出力: $OUTPUT"
}

expect_pass_through() {
  expect_status 0
  expect_output_empty
}

# ---- pre-edit.sh

it "実装ファイルの編集は確認なしで通す"
new_repo "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$REPO/src/add.js")"
expect_pass_through

it "分岐元にあるテストの編集は利用者に確認する"
new_repo "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$REPO/tests/add.test.js")"
expect_ask

it "このブランチで新しく書くテストは確認なしで通す"
new_repo "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$REPO/tests/new.test.js")"
expect_pass_through

it "このブランチでコミットしたテストも、分岐元になければ確認なしで通す"
new_repo "$CONFIG"
echo "test('new', () => {})" >tests/new.test.js
commit_all
run_hook pre-edit.sh "$(edit_input "$REPO/tests/new.test.js")"
expect_pass_through

it "承認済みとして記録したファイルの編集は利用者に確認する"
new_repo "$CONFIG"
echo "test('new', () => {})" >tests/new.test.js
"$SCRIPTS/lock.sh" add tests/new.test.js >/dev/null
run_hook pre-edit.sh "$(edit_input "$REPO/tests/new.test.js")"
expect_ask

it "別のブランチで承認済みとして記録したファイルの編集は、確認なしで通す"
new_repo "$CONFIG"
echo "test('new', () => {})" >tests/new.test.js
"$SCRIPTS/lock.sh" add tests/new.test.js >/dev/null
git switch -q -c next
run_hook pre-edit.sh "$(edit_input "$REPO/tests/new.test.js")"
expect_pass_through

it "ゲートの設定ファイルの編集は利用者に確認する"
new_repo "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$REPO/.merge-gate.json")"
expect_ask

it "承認の記録そのものの編集は利用者に確認する"
new_repo "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$REPO/.merge-gate/locked")"
expect_ask

it "CI の定義の新規作成は利用者に確認する"
new_repo "$CONFIG"
mkdir -p .github/workflows
run_hook pre-edit.sh "$(edit_input "$REPO/.github/workflows/ci.yml")"
expect_ask

it "依存の定義の編集は利用者に確認する"
new_repo "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$REPO/package.json")"
expect_ask

it "設定ファイルのないリポジトリでは何もしない"
new_repo "$CONFIG"
rm .merge-gate.json
run_hook pre-edit.sh "$(edit_input "$REPO/tests/add.test.js")"
expect_pass_through

it "リポジトリの外のファイルの編集には関与しない"
new_repo "$CONFIG"
run_hook pre-edit.sh "$(edit_input "$WORK_ROOT/outside.json")"
expect_pass_through

# ---- post-edit.sh

it "編集後の検査が通れば何も返さない"
new_repo "$CONFIG"
run_hook post-edit.sh "$(edit_input "$REPO/src/add.js")"
expect_pass_through

it "編集後の検査が失敗したら、エージェントに返すために終了コード 2 で止める"
new_repo "$CONFIG"
echo "// FIXME" >>src/add.js
run_hook post-edit.sh "$(edit_input "$REPO/src/add.js")"
expect_status 2
expect_output_contains "src/add.js"

it "パターンに一致しないファイルには検査を実行しない"
new_repo "$CONFIG"
echo "FIXME" >notes.md
run_hook post-edit.sh "$(edit_input "$REPO/notes.md")"
expect_pass_through

it "空白を含むファイル名でも検査できる"
new_repo "$CONFIG"
echo "// FIXME" >"src/with space.js"
run_hook post-edit.sh "$(edit_input "$REPO/src/with space.js")"
expect_status 2

# ---- stop.sh

it "分岐元から何も変えていなければ、検査せずに終了を許す"
new_repo '{"base": "main", "checks": {"verify": ["false"]}}'
run_hook stop.sh "$(stop_input)"
expect_pass_through

it "変更があり検査が通れば終了を許す"
new_repo "$CONFIG"
echo "export const sub = (a, b) => a - b" >src/sub.js
run_hook stop.sh "$(stop_input)"
expect_pass_through

it "変更があり検査が失敗していれば終了させない"
new_repo "$CONFIG"
touch BROKEN
run_hook stop.sh "$(stop_input)"
expect_status 2
expect_output_contains "失敗: test ! -f BROKEN"

it "止められたあとに直せば終了を許す"
new_repo "$CONFIG"
touch BROKEN
run_hook stop.sh "$(stop_input)"
rm BROKEN
echo "export const sub = (a, b) => a - b" >src/sub.js
run_hook stop.sh "$(stop_input true)"
expect_pass_through

it "止められたあとに別の変更をしても、失敗が残っていれば再び止める"
new_repo "$CONFIG"
touch BROKEN
run_hook stop.sh "$(stop_input)"
echo "export const sub = (a, b) => a - b" >src/sub.js
run_hook stop.sh "$(stop_input true)"
expect_status 2

it "止められたあと何も変えずに再び止まろうとしたら、繰り返しを避けて終了を許す"
new_repo "$CONFIG"
touch BROKEN
run_hook stop.sh "$(stop_input)"
run_hook stop.sh "$(stop_input true)"
expect_pass_through

it "新しい会話で同じ失敗のまま終わろうとしたら、再び止める"
new_repo "$CONFIG"
touch BROKEN
run_hook stop.sh "$(stop_input)"
run_hook stop.sh "$(stop_input false)"
expect_status 2

it "承認済みのファイルが書き換えられていれば終了させない"
new_repo "$CONFIG"
echo "test('new', () => {})" >tests/new.test.js
"$SCRIPTS/lock.sh" add tests/new.test.js >/dev/null
echo "// 緩めた" >>tests/new.test.js
run_hook stop.sh "$(stop_input)"
expect_status 2
expect_output_contains "承認後に変更されている: tests/new.test.js"

it "検査が設定されていなければ、止め続けずに利用者へ知らせる"
new_repo '{"base": "main", "checks": {"verify": []}}'
echo "export const sub = (a, b) => a - b" >src/sub.js
run_hook stop.sh "$(stop_input)"
expect_status 1
expect_output_contains "checks.verify が空"

it "設定ファイルのないリポジトリでは何もしない"
new_repo "$CONFIG"
rm .merge-gate.json
touch BROKEN
run_hook stop.sh "$(stop_input)"
expect_pass_through

finish
