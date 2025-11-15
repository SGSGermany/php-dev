#!/usr/bin/dumb-init /bin/bash
# PHP Development Environment
# A Debian-based PHP development environment running php-fpm.
#
# Copyright (c) 2025  SGS Serious Gaming & Simulations GmbH
#
# This work is licensed under the terms of the MIT license.
# For a copy, see LICENSE file or <https://opensource.org/licenses/MIT>.
#
# SPDX-License-Identifier: MIT
# License-Filename: LICENSE

set -eu -o pipefail
export LC_ALL=C.UTF-8

# check environment variables
if [ -z "${PHP_MILESTONES:-}" ]; then
    export PHP_MILESTONES="${PHP_MILESTONE:-}"
    export PHP_MILESTONE="${PHP_MILESTONE:-}"
elif [ -z "${PHP_MILESTONE:-}" ]; then
    export PHP_MILESTONE="${PHP_MILESTONES##* }"
elif [[ " ${PHP_MILESTONES[*]} " != *" $PHP_MILESTONE "* ]]; then
    echo "Contradictory 'PHP_MILESTONES' and 'PHP_MILESTONE' environment variables" >&2
    exit 1
fi

# start container
(( $# > 0 )) || set -- php-fpm "$@"
if [ "$1" == "php-fpm" ]; then
    # enable developer mode, if requested
    /dev.sh --setup

    # listen on TCP port 3306 to forward /run/mysql/mysql.sock
    [ ! -e /run/mysql/mysql.sock ] || lsof -iTCP:3306 -sTCP:LISTEN &> /dev/null \
        || setsid -f socat \
            TCP4-LISTEN:3306,bind=127.0.0.1,reuseaddr,fork,su=mysql,range=127.0.0.0/8 \
            UNIX-CLIENT:/run/mysql/mysql.sock &> /dev/null

    # start cron
    [ -e /run/crond.pid ] \
        || cron -L 7 &> /dev/null

    # start php-fpm pools
    FPM_POOLS=()
    for FPM_POOL in ${PHP_MILESTONES:-""}; do
        if [ ! -x "$(which "php-fpm$FPM_POOL" 2> /dev/null)" ]; then
            echo "Failed to start \`php-fpm$FPM_POOL\` pool: No such executable" >&2
            exit 1
        fi

        if [ ! -e "/run/php-fpm/$FPM_POOL" ]; then
            mkdir "/run/php-fpm/$FPM_POOL"
            chown www-data:www-data "/run/php-fpm/$FPM_POOL"
            chmod 750 "/run/php-fpm/$FPM_POOL"
        fi
        if [ ! -e "/var/log/php/$FPM_POOL" ]; then
            mkdir "/var/log/php/$FPM_POOL"
            chown www-data:www-data "/var/log/php/$FPM_POOL"
            chmod 750 "/var/log/php/$FPM_POOL"
        fi
        if [ ! -e "/var/www/php$FPM_POOL" ]; then
            mkdir "/var/www/php$FPM_POOL"
            chown www-data:www-data "/var/www/php$FPM_POOL"
        fi

        "php-fpm$FPM_POOL" -F &> /dev/null &
        FPM_POOLS+=( $! )
    done

    # set PHP defaults
    if [ -n "$PHP_MILESTONE" ]; then
        sleep 1

        update-alternatives --quiet --set php "/usr/bin/php$PHP_MILESTONE"
        update-alternatives --quiet --set phpize "/usr/bin/phpize$PHP_MILESTONE"
        update-alternatives --quiet --set php-config "/usr/bin/php-config$PHP_MILESTONE"
        update-alternatives --quiet --set phar "/usr/bin/phar$PHP_MILESTONE"
        update-alternatives --quiet --set phar.phar "/usr/bin/phar.phar$PHP_MILESTONE"

        update-alternatives --quiet --set html "/var/www/php$PHP_MILESTONE"
        update-alternatives --quiet --set php-fpm "/usr/sbin/php-fpm$PHP_MILESTONE"
        [ ! -e "/etc/php/$PHP_MILESTONE/fpm/pool.d/www.conf" ] \
            || update-alternatives --quiet --set php-fpm_www.sock "/run/php-fpm/$PHP_MILESTONE/php-fpm_www.sock"

        [ -e "/usr/local/bin/pie-php$PHP_MILESTONE" ] \
            && update-alternatives --quiet --set pie "/usr/local/bin/pie-php$PHP_MILESTONE" \
            || update-alternatives --quiet --auto pie
        update-alternatives --quiet --set composer "/usr/local/bin/composer-php$PHP_MILESTONE"
        update-alternatives --quiet --set phive "/usr/local/bin/phive-php$PHP_MILESTONE"
    fi

    # abbreviate symlinks on container volumes
    HTML_TARGET="$(update-alternatives --query html \
        | sed -ne 's#^Value: /var/www/\(php[0-9]\.[0-9]\)$#\1#p')"
    FPM_SOCKET_TARGET="$(update-alternatives --query php-fpm_www.sock \
        | sed -ne 's#^Value: /run/php-fpm/\([0-9]\.[0-9]/..*\)$#\1#p')"

    rm -f "/var/www/html"
    [ -z "$HTML_TARGET" ] || ln -s "$HTML_TARGET/" "/var/www/html"

    rm -f "/run/php-fpm/php-fpm_www.sock"
    [ -z "$FPM_SOCKET_TARGET" ] || ln -s "$FPM_SOCKET_TARGET" "/run/php-fpm/php-fpm_www.sock"

    # wait for *any* of the `php-fpm` pools to exit
    # i.e., this script quits if one of the `php-fpm` pools quit
    # if running as PID1, `dumb-init` will kill all other processes
    EXIT_CODE=0
    wait -n "${FPM_POOLS[@]}" || EXIT_CODE=$?

    # kill all other `php-fpm` pools
    kill -TERM "${FPM_POOLS[@]}" ||:
    exit $EXIT_CODE
fi

exec "$@"
