#!/bin/bash

# This script is running as root by default.
# Switching to the docker user can be done via "gosu docker <command>".

HOME_DIR='/home/docker'

DEBUG=${DEBUG:-0}
# Turn debugging ON when cli is started in the service mode
[[ "$1" == "supervisord" ]] && DEBUG=1
echo-debug ()
{
	[[ "$DEBUG" != 0 ]] && echo "$(date +"%F %H:%M:%S") | $@"
}

uid_gid_reset ()
{
	if [[ "$HOST_UID" != "$(id -u docker)" ]] || [[ "$HOST_GID" != "$(id -g docker)" ]]; then
		echo-debug "Updating docker user uid/gid to $HOST_UID/$HOST_GID to match the host user uid/gid..."
		usermod -u "$HOST_UID" -o docker
		groupmod -g "$HOST_GID" -o "$(id -gn docker)"
	fi
}

xdebug_enable ()
{
	echo-debug "Enabling xdebug..."
	ln -s /opt/docker-php-ext-xdebug.ini /usr/local/etc/php/conf.d/
}

ide_enable ()
{
	echo-debug "Enabling web IDE..."
	ln -s /opt/code-server/supervisord-code-server.conf /etc/supervisor/conf.d/code-server.conf
}

# Creates symlinks to project level overrides if they exist
php_settings ()
{
	php_ini=/var/www/.docksal/etc/php/php.ini
	if [[ -f ${php_ini} ]]; then
		echo-debug "Found project level overrides for PHP. Including:"
		echo-debug "${php_ini}"
		ln -s /var/www/.docksal/etc/php/php.ini /usr/local/etc/php/conf.d/zzz-php.ini
	fi

	php_fpm_conf=/var/www/.docksal/etc/php/php-fpm.conf
	if [[ -f ${php_fpm_conf} ]]; then
		echo-debug "Found project level overrides for PHP-FPM. Including:"
		echo-debug "${php_fpm_conf}"
		ln -s ${php_fpm_conf} /usr/local/etc/php-fpm.d/zzz-php-fpm.conf
	fi
}

add_ssh_key ()
{
	echo-debug "Adding a private SSH key from SECRET_SSH_PRIVATE_KEY..."
	render_tmpl "$HOME_DIR/.ssh/id_rsa"
	chmod 0600 "$HOME_DIR/.ssh/id_rsa"
}

# Helper function to render configs from go templates using gomplate
render_tmpl ()
{
	local file="${1}"
	local tmpl="${1}.tmpl"

	if [[ -f "${tmpl}" ]]; then
		echo-debug "Rendering template: ${tmpl}..."
		gomplate --file "${tmpl}" --out "${file}"
	else
		echo-debug "Error: Template file not found: ${tmpl}"
		return 1
	fi
}

# Helper function to loop through all environment variables prefixed with SECRET_ and
# convert to the equivalent variable without SECRET.
# Example: SECRET_TERMINUS_TOKEN => TERMINUS_TOKEN.
convert_secrets ()
{
	eval 'secrets=(${!SECRET_@})'
	for secret_key in "${secrets[@]}"; do
		key=${secret_key#SECRET_}
		secret_value=${!secret_key}

		# Write new variables to /etc/profile.d/secrets.sh to make them available for all users/sessions
		echo "export ${key}=\"${secret_value}\"" | tee -a "/etc/profile.d/secrets.sh" >/dev/null

		# Also export new variables here
		# This makes them available in the server/php-fpm environment
		eval "export ${key}=${secret_value}"
	done
}

# Acquia Cloud API login
acquia_login ()
{
	echo-debug "Authenticating with Acquia..."
	# This has to be done using the docker user via su to load the user environment
	# Note: Using 'su -l' to initiate a login session and have .profile sourced for the docker user
	local command="drush ac-api-login --email='${ACAPI_EMAIL}' --key='${ACAPI_KEY}' --endpoint='https://cloudapi.acquia.com/v1' && drush ac-site-list"
	local output=$(su -l docker -c "${command}" 2>&1)
	if [[ $? != 0 ]]; then
		echo-debug "ERROR: Acquia authentication failed."
		echo
		echo "$output"
		echo
	fi
}

# Pantheon (terminus) login
terminus_login ()
{
	echo-debug "Authenticating with Pantheon..."
	# This has to be done using the docker user via su to load the user environment
	# Note: Using 'su -l' to initiate a login session and have .profile sourced for the docker user
	local command="terminus auth:login --machine-token='${TERMINUS_TOKEN}'"
	local output=$(su -l docker -c "${command}" 2>&1)
	if [[ $? != 0 ]]; then
		echo-debug "ERROR: Pantheon authentication failed."
		echo
		echo "$output"
		echo
	fi
}

# Git settings
git_settings ()
{
	# These must be run as the docker user
	echo-debug "Configuring git..."
	# Set default git settings if none have been passed
	# See https://github.com/docksal/service-cli/issues/124
	gosu docker git config --global user.email "${GIT_USER_EMAIL:-cli@docksal.io}"
	gosu docker git config --global user.name "${GIT_USER_NAME:-Docksal CLI}"
}

# Inject a private SSH key if provided
[[ "$SECRET_SSH_PRIVATE_KEY" != "" ]] && add_ssh_key

# Convert all Environment Variables Prefixed with SECRET_
convert_secrets

# Docker user uid/gid mapping to the host user uid/gid
[[ "$HOST_UID" != "" ]] && [[ "$HOST_GID" != "" ]] && uid_gid_reset

# Enable xdebug
[[ "$XDEBUG_ENABLED" != "" ]] && [[ "$XDEBUG_ENABLED" != "0" ]] && xdebug_enable

# Enable web IDE
[[ "$IDE_ENABLED" != "" ]] && [[ "$IDE_ENABLED" != "0" ]] && ide_enable

# Include project level PHP settings if found
php_settings

# Make sure permissions are correct (after uid/gid change and COPY operations in Dockerfile)
# To not bloat the image size, permissions on the home folder are reset at runtime.
echo-debug "Resetting permissions on $HOME_DIR and /var/www..."
chown "${HOST_UID:-1000}:${HOST_GID:-1000}" -R "$HOME_DIR"
# Docker resets the project root folder permissions to 0:0 when cli is recreated (e.g. an env variable updated).
# We apply a fix/workaround for this at startup (non-recursive).
chown "${HOST_UID:-1000}:${HOST_GID:-1000}" /var/www

# These have to happen after the home directory permissions are reset,
# otherwise the docker user may not have write access to /home/docker, where the auth session data is stored.
# Acquia Cloud API config
[[ "$ACAPI_EMAIL" != "" ]] && [[ "$ACAPI_KEY" != "" ]] && acquia_login
# Automatically authenticate with Pantheon if Terminus token is present
[[ "$TERMINUS_TOKEN" != "" ]] && terminus_login

# If crontab file is found within project add contents to user crontab file.
if [[ -f ${PROJECT_ROOT}/.docksal/services/cli/crontab ]]; then
	echo-debug "Loading crontab..."
	cat ${PROJECT_ROOT}/.docksal/services/cli/crontab | crontab -u docker -
fi

# Apply git settings
[[ "$GIT_USER_EMAIL" != "" ]] && [[ "$GIT_USER_NAME" != "" ]] && git_settings

# Initialization steps completed. Create a pid file to mark the container as healthy
echo-debug "Preliminary initialization completed."
touch /var/run/cli

# Execute a custom startup script if present
if [[ -x ${PROJECT_ROOT}/.docksal/services/cli/startup.sh ]]; then
	echo-debug "Running custom startup script..."
	# TODO: should we source the script instead?
	su -l docker -c "${PROJECT_ROOT}/.docksal/services/cli/startup.sh"
	if [[ $? == 0 ]]; then
		echo-debug "Custom startup script executed successfully."
	else
		echo-debug "ERROR: Custom startup script execution failed."
	fi
fi

# Execute passed CMD arguments
echo-debug "Passing execution to: $*"
# Service mode (run as root)
if [[ "$1" == "supervisord" ]]; then
	exec gosu root supervisord -c /etc/supervisor/supervisord.conf
# Command mode (run as docker user)
else
	exec gosu docker "$@"
fi
