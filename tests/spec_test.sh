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
- AC-1: 除外を指定すると、キャンセル済みの注文が一覧に含まれない
- AC-2: 指定がなければ、すべての注文を返す

## 異常系と境界値
- AC-3: 該当する注文が 0 件のとき、空の一覧を返す

## 対象外
並べ替えの変更

## 依頼と食い違う点
なし。依頼が挙げる cancelled の状態が実在することをコードで確かめた。

## 確認できていない前提
なし

## 変更する既存テスト
なし'

write_spec() {
  mkdir -p .merge-gate
  printf '%s\n' "$1" >.merge-gate/spec.md
}

write_tests() {
  : >tests/filter.test.js
  for id in "$@"; do
    echo "test('$id 絞り込み', () => { expect(true).toBe(true) })" >>tests/filter.test.js
  done
}

# ---- 節の有無

it "必要な節と、条件に対応するテストが揃っていれば成功する"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-1 AC-2 AC-3
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0
expect_output_empty

it "節が欠けていれば、欠けている節の名前を出して失敗する"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed '/^## 依頼と食い違う点/,/^$/d')"
write_tests AC-1 AC-2 AC-3
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "「依頼と食い違う点」"

it "見出しだけで中身が空の節は、書かれていないものとして扱う"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed 's/^並べ替えの変更$//')"
write_tests AC-1 AC-2 AC-3
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "「対象外」"

# ---- 受け入れ条件とテストの対応

it "対応するテストがない条件があれば、その番号を出して失敗する"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-1 AC-3
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "AC-2 に対応するテストがない"

it "異常系の節に書いた条件にも、対応するテストを求める"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-1 AC-2
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "AC-3 に対応するテストがない"

it "番号が前方一致するだけのテストは、対応するテストとして数えない"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-10 AC-2 AC-3
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "AC-1 に対応するテストがない"

it "受け入れ条件に番号がなければ失敗する"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed 's/AC-[0-9]*: //')"
write_tests AC-1
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "番号が付いていない"

it "分岐元のテストに残っていた同じ番号は、今回の条件に対応するテストとして数えない"
new_repo "$CONFIG"
git switch -q main
echo "// AC-1 AC-2 AC-3 以前の変更で付けた番号" >>tests/add.test.js
commit_all "以前の変更"
git switch -q work
git merge -q main
write_spec "$SPEC"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "AC-1 に対応するテストがない"

it "コミット済みのテストに書いた番号も、対応するテストとして数える"
new_repo "$CONFIG"
write_tests AC-1 AC-2 AC-3
commit_all
write_spec "$SPEC"
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0

# ---- 既存テストの変更

it "承認時に挙げていない既存テストを変更していれば失敗する"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-1 AC-2 AC-3
echo "// 期待値を変えた" >>tests/add.test.js
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "既存のテスト tests/add.test.js を変更しているが"

it "承認時に挙げた既存テストの変更は通す"
new_repo "$CONFIG"
write_spec "$(printf '%s\n' "$SPEC" | sed '$d')
- tests/add.test.js: 加算の結果の丸め方が変わるため"
write_tests AC-1 AC-2 AC-3
echo "// 期待値を変えた" >>tests/add.test.js
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 0

it "承認時に挙げていない既存テストの削除も失敗にする"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-1 AC-2 AC-3
git rm -q tests/add.test.js
run "$SCRIPTS/checks/spec.sh" .merge-gate/spec.md
expect_status 1
expect_output_contains "既存のテスト tests/add.test.js を変更しているが"

# ---- PR の本文

it "見出しの階層が違う PR の本文でも検査できる"
new_repo "$CONFIG"
write_tests AC-1 AC-2 AC-3
commit_all
body="## 仕様
$(printf '%s\n' "$SPEC" | sed 's/^## /### /')

## 動作確認の手順
1. 一覧を開く"
printf '%s\n' "$body" >"$WORK_ROOT/body.md"
run "$SCRIPTS/checks/spec.sh" "$WORK_ROOT/body.md"
expect_status 0

it "コードブロックの中のコメント行を、節の区切りとして扱わない"
new_repo "$CONFIG"
write_tests AC-1 AC-2 AC-3
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
write_tests AC-1
run "$SCRIPTS/lock.sh" add .merge-gate/spec.md tests/filter.test.js
expect_status 2
expect_output_contains "AC-2 に対応するテストがない"
run "$SCRIPTS/lock.sh" list
expect_output_empty

it "形の整った仕様は、テストと合わせて記録できる"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-1 AC-2 AC-3
run "$SCRIPTS/lock.sh" add .merge-gate/spec.md tests/filter.test.js
expect_status 0
run "$SCRIPTS/lock.sh" list
expect_output_contains ".merge-gate/spec.md"

it "承認後に、挙げていない既存テストを変更したら、作業を終了させない"
new_repo "$CONFIG"
write_spec "$SPEC"
write_tests AC-1 AC-2 AC-3
"$SCRIPTS/lock.sh" add .merge-gate/spec.md tests/filter.test.js >/dev/null
echo "// 期待値を変えた" >>tests/add.test.js
run_hook stop.sh "$(stop_input)"
expect_status 2
expect_output_contains "既存のテスト tests/add.test.js を変更しているが"

finish
