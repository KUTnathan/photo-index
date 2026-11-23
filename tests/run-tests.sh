#!/bin/bash
set -u

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/photo-index-tests.XXXXXXXX") || exit 1
fixture_dir="$test_root/Desk Photos"
output_dir="$test_root/CSV Results"
mkdir -p "$fixture_dir/nested" "$output_dir"
fixture_dir=$(CDPATH= cd -- "$fixture_dir" && pwd -P)
fake="$project_dir/tests/fake-exiftool"
chmod u+x "$fake"

cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

passes=0
failures=0

check() {
  description=$1
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$description"
    passes=$((passes + 1))
  else
    printf 'FAIL: %s\n' "$description" >&2
    failures=$((failures + 1))
  fi
}

run_case() {
  scenario=$1
  output=$2
  FAKE_SCENARIO="$scenario" PHOTO_INDEX_EXIFTOOL="$fake" \
    bash "$project_dir/photo-index.sh" "$fixture_dir" "$output"
}

# Replace the stable placeholder in fake output with this run's temporary path.
escaped_root=$(printf '%s' "$fixture_dir" | sed 's/[\/&]/\\&/g')
sed "s/ROOT_PLACEHOLDER/$escaped_root/g" "$fake" > "$test_root/fake-exiftool"
fake="$test_root/fake-exiftool"
chmod u+x "$fake"

success_csv="$output_dir/success.csv"
run_case success "$success_csv" > "$test_root/success.out" 2> "$test_root/success.err"
check "successful scan exits cleanly" test "$?" -eq 0
check "successful scan creates CSV" test -s "$success_csv"
check "CSV has friendly relative-path headers" grep -Fq '"Relative folder","Relative path","Caption"' "$success_csv"
check "nested relative path is recorded" grep -Fq 'nested/news, photo.jpg' "$success_csv"
check "nested relative folder is recorded" grep -Fq '"nested","nested/news, photo.jpg"' "$success_csv"
check "absolute source path stays out of CSV" sh -c '! grep -Fq "$1" "$2"' sh "$fixture_dir" "$success_csv"
check "duplicate keywords are removed" grep -Fq 'Austin; City Hall; Politics' "$success_csv"
check "dedicated alt text is indexed" grep -Fq 'A reporter stands at a lectern.' "$success_csv"
check "extended accessibility description is indexed" grep -Fq 'The reporter faces a row of microphones' "$success_csv"
check "formula-like filename is neutralized" grep -Fq "'=formula.jpg" "$success_csv"
check "formula-like caption is neutralized" grep -Fq "'=HYPERLINK" "$success_csv"
check "completion count is plain English" grep -Fq 'Done. Indexed 2 photo(s).' "$test_root/success.out"

progress_csv="$output_dir/progress.csv"
run_case progress "$progress_csv" > "$test_root/progress.out" 2> "$test_root/progress.err"
check "ExifTool progress messages do not become warnings" test ! -e "$output_dir/progress-warnings.txt"
check "progress scan still creates its CSV" test -s "$progress_csv"

warning_csv="$output_dir/warning.csv"
printf 'DO NOT OVERWRITE\n' > "$output_dir/warning-warnings.txt"
run_case warning "$warning_csv" > "$test_root/warning.out" 2> "$test_root/warning.err"
check "warning does not discard usable CSV" test -s "$warning_csv"
check "existing warning report is not overwritten" grep -Fxq 'DO NOT OVERWRITE' "$output_dir/warning-warnings.txt"
warning_report=$(find "$output_dir" -name 'warning-warnings-*.txt' -print -quit)
check "new warning report gets a unique name" test -s "$warning_report"
check "warning report is private" test "$(stat -f '%Lp' "$warning_report")" = "600"
check "warning is explained in terminal" grep -Fq 'warning line(s) were saved' "$test_root/warning.out"

race_csv="$output_dir/race.csv"
run_case slow "$race_csv" > "$test_root/race-one.out" 2> "$test_root/race-one.err" &
race_one_pid=$!
sleep 0.2
set +e
run_case slow "$race_csv" > "$test_root/race-two.out" 2> "$test_root/race-two.err"
race_two_status=$?
set -e
wait "$race_one_pid"
race_one_status=$?
check "one concurrent scan succeeds" test "$race_one_status" -eq 0
check "second concurrent scan is refused" test "$race_two_status" -ne 0
check "concurrent refusal is explained" grep -Fq 'Another scan may already be using this CSV name' "$test_root/race-two.err"

set +e
run_case empty "$output_dir/empty.csv" > "$test_root/empty.out" 2> "$test_root/empty.err"
empty_status=$?
run_case fail "$output_dir/fail.csv" > "$test_root/fail.out" 2> "$test_root/fail.err"
fail_status=$?
run_case malformed "$output_dir/malformed.csv" > "$test_root/malformed.out" 2> "$test_root/malformed.err"
malformed_status=$?
run_case success "$success_csv" > "$test_root/existing.out" 2> "$test_root/existing.err"
existing_status=$?
run_case success "$test_root/missing/output.csv" > "$test_root/path.out" 2> "$test_root/path.err"
path_status=$?
set -e

check "empty folder fails" test "$empty_status" -ne 0
check "empty folder gives a next step" grep -Fq 'No supported photos were found' "$test_root/empty.err"
check "scan failure fails" test "$fail_status" -ne 0
check "scan failure leaves no CSV" test ! -e "$output_dir/fail.csv"
failure_report=$(find "$output_dir" -name 'fail-failed-scan-*.txt' -print -quit)
check "scan failure preserves full private report" test -s "$failure_report"
check "failure report is private" test "$(stat -f '%Lp' "$failure_report")" = "600"
check "malformed metadata fails" test "$malformed_status" -ne 0
check "existing CSV is not overwritten" test "$existing_status" -ne 0
check "missing output folder is explained" test "$path_status" -ne 0
check "no temporary scan files remain" sh -c '! find "$1" -name ".photo-index-*" -print -quit | grep -q .' sh "$output_dir"

printf '\n%s passed; %s failed.\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
