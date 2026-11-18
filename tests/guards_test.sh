#!/bin/bash
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---- classify.sh の review_markers

MARKER_CONFIG='{
  "base": "main",
  "checks": { "verify": ["true"] },
  "paths": { "tests": ["tests/*"] },
  "review_markers": ["eslint-disable", "@ts-ignore"]
}'

it "検査を抑制する記述を追加していれば、場所を示して人間に回す"
new_repo "$MARKER_CONFIG"
printf '%s\n' "export const sub = (a, b) => a - b" "// eslint-disable-next-line no-unused-vars" >src/sub.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "人間が確認すると決めた記述を追加している: src/sub.js:2 (eslint-disable)"

it "コミット前の新しいファイルに書いた抑制も検知する"
new_repo "$MARKER_CONFIG"
echo "// @ts-ignore" >src/sub.js
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "src/sub.js:1 (@ts-ignore)"

it "分岐元からあった抑制は、今回の変更の責任にしない"
new_repo "$MARKER_CONFIG"
git switch -q main
echo "// eslint-disable-next-line" >>src/add.js
commit_all "以前からある抑制"
git switch -q work
git merge -q main
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 0

it "既存のファイルの途中に足した抑制の行番号を正しく示す"
new_repo "$MARKER_CONFIG"
git switch -q main
printf '%s\n' "one" "two" "three" >src/lines.js
commit_all "行のあるファイル"
git switch -q work
git merge -q main
printf '%s\n' "one" "two" "// @ts-ignore" "three" >src/lines.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 3
expect_output_contains "src/lines.js:3 (@ts-ignore)"

it "設定で指定していなければ、抑制の記述を見ない"
new_repo '{"base": "main", "checks": {"verify": ["true"]}}'
echo "// eslint-disable" >src/sub.js
commit_all
run "$SCRIPTS/checks/classify.sh"
expect_status 0

# ---- secrets.sh

SECRET_CONFIG='{
  "base": "main",
  "checks": { "verify": ["true"] },
  "paths": { "tests": ["tests/*"], "secrets_ignore": ["tests/fixtures/*"] },
  "secret_patterns": ["corp_[a-f0-9]{16}"]
}'

# 本物の形式に一致する文字列をこのファイルにそのまま書くと、リポジトリのホスティング側の検査に
# 秘密の値として止められる。実行時に組み立てて、ソースには現れないようにする。
fake_aws_key="AKIA$(printf 'IOSFODNN7EXAMPLE')"
fake_github_token="ghp_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)"
fake_private_key="-----BEGIN RSA $(printf 'PRIVATE') KEY-----"

it "秘密の値がなければ成功する"
new_repo "$SECRET_CONFIG"
echo "export const region = 'ap-northeast-1'" >src/config.js
commit_all
run "$SCRIPTS/checks/secrets.sh"
expect_status 0
expect_output_empty

it "アクセスキーの形式の文字列が追加されたら、場所を示して失敗する"
new_repo "$SECRET_CONFIG"
echo "export const key = '$fake_aws_key'" >src/config.js
commit_all
run "$SCRIPTS/checks/secrets.sh"
expect_status 1
expect_output_contains "src/config.js:1 (AWS のアクセスキー)"

it "見つけた値そのものは出力しない"
new_repo "$SECRET_CONFIG"
echo "export const token = '$fake_github_token'" >src/config.js
commit_all
run "$SCRIPTS/checks/secrets.sh"
expect_status 1
case "$OUTPUT" in
  *"$fake_github_token"*) fail "検出した値が出力に含まれている" ;;
esac

it "コミット前のファイルに書かれた秘密鍵も検知する"
new_repo "$SECRET_CONFIG"
echo "$fake_private_key" >deploy.pem.txt
run "$SCRIPTS/checks/secrets.sh"
expect_status 1
expect_output_contains "deploy.pem.txt:1 (秘密鍵)"

it "設定で足した形式も検知する"
new_repo "$SECRET_CONFIG"
echo "token: corp_0123456789abcdef" >src/config.yml
commit_all
run "$SCRIPTS/checks/secrets.sh"
expect_status 1
expect_output_contains "src/config.yml:1 (設定で指定した形式)"

it "除外すると決めたパスは検査しない"
new_repo "$SECRET_CONFIG"
mkdir -p tests/fixtures
echo "$fake_aws_key" >tests/fixtures/keys.txt
commit_all
run "$SCRIPTS/checks/secrets.sh"
expect_status 0

it "分岐元からあった値は、今回の変更の責任にしない"
new_repo "$SECRET_CONFIG"
git switch -q main
echo "export const key = '$fake_aws_key'" >src/legacy.js
commit_all "以前からある値"
git switch -q work
git merge -q main
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
run "$SCRIPTS/checks/secrets.sh"
expect_status 0

it "秘密の値を書いたまま作業を終えようとしたら、終了させない"
new_repo "$SECRET_CONFIG"
echo "export const key = '$fake_aws_key'" >src/config.js
run_hook stop.sh "$(stop_input)"
expect_status 2
expect_output_contains "秘密の値らしい文字列が追加されている"

# ---- red.sh

# 検査コマンドは、tests/ にあるシェルスクリプトをすべて実行する。テストランナーの代わりである。
RED_CONFIG='{
  "base": "main",
  "checks": { "verify": ["for t in tests/*.sh; do sh \"$t\" || exit 1; done"] },
  "paths": { "tests": ["tests/*"], "dependencies": ["package.json"], "no_spec": ["*.md"] }
}'

new_red_repo() {
  new_repo "${1:-$RED_CONFIG}"
  git switch -q main
  echo "test -f src/add.js" >tests/add.sh
  commit_all "検査用のテスト"
  git switch -q work
  git merge -q main
}

expect_clean_tree() {
  [ -z "$(git status --porcelain)" ] || fail "作業ツリーが元に戻っていない: $(git status --porcelain)"
}

it "追加したテストが変更を検出するなら成功し、作業ツリーを元に戻す"
new_red_repo
echo "export const sub = (a, b) => a - b" >src/sub.js
echo "grep -q sub src/sub.js" >tests/sub.sh
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0
expect_clean_tree
[ -f src/sub.js ] || fail "追加したファイルが戻っていない"

it "テストを追加していない変更は、検出するテストがないと判定する"
new_red_repo
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 3
expect_output_contains "この変更を検出するテストがない"
expect_clean_tree

it "変更がなくても通るテストしか追加していなければ、検出するテストがないと判定する"
new_red_repo
echo "export const sub = (a, b) => a - b" >src/sub.js
echo "true" >tests/sub.sh
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 3
expect_clean_tree

it "既存のファイルの変更も、分岐元の内容に戻して確かめる"
new_red_repo
echo "export const add = (a, b) => a + b + 0" >src/add.js
echo "grep -q '+ 0' src/add.js" >tests/add_zero.sh
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0
expect_clean_tree
grep -q '+ 0' src/add.js || fail "変更したファイルの内容が戻っていない"

it "ファイルを削除する変更も、分岐元の状態に戻して確かめ、あとで消し直す"
new_red_repo
git rm -q src/add.js
git rm -q tests/add.sh
echo "test ! -f src/add.js" >tests/removed.sh
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0
expect_clean_tree
[ ! -f src/add.js ] || fail "削除したファイルが作業ツリーに残っている"

it "実行権限のあるファイルを戻したあとも、実行権限を保つ"
new_red_repo
echo "echo run" >src/tool.sh
chmod +x src/tool.sh
echo "test -x src/tool.sh" >tests/tool.sh
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0
expect_clean_tree
[ -x src/tool.sh ] || fail "実行権限が失われている"

it "テストだけの変更は、確かめる対象がないので成功する"
new_red_repo
echo "true" >tests/more.sh
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0

it "仕様を要しないパスだけの変更は、確かめる対象にしない"
new_red_repo
echo "# 説明" >README.md
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0

it "依存の定義は戻さない"
new_red_repo
echo '{}' >package.json
echo "test -f package.json" >tests/pkg.sh
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0
[ -f package.json ] || fail "依存の定義が消えている"

it "未コミットの変更があれば、作業ツリーに触れずにエラーにする"
new_red_repo
echo "export const sub = (a, b) => a - b" >src/sub.js
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 2
[ -f src/sub.js ] || fail "未コミットのファイルが消えている"

it "--in-place を付けなければ実行しない"
new_red_repo
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
run "$SCRIPTS/checks/red.sh"
expect_status 2

it "checks.red を false にすると確かめない"
new_red_repo '{
  "base": "main",
  "checks": { "verify": ["true"], "red": false },
  "paths": { "tests": ["tests/*"] }
}'
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0

it "checks.red にコマンドを指定すると、そのコマンドで確かめる"
new_red_repo '{
  "base": "main",
  "checks": { "verify": ["true"], "red": ["test -f src/sub.js"] },
  "paths": { "tests": ["tests/*"] }
}'
echo "export const sub = (a, b) => a - b" >src/sub.js
commit_all
run "$SCRIPTS/checks/red.sh" --in-place
expect_status 0

finish
