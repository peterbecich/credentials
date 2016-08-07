#!/usr/bin/env bash

set -e

store="$1"

if [ -z "$store" ]; then
    echo "Usage: run <STORE>"
    exit 1
fi

region="eu-central-1"

send() {
    local mode="$1"
    local args="$2"

    credentials $mode -r $region -u $store $args --format echo
}

gets() {
    local name="$1"
    local expect="$2"
    local context="$3"

    local actual="$(credentials get -r $region -u $store --name $name $context --format echo)"

    if [ "$expect" != "$actual" ]; then
        send "list"
        echo ""
        echo "Test failed for $name, expected: $expect, actual: $actual"
        send "get" "-l debug --name $name $context"
        echo ""
        exit 1
    fi
}

puts() {
    local __revision=$1
    local name="$2"
    local secret="$3"
    local context="$4"

    local revision=$(credentials put -r $region -u $store --name $name -s "$secret" $context --format echo)
    gets "$name" "$secret" "$context"

    eval $__revision="'$revision'"
}

send "cleanup" "-f"
echo ""
send "setup"

echo ""
echo "Put series ..."

puts foo1 "foo" "secret"
puts foo2 "foo" "not so secret"
puts foo3 "foo" "something"
puts foo4 "foo" "bother"
puts bar1 "bar" "rah rah rah"
puts bar2 "bar" "nothing"
puts baz1 "baz" "supercalifragilistic"
puts baz2 "baz" "anything"

echo "Delete revision $foo3"

send "delete" "--name foo --revision $foo3 -f"
gets "foo" "bother"

echo "Delete revision $foo4"

send "delete" "--name foo --revision $foo4 -f"
gets "foo" "not so secret"

echo "Put with context ..."

puts bar3 "bar" "longer secret '-c a=b -c this=notthis'"

send "list"

echo "Done."