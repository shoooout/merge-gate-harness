#!/bin/bash
# すべてのテストを実行する。1 つでも失敗があれば 0 以外で終了する。
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

failed=0
for test_file in *_test.sh; do
  echo "== $test_file"
  bash "$test_file" || failed=1
done
exit "$failed"
