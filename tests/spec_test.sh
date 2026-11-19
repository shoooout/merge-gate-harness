#!/bin/bash
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIG='{
  "base": "main",
  "checks": { "verify": ["true"] },
  "paths": { "tests": ["tests/*"] }
}'

SPEC='## 要件
注文一覧に、キャンセル済みの注文を除外する絞り込みを追加する。

## 受け入れ条件
- 除外を指定すると、キャンセル済みの注文が一覧に含まれない
  - テスト: `除外を指定するとキャンセル済みを含まない`
- 指定がなければ、すべての注文を返す
  - テスト: `指定がなければすべての注文を返す`

## 異常系と境界値
- 該当する注文が 0 件のとき、空の一覧を返す
  - テスト: `該当が 0 件なら空の一覧を返す`

## 対象外
並べ替えの変更

## 採らなかった案
- 絞り込みを画面の側だけで行う案。件数の表示が実際の件数とずれるため採らなかった。

## 依頼と食い違う点
なし。依頼が挙げる cancelled の状態が実在することを `src/order.js:12` で確かめた。

## 確認できていない前提
なし

## 変更する既存テスト
なし'

# SPEC の各条件に書いたテストの名前
T1='除外を指定するとキャンセル済みを含まない'
T2='指定がなければすべての注文を返す'
T3='該当が 0 件なら空の一覧を返す'

write_spec() {
  mkdir -p .merge-gate
  printf '%s\n' "$1" >.merge-gate/spec.md
}

write_tests() {
  : >tests/filter.test.js
  for name in "$@"; do
    echo "test('$name', () => { expect(true).toBe(true) })" >>tests/filter.test.js
  done
}

# ---- 節の有無

it "必要な節と、条件に対応するテストが揃っていれば成功する"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1" "$T2" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0
expect_output_empty

it "節が欠けていれば、欠けている節の名前を出して失敗する"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed '/^## 依頼と食い違う点/,/^$/d')"
write_tests "$T1" "$T2" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "「依頼と食い違う点」"

it "採らなかった案の節が欠けていれば失敗する"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed '/^## 採らなかった案/,/^$/d')"
write_tests "$T1" "$T2" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "「採らなかった案」"

it "見出しだけで中身が空の節は、書かれていないものとして扱う"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed 's/^並べ替えの変更$//')"
write_tests "$T1" "$T2" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "「対象外」"

# ---- 受け入れ条件とテストの対応

it "仕様に書いたテストが追加されていなければ、条件とテストの名前を出して失敗する"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "条件「指定がなければ、すべての注文を返す」のテスト「${T2}」が、このブランチで追加したテストにない"

it "異常系の節に書いた条件にも、対応するテストを求める"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1" "$T2"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "テスト「${T3}」が、このブランチで追加したテストにない"

it "テストの名前が書かれていない条件があれば、その条件を出して失敗する"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | grep -v -F "$T2")"
write_tests "$T1" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "条件「指定がなければ、すべての注文を返す」に対応するテストが書かれていない"

it "1 つの条件に書いた複数のテストは、すべて追加されていることを求める"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed "s/^  - テスト: \`$T1\`\$/&\\
  - テスト: \`除外の指定は大文字と小文字を区別しない\`/")"
write_tests "$T1" "$T2" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "テスト「除外の指定は大文字と小文字を区別しない」が、このブランチで追加したテストにない"

it "受け入れ条件が箇条書きでなければ失敗する"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed -e 's/^- \(除外を指定\)/\1/' -e 's/^- \(指定がなければ\)/\1/')"
write_tests "$T1" "$T2" "$T3"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "受け入れ条件が箇条書きになっていない"

it "異常系と境界値に箇条書きの条件がなくても、受け入れ条件が揃っていれば成功する"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | grep -v -F "$T3" | sed 's/^- 該当する注文が 0 件.*$/なし。絞り込みは件数によって分岐しないことをコードで確かめた。/')"
write_tests "$T1" "$T2"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0

it "分岐元のテストにすでにある同じ名前は、今回の条件に対応するテストとして数えない"
new_repo "$CONFIG"
git switch -q main
printf "test('%s', () => {})\n" "$T1" "$T2" "$T3" >>tests/add.test.js
commit_all "以前の変更"
git switch -q work
git merge -q main
write_spec "$SPEC"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "テスト「${T1}」が、このブランチで追加したテストにない"

it "コミット済みのテストも、このブランチで追加したものなら対応するテストとして数える"
new_repo "$CONFIG"
write_tests "$T1" "$T2" "$T3"
commit_all
write_spec "$SPEC"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0

# ---- 既存テストの変更

it "承認時に挙げていない既存テストを変更していれば失敗する"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1" "$T2" "$T3"
echo "// 期待値を変えた" >>tests/add.test.js
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "既存のテスト tests/add.test.js を変更しているが"

it "承認時に挙げた既存テストの変更は通す"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed '$d')
- tests/add.test.js: 加算の結果の丸め方が変わるため"
write_tests "$T1" "$T2" "$T3"
echo "// 期待値を変えた" >>tests/add.test.js
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0

it "承認時に挙げていない既存テストの削除も失敗にする"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1" "$T2" "$T3"
git rm -q tests/add.test.js
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "既存のテスト tests/add.test.js を変更しているが"

# ---- PR の本文

it "見出しの階層が違う PR の本文でも検査できる"
new_repo "$CONFIG"
write_tests "$T1" "$T2" "$T3"
commit_all
body="## 仕様
$(printf '%s\n' "$SPEC" | sed 's/^## /### /')

## 動作確認の手順
1. 一覧を開く"
printf '%s\n' "$body" >"$WORK_ROOT/body.md"
run "$SCRIPTS/checks/spec.sh" "$WORK_ROOT/body.md"
expect_status 0

it "PR の本文で仕様を折りたたんでいても、仕様として読む"
new_repo "$CONFIG"
write_tests "$T1" "$T2" "$T3"
commit_all
folded_body() {
  printf '%s\n' "## 要点" "- 絞り込みを追加した" "" "## 仕様" "<details>" "<summary>承認済みの仕様の全文</summary>" ""
  printf '%s\n' "$1" | sed 's/^## /### /'
  printf '%s\n' "" "</details>" "" "## 動作確認の手順" "1. 一覧を開く"
}
folded_body "$SPEC" >"$WORK_ROOT/body.md"
run "$SCRIPTS/checks/spec.sh" "$WORK_ROOT/body.md"
expect_status 0
expect_output_empty

it "折りたたみの閉じタグだけが残った節は、書かれていないものとして扱う"
new_repo "$CONFIG"
write_tests "$T1" "$T2" "$T3"
commit_all
folded_body "$(printf '%s\n' "$SPEC" | sed '$d')" >"$WORK_ROOT/body.md"
run "$SCRIPTS/checks/spec.sh" "$WORK_ROOT/body.md"
expect_status 1
expect_output_contains "「変更する既存テスト」"

it "コードブロックの中のコメント行を、節の区切りとして扱わない"
new_repo "$CONFIG"
write_tests "$T1" "$T2" "$T3"
write_spec "$(printf '%s\n' "$SPEC" | sed '$d')"'
```bash
# 影響を受けるテストはない
```'
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0

it "仕様のない PR の本文は失敗する"
new_repo "$CONFIG"
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
printf '%s\n' "## 動作確認の手順" "1. 一覧を開く" >"$WORK_ROOT/body.md"
run "$SCRIPTS/checks/spec.sh" "$WORK_ROOT/body.md"
expect_status 1
expect_output_contains "「受け入れ条件」"

# ---- 仕様を要しない変更

NO_SPEC_CONFIG='{
  "base": "main",
  "checks": { "verify": ["true"] },
  "paths": { "tests": ["tests/*"], "no_spec": ["*.md", "docs/*"] }
}'

it "仕様を要しないと決めたパスだけの変更は、仕様がなくても通す"
new_repo "$NO_SPEC_CONFIG"
echo "# 説明" >README.md
commit_all
: >"$WORK_ROOT/empty.md"
run "$SCRIPTS/checks/spec.sh" "$WORK_ROOT/empty.md"
expect_status 0

it "仕様を要しないパスとそれ以外を両方変更していれば、仕様を求める"
new_repo "$NO_SPEC_CONFIG"
echo "# 説明" >README.md
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
: >"$WORK_ROOT/empty.md"
run "$SCRIPTS/checks/spec.sh" "$WORK_ROOT/empty.md"
expect_status 1

# ---- 承認の記録との連携

it "形の整っていない仕様は、承認済みとして記録できない"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1"
run "$SCRIPTS/lock.sh" add .merge-gate/spec.md tests/filter.test.js
expect_status 2
expect_output_contains "テスト「${T2}」が、このブランチで追加したテストにない"
run "$SCRIPTS/lock.sh" list
expect_output_empty

it "形の整った仕様は、テストと合わせて記録できる"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1" "$T2" "$T3"
run "$SCRIPTS/lock.sh" add .merge-gate/spec.md tests/filter.test.js
expect_status 0
run "$SCRIPTS/lock.sh" list
expect_output_contains ".merge-gate/spec.md"

it "承認後に、挙げていない既存テストを変更したら、作業を終了させない"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests "$T1" "$T2" "$T3"
"$SCRIPTS/lock.sh" add .merge-gate/spec.md tests/filter.test.js >/dev/null
echo "// 期待値を変えた" >>tests/add.test.js
run_hook stop.sh "$(stop_input)"
expect_status 2
expect_output_contains "既存のテスト tests/add.test.js を変更しているが"

finish
