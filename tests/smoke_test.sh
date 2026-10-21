#!/usr/bin/env bash
#
# End-to-end smoke test: builds the Docker image, runs it against a real
# beanstalkd, exercises the main pages and actions, and fails on any PHP
# warning, deprecation or fatal error in a response or in the container log.
#
# Usage: tests/smoke_test.sh [image-tag]
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="${1:-beanstalk-console:smoke}"
NAME="bsc-smoke-$$"
NET="$NAME"
TUBE="smoke-tube"
FAILURES=0
COOKIES="$(mktemp)"

cleanup() {
    docker rm -f "$NAME-web" "$NAME-beanstalkd" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -f "$COOKIES"
}
trap cleanup EXIT

docker build -q -t "$IMAGE" . >/dev/null
docker network create "$NET" >/dev/null
docker run -d --name "$NAME-beanstalkd" --network "$NET" --network-alias beanstalkd \
    --platform linux/amd64 dinamic/docker-alpine-beanstalkd:latest >/dev/null
docker run -d --name "$NAME-web" --network "$NET" -p 127.0.0.1::8080 \
    -e BEANSTALK_SERVERS=beanstalkd:11300 "$IMAGE" >/dev/null

PORT="$(docker port "$NAME-web" 8080/tcp | head -1 | sed 's/.*://')"
BASE="http://127.0.0.1:$PORT"
SERVER="beanstalkd:11300"

for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$BASE/" && break
    sleep 1
done

PHP_VERSION="$(docker exec "$NAME-web" php -r 'echo PHP_VERSION;')"
echo "Running smoke test against PHP $PHP_VERSION"

fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

# check <description> <expected-status> <expected-text|-> <curl args...>
check() {
    local desc="$1" want_status="$2" want_text="$3"
    shift 3
    local body status
    body="$(mktemp)"
    status="$(curl -s -o "$body" -w '%{http_code}' -b "$COOKIES" -c "$COOKIES" "$@")"
    if [ "$status" != "$want_status" ]; then
        fail "$desc: HTTP $status, expected $want_status"
        grep -A2 'alert-danger' "$body" | head -6 | sed 's/^/    /' || true
    elif grep -qiE '<b>(warning|deprecated|fatal error|parse error)</b>|uncaught|stack trace:' "$body"; then
        fail "$desc: PHP error in response"
        grep -iE 'warning|deprecated|fatal|uncaught' "$body" | head -5 | sed 's/^/    /'
    elif [ "$want_text" != "-" ] && ! grep -qF -- "$want_text" "$body"; then
        fail "$desc: response does not contain '$want_text'"
    else
        echo "ok   $desc"
    fi
    rm -f "$body"
}

php_urlencode() { docker exec "$NAME-web" php -r 'echo rawurlencode($argv[1]);' "$1"; }

S="server=$(php_urlencode "$SERVER")"
T="tube=$TUBE"

# Runs a Pheanstalk snippet inside the web container with $p connected.
pheanstalk() {
    local code="$1"
    shift
    docker exec "$NAME-web" php -r '
        require "/var/www/lib/Pheanstalk/ClassLoader.php";
        Pheanstalk_ClassLoader::register("/var/www/lib");
        require "/var/www/lib/Pheanstalk.php";
        $p = new Pheanstalk("beanstalkd", 11300);
    '"$code" -- "$@"
}

# expect_jobs <tube> <state> <count>: asserts against beanstalkd, not the UI.
expect_jobs() {
    local got
    got="$(pheanstalk 'try { echo $p->statsTube($argv[1])["current-jobs-".$argv[2]]; } catch (Exception $e) { echo 0; }' "$1" "$2")"
    if [ "$got" = "$3" ]; then
        echo "ok   $1 has $3 $2 job(s)"
    else
        fail "$1 has $got $2 job(s), expected $3"
    fi
}

# Seed one job in each state the UI distinguishes.
check "add ready job"   200 '"result":true' -X POST "$BASE/?$S&action=addjob" \
    --data-urlencode "tubeName=$TUBE" --data-urlencode 'tubeData={"hello":"ready"}'
check "add delayed job" 200 '"result":true' -X POST "$BASE/?$S&action=addjob" \
    --data-urlencode "tubeName=$TUBE" --data-urlencode 'tubeData={"hello":"delayed"}' \
    --data-urlencode 'tubeDelay=3600'
pheanstalk '$p->useTube($argv[1])->put("{\"hello\":\"buried\"}");
    $p->watch($argv[1])->ignore("default");
    $p->bury($p->reserve(5));' "$TUBE"
expect_jobs "$TUBE" ready 1
expect_jobs "$TUBE" delayed 1
expect_jobs "$TUBE" buried 1

check "home page"           200 'Beanstalk console' "$BASE/"
check "server overview"     200 "$TUBE"             "$BASE/?$S"
check "all tubes reloader"  200 "$TUBE"             "$BASE/?$S&action=reloader&tplMain=ajax&tplBlock=allTubes"
check "server stats block"  200 -                   "$BASE/?$S&tplMain=ajax&tplBlock=serversList"
check "tube page"           200 'hello'             "$BASE/?$S&$T"
check "search"              200 'ready'             "$BASE/?$S&$T&action=search&searchStr=hello"
check "settings cookie"     200 'hello'             -b 'isDisabledJsonDecode=1' "$BASE/?$S&$T"
check "review batches"      200 -                   "$BASE/?$S&action=reviewBatches"

check "kick buried"         302 -                   "$BASE/?$S&$T&action=kick&count=1"
expect_jobs "$TUBE" buried 0
expect_jobs "$TUBE" ready 2
check "move ready to buried" 302 -                  "$BASE/?$S&$T&action=moveJobsTo&state=ready&destState=buried"
expect_jobs "$TUBE" ready 0
expect_jobs "$TUBE" buried 2
check "move buried to tube" 302 -                   "$BASE/?$S&$T&action=moveJobsTo&state=buried&destTube=$TUBE-moved"
expect_jobs "$TUBE-moved" ready 2
check "moved tube page"     200 'hello'             "$BASE/?$S&tube=$TUBE-moved"
check "delete all delayed"  302 -                   "$BASE/?$S&$T&action=deleteAll&state=delayed"
expect_jobs "$TUBE" delayed 0
check "delete all ready"    302 -                   "$BASE/?$S&tube=$TUBE-moved&action=deleteAll&state=ready"
expect_jobs "$TUBE-moved" ready 0

check "add job to pause"    200 '"result":true'     -X POST "$BASE/?$S&action=addjob" \
    --data-urlencode "tubeName=$TUBE" --data-urlencode 'tubeData=pause'
check "pause tube"          302 -                   "$BASE/?$S&$T&action=pause&count=60"
check "paused tube page"    200 'pause'             "$BASE/?$S&$T"

check "new sample form"     200 "$TUBE"             "$BASE/?action=newSample"
check "save sample"         302 -                   -X POST "$BASE/?action=newSample" \
    --data-urlencode 'name=smoke sample' --data-urlencode 'jobdata={"hello":"sample"}' \
    --data-urlencode "tubes[$TUBE]=1"
check "manage samples"      200 'smoke sample'      "$BASE/?action=manageSamples"
SAMPLE_KEY="$(docker exec "$NAME-web" php -r 'echo md5("smoke sample");')"
check "edit sample form"    200 'checked="checked"' "$BASE/?action=editSample&key=$SAMPLE_KEY"
check "load sample to tube" 302 -                   "$BASE/?$S&$T&action=loadSample&key=$SAMPLE_KEY"
expect_jobs "$TUBE" ready 2
# Only ready jobs remain, so the delayed and buried searches find nothing.
check "search, empty states" 200 'sample'          "$BASE/?$S&$T&action=search&searchStr=sample"
check "delete sample"       302 -                   "$BASE/?action=deleteSample&key=$SAMPLE_KEY"

check "unreachable server"  200 'unavailable'       "$BASE/?server=nonexistent:11300"

if docker logs "$NAME-web" 2>&1 | grep -E 'PHP (Warning|Deprecated|Notice|Fatal|Parse)'; then
    fail "PHP errors in container log (above)"
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES smoke check(s) failed on PHP $PHP_VERSION"
    exit 1
fi
echo "All smoke checks passed on PHP $PHP_VERSION"
