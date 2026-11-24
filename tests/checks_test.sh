#!/bin/bash
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG='{
  "base": "main",
  "checks": { "verify": ["true"] },
  "paths": {
    "tests": ["tests/*", "*.test.js"],
    "dependencies": ["package.json"],
    "human_review": ["src/auth/*"]
  },
  "skip_markers": ["\\.skip\\(", "(^|[^A-Za-z])xit\\("],
  "limits": { "max_changed_lines": 20 }
}'

# ---- classify.sh

it "実装だけの小さな変更は自動マージしてよいと判定する"
new_repo "$CONFIG"
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 0
expect_output_empty

it "コミット前の作業ツリーの変更も判定の対象にする"
new_repo "$CONFIG"
echo "// 変更" >>tests/add.test.js
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "既存のテストを変更している: tests/add.test.js"

it "既存のテストの削除を人間に回す"
new_repo "$CONFIG"
git rm -q tests/add.test.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "既存のテストを削除している: tests/add.test.js"

it "既存のテストを別名に移して書き換えても、元のテストの削除として検知する"
new_repo "$CONFIG"
git mv tests/add.test.js tests/renamed.test.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "既存のテストを削除している: tests/add.test.js"

it "テストの追加だけなら自動マージしてよいと判定する"
new_repo "$CONFIG"
echo "test('sub', () => {})" >tests/sub.test.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 0

it "新規のテストでも skip の記述があれば人間に回す"
new_repo "$CONFIG"
echo "test.skip('sub', () => {})" >tests/sub.test.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "テストを skip する記述を追加している: tests/sub.test.js"

it "skip の印を名前の一部に含むだけの記述は、skip として扱わない"
new_repo "$CONFIG"
echo "test('sub', () => { process.exit(0) })" >tests/sub.test.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 0

it "行頭の skip の印を検知する"
new_repo "$CONFIG"
echo "xit('sub', () => {})" >tests/sub.test.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "テストを skip する記述を追加している: tests/sub.test.js"

it "依存の定義の変更を人間に回す"
new_repo "$CONFIG"
echo '{}' >package.json
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "依存の定義を変更している: package.json"

it "人間が確認すると決めたパスの変更を人間に回す"
new_repo "$CONFIG"
mkdir -p src/auth
echo "export const login = () => {}" >src/auth/login.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "人間が確認すると決めたパスを変更している: src/auth/login.js"

it "設定に書いていなくても、ゲートの設定ファイルの変更を人間に回す"
new_repo "$CONFIG"
echo '{"base": "main", "checks": {"verify": ["true"]}}' >.merge-gate.json
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "ゲートの定義を変更している: .merge-gate.json"

it "設定に書いていなくても、CI の定義の変更を人間に回す"
new_repo "$CONFIG"
mkdir -p .github/workflows
echo "name: ci" >.github/workflows/ci.yml
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "ゲートの定義を変更している: .github/workflows/ci.yml"

it "非 ASCII の名前の既存テストの変更を人間に回す"
new_repo "$CONFIG"
git switch -q main
echo "test('注文', () => {})" >"tests/注文.test.js"
commit_all "既存のテスト"
git switch -q work
git merge -q main
echo "// 期待値を変えた" >>"tests/注文.test.js"
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "既存のテストを変更している: tests/注文.test.js"

it "非 ASCII の名前のテストに skip の記述があれば人間に回す"
new_repo "$CONFIG"
echo "test.skip('注文', () => {})" >"tests/注文.test.js"
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "テストを skip する記述を追加している: tests/注文.test.js"

it "非 ASCII の名前のゲートの定義の変更を人間に回す"
new_repo "$CONFIG"
mkdir -p .github/workflows
echo "name: ci" >".github/workflows/検査.yml"
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "ゲートの定義を変更している: .github/workflows/検査.yml"

it "非 ASCII の名前の、人間が確認すると決めたパスの変更を人間に回す"
new_repo "$CONFIG"
mkdir -p src/auth
echo "export const login = () => {}" >"src/auth/ログイン.js"
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "人間が確認すると決めたパスを変更している: src/auth/ログイン.js"

it "変更行数が上限を超えたら人間に回す"
new_repo "$CONFIG"
i=0
while [ "$i" -lt 30 ]; do
  echo "export const v$i = $i" >>src/many.js
  i=$((i + 1))
done
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "変更行数 30 が上限 20 を超えている"

it "base ブランチだけが進んでいても、このブランチの変更だけで判定する"
new_repo "$CONFIG"
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
git switch -q main
echo '{}' >package.json
commit_all "main だけの変更"
git switch -q work
run "$SCRIPTS/checks/classify.sh"
expect_status 0

it "設定ファイルがなければ、判定せずにエラーにする"
new_repo "$CONFIG"
rm .merge-gate.json
run "$SCRIPTS/checks/classify.sh"
expect_status 2

# ---- verify.sh

it "検査コマンドがすべて成功すれば成功する"
new_repo '{"checks": {"verify": ["true", "test -f src/add.js"]}}'
run "$SCRIPTS/checks/verify.sh"
expect_status 0

it "検査コマンドが 1 つでも失敗すれば、その出力を添えて失敗する"
new_repo '{"checks": {"verify": ["true", "echo 原因はこれ; false"]}}'
run "$SCRIPTS/checks/verify.sh"
expect_status 1
expect_output_contains "失敗: echo 原因はこれ; false"
expect_output_contains "原因はこれ"

it "失敗した検査の後ろにある検査も実行する"
new_repo '{"checks": {"verify": ["false", "echo 後ろの検査; false"]}}'
run "$SCRIPTS/checks/verify.sh"
expect_status 1
expect_output_contains "後ろの検査"

it "検査コマンドはリポジトリのルートで実行する"
new_repo '{"checks": {"verify": ["test -f .merge-gate.json"]}}'
cd src || exit 1
run "$SCRIPTS/checks/verify.sh"
expect_status 0

it "検査が 1 つも設定されていなければ、成功にせずエラーにする"
new_repo '{"checks": {"verify": []}}'
run "$SCRIPTS/checks/verify.sh"
expect_status 2

# ---- handoff.sh

it "必要な節がすべて書かれていれば成功する"
new_repo "$CONFIG"
body="## 動作確認の手順
1. 画面を開く

## 実行した確認
- 手順 1: 画面を開いた → 注文が 3 件表示された

## 影響範囲
注文一覧

## 独立した検証
- spec-auditor: 実行した。指摘 0 件
- security-reviewer: 実行できなかった。sub agent を起動できなかった

## 検証できなかったこと
なし"
run bash -c "printf '%s\n' \"\$1\" | \"\$2\"" _ "$body" "$SCRIPTS/checks/handoff.sh"
expect_status 0

it "節が欠けていれば、欠けている節の名前を出して失敗する"
new_repo "$CONFIG"
body="## 動作確認の手順
1. 画面を開く"
run bash -c "printf '%s\n' \"\$1\" | \"\$2\"" _ "$body" "$SCRIPTS/checks/handoff.sh"
expect_status 1
expect_output_contains "「影響範囲」"
expect_output_contains "「検証できなかったこと」"

it "エージェントが実行した確認の節がなければ失敗する"
new_repo "$CONFIG"
body="## 動作確認の手順
1. 画面を開く

## 影響範囲
注文一覧

## 独立した検証
- spec-auditor: 実行した。指摘 0 件

## 検証できなかったこと
なし"
run bash -c "printf '%s\n' \"\$1\" | \"\$2\"" _ "$body" "$SCRIPTS/checks/handoff.sh"
expect_status 1
expect_output_contains "「実行した確認」"

it "検証役の実行状況の節がなければ失敗する"
new_repo "$CONFIG"
body="## 動作確認の手順
1. 画面を開く

## 実行した確認
- 手順 1: 画面を開いた → 注文が 3 件表示された

## 影響範囲
注文一覧

## 検証できなかったこと
なし"
run bash -c "printf '%s\n' \"\$1\" | \"\$2\"" _ "$body" "$SCRIPTS/checks/handoff.sh"
expect_status 1
expect_output_contains "「独立した検証」"

it "見出しだけで中身が空の節は、書かれていないものとして扱う"
new_repo "$CONFIG"
body="## 動作確認の手順
<!-- ここに手順を書く -->

## 実行した確認
- 手順 1: 実行できなかった。環境がない

## 影響範囲
注文一覧

## 独立した検証
- spec-auditor: 実行した。指摘 0 件

## 検証できなかったこと
なし"
run bash -c "printf '%s\n' \"\$1\" | \"\$2\"" _ "$body" "$SCRIPTS/checks/handoff.sh"
expect_status 1
expect_output_contains "「動作確認の手順」"

it "必要な節を設定で差し替えられる"
new_repo '{"checks": {"verify": ["true"]}, "handoff_sections": ["確認方法"]}'
body="## 確認方法
画面を開く"
run bash -c "printf '%s\n' \"\$1\" | \"\$2\"" _ "$body" "$SCRIPTS/checks/handoff.sh"
expect_status 0

# ---- lock.sh

it "記録した直後は変更なしと判定する"
new_repo "$CONFIG"
run "$SCRIPTS/lock.sh" add tests/add.test.js
expect_status 0
run "$SCRIPTS/lock.sh" verify
expect_status 0

it "記録したファイルが書き換えられたら検知する"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
echo "// 緩めた" >>tests/add.test.js
run "$SCRIPTS/lock.sh" verify
expect_status 1
expect_output_contains "承認後に変更されている: tests/add.test.js"

it "記録したファイルが削除されたら検知する"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
rm tests/add.test.js
run "$SCRIPTS/lock.sh" verify
expect_status 1
expect_output_contains "削除されている: tests/add.test.js"

it "記録し直すと、新しい内容が承認済みになる"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
echo "// 承認を得た変更" >>tests/add.test.js
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
run "$SCRIPTS/lock.sh" verify
expect_status 0
run "$SCRIPTS/lock.sh" list
expect_output_contains "tests/add.test.js"
[ "$(printf '%s\n' "$OUTPUT" | wc -l | tr -d ' ')" = "1" ] || fail "同じファイルが重複して記録されている: $OUTPUT"

it "名前が前方一致するだけの別のファイルの記録を消さない"
new_repo "$CONFIG"
cp tests/add.test.js tests/add.test.js.bak
"$SCRIPTS/lock.sh" add tests/add.test.js.bak tests/add.test.js >/dev/null
run "$SCRIPTS/lock.sh" list
expect_output_contains "tests/add.test.js.bak"

it "別のブランチで取った記録は、無いものとして扱う"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
git switch -q -c next
echo "// 次の作業での変更" >>tests/add.test.js
run "$SCRIPTS/lock.sh" verify
expect_status 0
run "$SCRIPTS/lock.sh" list
expect_output_empty

it "元のブランチに戻れば、記録は消えずに有効なままである"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
git switch -q -c next
"$SCRIPTS/lock.sh" verify >/dev/null
git switch -q work
echo "// 緩めた" >>tests/add.test.js
run "$SCRIPTS/lock.sh" verify
expect_status 1
expect_output_contains "承認後に変更されている: tests/add.test.js"

it "別のブランチで記録を取ると、前のブランチの記録を捨てて新しく始める"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
git switch -q -c next
echo "test('next', () => {})" >tests/next.test.js
"$SCRIPTS/lock.sh" add tests/next.test.js >/dev/null
run "$SCRIPTS/lock.sh" list
[ "$OUTPUT" = "tests/next.test.js" ] || fail "前のブランチの記録が残っている: $OUTPUT"

it "clear で、現在のブランチの記録を消せる"
new_repo "$CONFIG"
"$SCRIPTS/lock.sh" add tests/add.test.js >/dev/null
"$SCRIPTS/lock.sh" clear
echo "// 別の依頼での変更" >>tests/add.test.js
run "$SCRIPTS/lock.sh" verify
expect_status 0

it "記録がなければ verify は成功する"
new_repo "$CONFIG"
run "$SCRIPTS/lock.sh" verify
expect_status 0

finish
