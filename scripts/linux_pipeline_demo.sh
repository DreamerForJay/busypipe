#!/usr/bin/env sh
set -eu

mkdir -p build/linux data/linux
rm -f data/linux/errors.tsv data/linux/errors.tsv.tmp

gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 -c src/common.c -o build/linux/common.o
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 src/lparser.c build/linux/common.o -o build/linux/lparser
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 src/lfilter.c build/linux/common.o -o build/linux/lfilter
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 src/lstore.c build/linux/common.o -o build/linux/lstore

REGEX='^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9][0-9][0-9]) .*'
FIELDS='ip,time,method,path,status'

./build/linux/lparser --regex "$REGEX" --fields "$FIELDS" --csv < samples/access.log | \
  ./build/linux/lfilter --where 'status>=400' | \
  ./build/linux/lstore --db data/linux/errors.tsv --put --key-field ip --ttl 3600

echo '---FILTERED---'
./build/linux/lparser --regex "$REGEX" --fields "$FIELDS" --csv < samples/access.log | \
  ./build/linux/lfilter --where 'status>=400' --select 'ip,path,status'

echo '---STORE---'
cat data/linux/errors.tsv

echo '---GET---'
./build/linux/lstore --db data/linux/errors.tsv --get 192.168.0.4
