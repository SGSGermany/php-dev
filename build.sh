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

[ -v CI_TOOLS ] && [ "$CI_TOOLS" == "SGSGermany" ] \
    || { echo "Invalid build environment: Environment variable 'CI_TOOLS' not set or invalid" >&2; exit 1; }

[ -v CI_TOOLS_PATH ] && [ -d "$CI_TOOLS_PATH" ] \
    || { echo "Invalid build environment: Environment variable 'CI_TOOLS_PATH' not set or invalid" >&2; exit 1; }

source "$CI_TOOLS_PATH/helper/common.sh.inc"
source "$CI_TOOLS_PATH/helper/common-traps.sh.inc"
source "$CI_TOOLS_PATH/helper/container.sh.inc"
source "$CI_TOOLS_PATH/helper/container-debian.sh.inc"
source "$CI_TOOLS_PATH/helper/php.sh.inc"
source "$CI_TOOLS_PATH/helper/gpg.sh.inc"

BUILD_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$BUILD_DIR/container.env"

readarray -t -d' ' TAGS < <(printf '%s' "$TAGS")

echo + "CONTAINER=\"\$(buildah from $(quote "$BASE_IMAGE"))\"" >&2
CONTAINER="$(buildah from "$BASE_IMAGE")"

echo + "MOUNT=\"\$(buildah mount $(quote "$CONTAINER"))\"" >&2
MOUNT="$(buildah mount "$CONTAINER")"

echo + "rsync -v -rl --exclude .gitignore ./src/ …/" >&2
rsync -v -rl --exclude '.gitignore' "$BUILD_DIR/src/" "$MOUNT/"

cmd buildah run "$CONTAINER" -- \
    chmod 750 \
        "/run/php-fpm" \
        "/tmp/php" \
        "/var/log/php"

# install runtime dependencies
pkg_install "$CONTAINER" \
    dumb-init \
    cron \
    socat \
    lsof

# install build essentials
pkg_install "$CONTAINER" \
    build-essential \
    rsync \
    ca-certificates \
    gnupg \
    git \
    patch \
    unzip \
    tar \
    xz-utils

# install OpenSSH server and common user tools
pkg_install "$CONTAINER" \
    openssh-server \
    bash-completion \
    man-db \
    manpages \
    vim \
    less \
    curl

# prepare users
user_changeuid "$CONTAINER" www-data 65536

user_add "$CONTAINER" php-sock 65537

cmd buildah run "$CONTAINER" -- \
    usermod -aG php-sock www-data

user_add "$CONTAINER" mysql 65538

# create runtime directories
for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    cmd buildah run "$CONTAINER" -- \
        mkdir \
            "/run/php-fpm/$PHP_MILESTONE" \
            "/tmp/php/$PHP_MILESTONE" \
            "/tmp/php/$PHP_MILESTONE/php-tmp" \
            "/tmp/php/$PHP_MILESTONE/php-uploads" \
            "/tmp/php/$PHP_MILESTONE/php-session" \
            "/var/log/php/$PHP_MILESTONE" \
            "/var/www/php$PHP_MILESTONE"

    cmd buildah run "$CONTAINER" -- \
        chown www-data:www-data \
            "/run/php-fpm/$PHP_MILESTONE" \
            "/tmp/php/$PHP_MILESTONE" \
            "/tmp/php/$PHP_MILESTONE/php-tmp" \
            "/tmp/php/$PHP_MILESTONE/php-uploads" \
            "/tmp/php/$PHP_MILESTONE/php-session" \
            "/var/log/php/$PHP_MILESTONE" \
            "/var/www/php$PHP_MILESTONE"

    cmd buildah run "$CONTAINER" -- \
        chmod 750 \
            "/run/php-fpm/$PHP_MILESTONE" \
            "/tmp/php/$PHP_MILESTONE" \
            "/tmp/php/$PHP_MILESTONE/php-tmp" \
            "/tmp/php/$PHP_MILESTONE/php-uploads" \
            "/tmp/php/$PHP_MILESTONE/php-session" \
            "/var/log/php/$PHP_MILESTONE"

    cmd buildah run "$CONTAINER" -- \
        chmod +t "/tmp/php/$PHP_MILESTONE"
done

# setup DEB.SURY.ORG repository (@oerdnj's PHP LTS repo)
echo + "PHP_REPO_KEYRING=\"\$(mktemp)\"" >&2
PHP_REPO_KEYRING="$(mktemp)"
trap_exit rm -f "$PHP_REPO_KEYRING"

gpg_recv "$PHP_REPO_KEYRING" "${PHP_REPO_GPG_KEYS[@]}"

echo + "gpg --dearmor -o …/usr/share/keyrings/deb.sury.org-php.gpg $(quote "$PHP_REPO_KEYRING")" >&2
gpg --dearmor -o "$MOUNT/usr/share/keyrings/deb.sury.org-php.gpg" "$PHP_REPO_KEYRING"

cmd buildah run "$CONTAINER" -- \
    sh -c 'printf "deb [signed-by=%s] %s %s %s" "$1" "$2" "$(. /etc/os-release ; echo $VERSION_CODENAME)" "main" > "$3"' sh \
        "/usr/share/keyrings/deb.sury.org-php.gpg" \
        "$PHP_REPO" \
        "/etc/apt/sources.list.d/php.list"

cmd buildah run "$CONTAINER" -- \
    apt-get update

# install PHP packages
pkg_install "$CONTAINER" \
    "${PHP_PACKAGES[@]}"

PHP_VERSIONS=()
PHP_LATEST_VERSION=

for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    PHP_EXEC="/usr/bin/php$PHP_MILESTONE"

    echo + "[ -x $(quote "…$PHP_EXEC") ]" >&2
    if [ ! -x "$MOUNT$PHP_EXEC" ]; then
        echo "Failed to determine full PHP $PHP_MILESTONE version: \`$PHP_EXEC\` executable not found" >&2
        exit 1
    fi

    echo + "PHP_VERSION_STRING=\"\$(buildah run $(quote "$CONTAINER") -- $PHP_EXEC -r 'echo PHP_VERSION;')\"" >&2
    PHP_VERSION_STRING="$(buildah run "$CONTAINER" -- "$PHP_EXEC" -r 'echo PHP_VERSION;')"

    echo + "[[ ! \"\$PHP_VERSION_STRING\" =~ ^\"\$PHP_MILESTONE\"\.([0-9]+)(-dev|(alpha|beta|RC|pl)[0-9]+)?([+~-]|$) ]]" >&2
    if [[ ! "$PHP_VERSION_STRING" =~ ^"$PHP_MILESTONE"\.([0-9]+)(-dev|(alpha|beta|RC|pl)[0-9]+)?([+~-]|$) ]]; then
        echo "Failed to determine full PHP $PHP_MILESTONE version: Invalid output of" \
            "\`$PHP_EXEC -r 'echo PHP_VERSION;'\`: $PHP_VERSION_STRING" >&2
        exit 1
    fi

    PHP_VERSION="$PHP_MILESTONE.${BASH_REMATCH[1]}${BASH_REMATCH[2]}"

    echo + "PHP_VERSIONS+=( $(quote "$PHP_VERSION") )" >&2
    PHP_VERSIONS+=( "$PHP_VERSION" )

    if [ "$PHP_MILESTONE" == "$PHP_LATEST_MILESTONE" ]; then
        echo + "PHP_LATEST_VERSION=$(quote "$PHP_VERSION")" >&2
        PHP_LATEST_VERSION="$PHP_VERSION"
    fi
done

if [ -z "$PHP_LATEST_VERSION" ]; then
    echo "Failed to determine full PHP $PHP_LATEST_MILESTONE version: Not installed" >&2
    exit 1
fi

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set php "/usr/bin/php$PHP_LATEST_MILESTONE"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set phpize "/usr/bin/phpize$PHP_LATEST_MILESTONE"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set php-config "/usr/bin/php-config$PHP_LATEST_MILESTONE"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set phar "/usr/bin/phar$PHP_LATEST_MILESTONE"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set phar.phar "/usr/bin/phar.phar$PHP_LATEST_MILESTONE"

# install alternatives
setup_dangling_alternatives() {
    local CONTAINER="$1"
    local MOUNT="$(buildah mount "$CONTAINER")"
    local LINK="$2" NAME="$3" ALTERNATIVE_TEMPLATE="$4"
    local DEFAULT="$5"
    shift 5

    local ALTERNATIVE= ALTERNATIVES=() PRIORITIES=()
    for ALTERNATIVE in "$@"; do
        PRIORITIES+=( "${ALTERNATIVE//./}" )

        ALTERNATIVE="$(printf "$ALTERNATIVE_TEMPLATE" "$ALTERNATIVE")"
        ALTERNATIVES+=( "$ALTERNATIVE" )

        echo + "touch $(quote "…$ALTERNATIVE")" >&2
        touch "$MOUNT$ALTERNATIVE"
    done

    for (( i=0 ; i < $# ; i++ )); do
        cmd buildah run "$CONTAINER" -- \
            update-alternatives --install "$LINK" "$NAME" \
                "${ALTERNATIVES[i]}" "${PRIORITIES[i]}"
    done

    cmd buildah run "$CONTAINER" -- \
        update-alternatives --set "$NAME" "$(printf "$ALTERNATIVE_TEMPLATE" "$DEFAULT")"

    for ALTERNATIVE in "${ALTERNATIVES[@]}"; do
        echo "rm -f $(quote "…$ALTERNATIVE")" >&2
        rm -f "$MOUNT$ALTERNATIVE"
    done
}

for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    cmd buildah run "$CONTAINER" -- \
        update-alternatives --install "/var/www/html" "html" \
            "/var/www/php$PHP_MILESTONE" "${PHP_MILESTONE//./}"

    cmd buildah run "$CONTAINER" -- \
        update-alternatives --install "/usr/sbin/php-fpm" "php-fpm" \
            "/usr/sbin/php-fpm$PHP_MILESTONE" "${PHP_MILESTONE//./}"
done

setup_dangling_alternatives "$CONTAINER" \
    "/run/php-fpm/php-fpm.sock" "php-fpm.sock" "/run/php-fpm/%s/php-fpm_www.sock" \
    "$PHP_LATEST_MILESTONE" "${PHP_MILESTONES[@]}"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set php-fpm "/usr/sbin/php-fpm$PHP_LATEST_MILESTONE"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set html "/var/www/php$PHP_LATEST_MILESTONE"

# patch PHP config
for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    PHP_INI_VALUES=(
        "display_errors" "On"
        "display_startup_errors" "On"
        "error_reporting" "E_ALL"
        "sys_temp_dir" "/tmp/php/$PHP_MILESTONE/php-tmp/"
        "upload_tmp_dir" "/tmp/php/$PHP_MILESTONE/php-uploads/"
        "session.save_path" "/tmp/php/$PHP_MILESTONE/php-session/"
        "expose_php" "On"
        "zend.assertions" "1"
        "zend.exception_ignore_args" "Off"
        "zend.exception_string_param_max_len" "256"
    )

    cmd php_patch_config "$CONTAINER" "/etc/php/$PHP_MILESTONE/fpm/php.ini" \
        "${PHP_INI_VALUES[@]}" \
        "log_errors" "On" \
        "error_log" "/var/log/php/$PHP_MILESTONE/php-fpm_www.log"

    cmd php_patch_config "$CONTAINER" "/etc/php/$PHP_MILESTONE/cli/php.ini" \
        "${PHP_INI_VALUES[@]}" \
        "log_errors" "Off" \
        "error_log" "/var/log/php/$PHP_MILESTONE/php-cli.log"

    echo + "rm -f …/etc/php/$PHP_MILESTONE/{cli,fpm}/conf.d/20-xdebug.ini" >&2
    rm -f "$MOUNT/etc/php/$PHP_MILESTONE/cli/conf.d/20-xdebug.ini" \
        "$MOUNT/etc/php/$PHP_MILESTONE/fpm/conf.d/20-xdebug.ini"
done

# patch PHP-FPM config
for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    cmd php_patch_config "$CONTAINER" "/etc/php/$PHP_MILESTONE/fpm/php-fpm.conf" \
        "pid" "/run/php/php$PHP_MILESTONE-fpm.pid" \
        "error_log" "/var/log/php/$PHP_MILESTONE/php-fpm.log"

    cmd php_patch_config "$CONTAINER" "/etc/php/$PHP_MILESTONE/fpm/pool.d/www.conf" \
        "listen" "/run/php-fpm/$PHP_MILESTONE/php-fpm_www.sock" \
        "listen.owner" "php-sock" \
        "listen.group" "php-sock" \
        "listen.mode" "0660" \
        "pm" "dynamic" \
        "pm.max_children" "8" \
        "pm.start_servers" "2" \
        "pm.min_spare_servers" "1" \
        "pm.max_spare_servers" "2" \
        "chdir" "/var/www/php$PHP_MILESTONE" \
        "catch_workers_output" "yes" \
        "decorate_workers_output" "yes" \
        "clear_env" "yes"

    PHP_FPM_ENV=( "/usr/local/sbin" "/usr/local/bin" "/usr/sbin" "/usr/bin" "/sbin" "/bin" )
    cmd php_patch_config_list "$CONTAINER" "/etc/php/$PHP_MILESTONE/fpm/pool.d/www.conf" \
        "env" \
        "env[HOSTNAME] = \$HOSTNAME" \
        "env[PATH] = $(IFS=:; echo "${PHP_FPM_ENV[*]}")" \
        "env[TMPDIR] = /tmp/php/$PHP_MILESTONE/php-tmp/" \
        "env[XDEBUG_MODE] = \$XDEBUG_MODE" \
        "env[XDEBUG_CONFIG] = \$XDEBUG_CONFIG"

    PHP_FPM_OPEN_BASEDIR=(
        "/var/www/php$PHP_MILESTONE"
        "/usr/share/php/$PHP_MILESTONE/"
        "/tmp/php/$PHP_MILESTONE/"
        "/dev/urandom"
    )
    cmd php_patch_config_list "$CONTAINER" "/etc/php/$PHP_MILESTONE/fpm/pool.d/www.conf" \
        "php(_admin)?_(flag|value)" \
        "php_admin_value[open_basedir] = $(IFS=:; echo "${PHP_FPM_OPEN_BASEDIR[*]}")" \
        "php_admin_value[memory_limit] = 128M"
done

# install PIE (PHP Installer for Extensions)
php_pie_install "$CONTAINER" "latest" "/usr/local/bin/pie-latest"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --install "/usr/local/bin/pie" "pie" \
        "/usr/local/bin/pie-latest" "99"

for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    case "$PHP_MILESTONE" in
        "5.6"|"7.0"|"7.1"|"7.2"|"7.3"|"7.4"|"8.0") continue ;;
        *) ;;
    esac

    echo + "ln -s pie-php $(quote "…/usr/local/bin/pie-php$PHP_MILESTONE")" >&2
    ln -s pie-php "$MOUNT/usr/local/bin/pie-php$PHP_MILESTONE"

    cmd buildah run "$CONTAINER" -- \
        update-alternatives --install "/usr/local/bin/pie" "pie" \
            "/usr/local/bin/pie-php$PHP_MILESTONE" "${PHP_MILESTONE//./}"
done

if [ -e "$MOUNT/usr/local/bin/pie-php$PHP_LATEST_MILESTONE" ]; then
    cmd buildah run "$CONTAINER" -- \
        update-alternatives --set pie "/usr/local/bin/pie-php$PHP_LATEST_MILESTONE"
else
    cmd buildah run "$CONTAINER" -- \
        update-alternatives --auto pie
fi

# install Composer
php_composer_install "$CONTAINER" "latest-stable" "/usr/local/bin/composer-latest"
php_composer_install "$CONTAINER" "latest-2.2.x" "/usr/local/bin/composer-2.2.x"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --install "/usr/local/bin/composer" "composer" \
        "/usr/local/bin/composer-latest" "99"

for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    echo + "ln -s composer-php $(quote "…/usr/local/bin/composer-php$PHP_MILESTONE")" >&2
    ln -s composer-php "$MOUNT/usr/local/bin/composer-php$PHP_MILESTONE"

    cmd buildah run "$CONTAINER" -- \
        update-alternatives --install "/usr/local/bin/composer" "composer" \
            "/usr/local/bin/composer-php$PHP_MILESTONE" "${PHP_MILESTONE//./}"
done

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set composer "/usr/local/bin/composer-php$PHP_LATEST_MILESTONE"

# install PHIVE
php_phive_install "$CONTAINER" "latest" "/usr/local/bin/phive-latest"
php_phive_install "$CONTAINER" "0.15.3" "/usr/local/bin/phive-0.15"
php_phive_install "$CONTAINER" "0.14.5" "/usr/local/bin/phive-0.14"
php_phive_install "$CONTAINER" "0.13.5" "/usr/local/bin/phive-0.13"
php_phive_install "$CONTAINER" "0.12.4" "/usr/local/bin/phive-0.12"
php_phive_install "$CONTAINER" "0.12.1" "/usr/local/bin/phive-0.12.1"

cmd buildah run "$CONTAINER" -- \
    update-alternatives --install "/usr/local/bin/phive" "phive" \
        "/usr/local/bin/phive-latest" "99"

for PHP_MILESTONE in "${PHP_MILESTONES[@]}"; do
    echo + "ln -s phive-php $(quote "…/usr/local/bin/phive-php$PHP_MILESTONE")" >&2
    ln -s phive-php "$MOUNT/usr/local/bin/phive-php$PHP_MILESTONE"

    cmd buildah run "$CONTAINER" -- \
        update-alternatives --install "/usr/local/bin/phive" "phive" \
            "/usr/local/bin/phive-php$PHP_MILESTONE" "${PHP_MILESTONE//./}"
done

cmd buildah run "$CONTAINER" -- \
    update-alternatives --set phive "/usr/local/bin/phive-php$PHP_LATEST_MILESTONE"

# finalize image
cleanup "$CONTAINER"

CONTAINER_ENV=(
    --env PHP_VERSION="$PHP_LATEST_VERSION"
    --env PHP_VERSIONS="$(IFS=' '; echo "${PHP_VERSIONS[*]}")"
    --env PHP_MILESTONE="$PHP_LATEST_MILESTONE"
    --env PHP_MILESTONES="$(IFS=' '; echo "${PHP_MILESTONES[*]}")"
)

for (( i=0 ; i < ${#PHP_MILESTONES[@]} ; i++ )); do
    CONTAINER_ENV+=( --env "PHP${PHP_MILESTONES[i]}_VERSION"="${PHP_VERSIONS[i]}" )
done

cmd buildah config "${CONTAINER_ENV[@]}" "$CONTAINER"

cmd buildah config \
    --volume "/run/mysql" \
    --volume "/run/php-fpm" \
    --volume "/var/log/php" \
    --volume "/var/www" \
    "$CONTAINER"

cmd buildah config \
    --workingdir "/var/www/html" \
    --entrypoint '[ "/entrypoint.sh" ]' \
    --cmd '[ "php-fpm" ]' \
    "$CONTAINER"

cmd buildah config \
    --annotation org.opencontainers.image.title="PHP Development Environment" \
    --annotation org.opencontainers.image.description="A Debian-based PHP development environment running php-fpm." \
    --annotation org.opencontainers.image.version="$PHP_LATEST_VERSION" \
    --annotation org.opencontainers.image.url="https://github.com/SGSGermany/php-dev" \
    --annotation org.opencontainers.image.authors="SGS Serious Gaming & Simulations GmbH" \
    --annotation org.opencontainers.image.vendor="SGS Serious Gaming & Simulations GmbH" \
    --annotation org.opencontainers.image.licenses="MIT" \
    --annotation org.opencontainers.image.base.name="$BASE_IMAGE" \
    --annotation org.opencontainers.image.base.digest="$(podman image inspect --format '{{.Digest}}' "$BASE_IMAGE")" \
    --annotation org.opencontainers.image.created="$(date -u +'%+4Y-%m-%dT%H:%M:%SZ')" \
    "$CONTAINER"

con_commit "$CONTAINER" "$IMAGE" "${TAGS[@]}"
