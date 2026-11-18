#!/bin/bash
# テスト用の最小限の道具。bats などを入れずに済ませ、macOS 標準の bash 3.2 と CI の両方で同じように動かす。

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$HARNESS_ROOT/scripts"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-test.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

# 利用者のグローバルな git 設定(署名の強制、hooks、既定ブランチ名など)に結果を左右させない
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "失敗: $CURRENT_TEST"
  echo "    $1"
}

# run <コマンド>...: 標準出力と標準エラーを OUTPUT に、終了コードを STATUS に入れる
run() {
  OUTPUT="$("$@" 2>&1)"
  STATUS=$?
}

expect_status() {
  [ "$STATUS" -eq "$1" ] || fail "終了コード $1 を期待したが $STATUS だった。出力: $OUTPUT"
}

expect_output_contains() {
  case "$OUTPUT" in
    *"$1"*) ;;
    *) fail "出力に「$1」が含まれない。出力: $OUTPUT" ;;
  esac
}

expect_output_empty() {
  [ -z "$OUTPUT" ] || fail "出力が空であることを期待した。出力: $OUTPUT"
}

# new_repo <設定の JSON>: main に設定と初期ファイルをコミットし、作業用ブランチに切り替えたリポジトリを作る。
# 以降のコマンドがそのリポジトリの中で動くように、カレントディレクトリを移す。
new_repo() {
  REPO="$(mktemp -d "$WORK_ROOT/repo.XXXXXX")"
  cd "$REPO" || exit 1
  git init -q -b main
  printf '%s\n' "$1" >.merge-gate.json
  mkdir -p src tests
  echo "export const add = (a, b) => a + b" >src/add.js
  echo "test('add', () => {})" >tests/add.test.js
  git add -A
  git commit -q -m init
  git switch -q -c work
}

commit_all() {
  git add -A
  git commit -q -m "${1:-change}"
}

finish() {
  echo ""
  echo "$TESTS_RUN 件中 $TESTS_FAILED 件が失敗"
  [ "$TESTS_FAILED" -eq 0 ]
}
