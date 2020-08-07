#!/bin/bash

ZIG=/mnt/d/zig-linux-x86_64/zig
BUILD_MODES=('' '-Drelease-fast' '-Drelease-safe' '-Drelease-small')
BUILD_STRING=('Debug' 'Release fast' 'Release safe' 'Release small')
RT_TEST_MODES=('Initialisation' 'Panic' 'Scheduler')

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'

NO_COLOUR='\033[0m'

for i in ${!BUILD_MODES[@]}
do
    echo -e ${GREEN}"Build mode: "${BUILD_STRING[$i]}${NO_COLOUR}
    
    echo -e ${PURPLE}"Building "${BUILD_STRING[$i]}${NO_COLOUR}
    CMD=$ZIG" build "${BUILD_MODES[$i]}
    STDO=$($CMD 2>&1)
    if [ $? -ne 0 ]; then
        echo "$STDO"
        echo -e ${RED}"Build failed for command: "${CMD}${NO_COLOUR}
        exit $?
    fi
    
    echo -e ${PURPLE}"Unit testing "${BUILD_STRING[$i]}${NO_COLOUR}
    CMD=$ZIG" build test "${BUILD_MODES[$i]}
    STDO=$($CMD 2>&1)
    if [ $? -ne 0 ]; then
        echo "$STDO"
        echo -e ${RED}"Unit test failed for command: "${CMD}${NO_COLOUR}
        exit $?
    fi
    
    for j in ${!RT_TEST_MODES[@]}
    do
        echo -e ${PURPLE}"Run time testing "${BUILD_STRING[$i]} "for "${RT_TEST_MODES[$j]}${NO_COLOUR}
        CMD=$ZIG" build rt-test -Ddisable-display -Dtest-mode="${RT_TEST_MODES[$j]}" "${BUILD_MODES[$i]}
        STDO=$($CMD 2>&1)
        if [ $? -ne 0 ]; then
            echo "$STDO"
            echo -e ${RED}"Unit test failed for command: "${CMD}${NO_COLOUR}
            exit $?
        fi
    done
done

echo -e ${CYAN}"Done"${NO_COLOUR}
