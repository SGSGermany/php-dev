#!/bin/bash
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
shopt -s nullglob

ENABLE=
case "${1:---auto}" in
    "--setup")  [[ ! "${ENABLE_DEVELOPER_MODE:-}" =~ ^(1|y|yes|on|true)$ ]] || ENABLE="y" ;;
    "--auto")   [[ "${ENABLE_DEVELOPER_MODE:-}" =~ ^(1|y|yes|on|true)$ ]] && ENABLE="y" \
                    || { [ "$(passwd -S www-data | cut -d' ' -f2)" != "P" ] || ENABLE="n"; } ;;
    "--toggle") [ "$(passwd -S www-data | cut -d' ' -f2)" == "P" ] && ENABLE="n" || ENABLE="y" ;;
    "--on")     ENABLE="y" ;;
    "--off")    ENABLE="n" ;;
    *) echo "Invalid option: $1" >&2; exit 1 ;;
esac

if [ "$ENABLE" == "y" ]; then
    # unlock 'www-data' user
    echo "Unlocking 'www-data' user..."

    USER_PASSWORD_FILE="/run/secrets/www-data_password"
    echo "    - Read password from ${USER_PASSWORD_FILE@Q}"

    [ -e "$USER_PASSWORD_FILE" ] || { echo "Failed to enable developer mode:" \
        "Missing required container secret ${USER_PASSWORD_FILE@Q}" >&2; exit 1; }
    [ -f "$USER_PASSWORD_FILE" ] || { echo "Invalid container secret ${USER_PASSWORD_FILE@Q}:" \
        "Not a file" >&2; exit 1; }
    [ -r "$USER_PASSWORD_FILE" ] || { echo "Invalid container secret ${USER_PASSWORD_FILE@Q}:" \
        "Permission denied" >&2; exit 1; }
    USER_PASSWORD="$(cat "$USER_PASSWORD_FILE")"

    echo "    - Check password validity"
    (( ${#USER_PASSWORD} >= 8 )) || { echo "Invalid container secret ${USER_PASSWORD_FILE@Q}:" \
        "Password must be at least 8 characters long" >&2; exit 1; }
    [ "$USER_PASSWORD" != "www-data" ] || { echo "Invalid container secret ${USER_PASSWORD_FILE@Q}:" \
        "Password must not match username" >&2; exit 1; }

    echo "    - Change login shell to '/bin/bash'"
    sed -i -e 's#^\(www-data:[^:]*:[0-9][0-9]*:[0-9][0-9]*:[^:]*:/[^:]*\):\(.*\)$#\1:/bin/bash#' /etc/passwd

    echo "    - Unlock user and set password"
    echo "www-data:$USER_PASSWORD" | chpasswd 2> /dev/null

    # enable PHP XDebug extension
    echo "Enabling PHP XDebug extension in '/etc/php/*/*/conf.d/20-xdebug.ini'..."
    for PHP_MILESTONE in /etc/php/?.?; do
        PHP_MILESTONE="$(basename "$PHP_MILESTONE")"
        [ -e "/etc/php/$PHP_MILESTONE/mods-available/xdebug.ini" ] \
            || { echo "    - $PHP_MILESTONE (-)"; continue; }

        echo "    - $PHP_MILESTONE ($(dirname /etc/php/$PHP_MILESTONE/*/conf.d | xargs -rL1 basename | paste -sd ' '))"
        for PHP_CONFIG_DIR in /etc/php/$PHP_MILESTONE/*/conf.d; do
            [ -e "$PHP_CONFIG_DIR/20-xdebug.ini" ] \
                || ln -s "/etc/php/$PHP_MILESTONE/mods-available/xdebug.ini" "$PHP_CONFIG_DIR/20-xdebug.ini"
        done
    done

    # copy ssh host keys from container secrets, or generate a new RSA host key
    echo "Deploying \`sshd\` host keys..."

    SSH_HOST_KEY_EXISTS=
    for SSH_HOST_KEY in ssh_host_rsa_key ssh_host_ecdsa_key ssh_host_ed25519_key; do
        if [ -e "/etc/ssh/$SSH_HOST_KEY" ]; then
            echo "    - Remove old '/etc/ssh/$SSH_HOST_KEY' key file"
            rm -f "/etc/ssh/$SSH_HOST_KEY" "/etc/ssh/$SSH_HOST_KEY.pub"
        fi

        if [ -e "/run/secrets/$SSH_HOST_KEY" ]; then
            echo "    - Copy '/run/secrets/$SSH_HOST_KEY' key file to '/etc/ssh/$SSH_HOST_KEY'"

            [ -f "/run/secrets/$SSH_HOST_KEY" ] || { echo "Invalid container secret" \
                "'/run/secrets/$SSH_HOST_KEY': Not a file" >&2; exit 1; }
            [ -r "/run/secrets/$SSH_HOST_KEY" ] || { echo "Invalid container secret" \
                "'/run/secrets/$SSH_HOST_KEY': Permission denied" >&2; exit 1; }
            install -o root -g root -m 0600 -p "/run/secrets/$SSH_HOST_KEY" "/etc/ssh/$SSH_HOST_KEY"

            SSH_HOST_KEY_EXISTS="y"
        fi
    done

    if [ -z "$SSH_HOST_KEY_EXISTS" ]; then
        echo "    - Generate new '/etc/ssh/ssh_host_rsa_key' key file"
        ssh-keygen -t rsa -b 4096 -N "" -C "${HOSTNAME:-$(hostname)}" \
            -f "/etc/ssh/ssh_host_rsa_key" 2>&1 \
            | sed -e 's/^/        /'
    fi

    # start sshd
    echo "Starting \`sshd\` daemon..."

    echo "    - Test config"
    /usr/sbin/sshd -t

    sshd_signal HUP 2> /dev/null \
        || { echo "    - Run \`/usr/sbin/sshd\`"; /usr/sbin/sshd; }
elif [ "$ENABLE" == "n" ]; then
    # stop sshd
    echo "Stopping \`sshd\` daemon..."
    sshd_signal TERM 2> /dev/null \
        || echo "    - Not running"

    # disable PHP XDebug extension
    echo "Disabling PHP XDebug extension in '/etc/php/*/*/conf.d/20-xdebug.ini'..."
    for PHP_MILESTONE in /etc/php/?.?; do
        PHP_MILESTONE="$(basename "$PHP_MILESTONE")"
        [ -e "/etc/php/$PHP_MILESTONE/mods-available/xdebug.ini" ] \
            || { echo "    - $PHP_MILESTONE (-)"; continue; }

        echo "    - $PHP_MILESTONE ($(printf '%s\n' /etc/php/$PHP_MILESTONE/*/conf.d/20-xdebug.ini \
            | cut -d'/' -f5 | paste -sd ' '))"
        rm -f /etc/php/$PHP_MILESTONE/*/conf.d/20-xdebug.ini
    done

    # lock 'www-data' user
    echo "Locking 'www-data' user..."

    echo "    - Change login shell to '/usr/sbin/nologin'"
    sed -i -e 's#^\(www-data:[^:]*:[0-9][0-9]*:[0-9][0-9]*:[^:]*:/[^:]*\):\(.*\)$#\1:/usr/sbin/nologin#' /etc/passwd

    echo "    - Remove password and lock user"
    echo "www-data:!" | chpasswd -e 2> /dev/null
fi
