#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

pnpm_version="11.5.2"

__get_enrollment_code() {
    local max_attempts=5
    local attempt=1
    local enrollment_code=""

    while [ $attempt -le $max_attempts ]; do
        enrollment_code=$(journalctl -u "$app" -n 50 -r --no-pager | grep -m 1 -oP 'enrollment code \(10 minutes\): \K[a-zA-Z0-9-]+')
        
        if [ -n "$enrollment_code" ]; then
            break
        fi
        
        sleep 1
        ((attempt++))
    done

    if [ -z "$enrollment_code" ]; then
        echo "Error: Enrollment token not found in logs." >&2
        return 1
    fi

    echo "$enrollment_code"
    ynh_app_setting_set --key=enrollment_code --value="$enrollment_code"
    ynh_replace --match="__ENROLLMENT_CODE__" --replace="$enrollment_code" --file="/etc/yunohost/apps/$app/doc/ADMIN.md"
    ynh_replace --match="__ENROLLMENT_CODE__" --replace="$enrollment_code" --file="/etc/yunohost/apps/$app/doc/POST_INSTALL.md"

    return 0
}

__trigger_and_capture_signup() {
    local max_attempts=15
    local attempt=1
    
    invite_link=""
    enrollment_code=""

    local start_time=$(date +"%Y-%m-%d %H:%M:%S")

    local payload
    if [[ "$target_relay" == "https://nine.testrun.org" ]]; then
        payload=$(cat <<EOF
{
  "display_name": "$display_name",
  "relay": "$target_relay"
}
EOF
)
    else
        local custom_relay_enrollment_code=$(journalctl -u "$app" --no-pager | grep -oP 'one-time frontend enrollment code \(10 minutes\): \K[a-zA-Z0-9_-]+' | tail -n 1)

        payload=$(cat <<EOF
{
  "display_name": "$display_name",
  "relay": "$target_relay",
  "enrollment_code": "$custom_relay_enrollment_code"
}
EOF
)
    fi

    echo "Firing account creation API request..." >&2

    local http_response=$(curl -s -k -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://$domain/api/headwater/signup")

    if [[ "$http_response" != "200" && "$http_response" != "201" ]]; then
        echo "Error: Signup API rejected request with status code: $http_response" >&2
        return 1
    fi

    while [ $attempt -le $max_attempts ]; do
        local log_chunk=$(journalctl -u "$app" --since "$start_time" --no-pager)

        unescaped_invite_link=$(echo "$log_chunk" | grep -oP 'your feed invite: \Khttps://[^\s]+' | tail -n 1)
        invite_link=$(echo "$unescaped_invite_link" | sed 's/[\&]/\\&/g')
        enrollment_code=$(echo "$log_chunk" | grep -oP 'one-time frontend enrollment code \(10 minutes\): \K[a-zA-Z0-9_-]+' | tail -n 1)

        if [ -n "$enrollment_code" ] && [ -n "$unescaped_invite_link" ]; then
            break
        fi

        sleep 1
        ((attempt++))
    done

    if [ -z "$enrollment_code" ] || [ -z "$invite_link" ]; then
        echo "Error: Timed out waiting for downstream credentials in logs." >&2
        return 1
    fi

    ynh_app_setting_set --key=enrollment_code --value="$enrollment_code"
    ynh_app_setting_set --key=invite_link --value="$unescaped_invite_link"
    ynh_replace --match="__ENROLLMENT_CODE__" --replace="$enrollment_code" --file="/etc/yunohost/apps/$app/doc/ADMIN.md"
    ynh_replace --match="__INVITE_LINK__" --replace="$invite_link" --file="/etc/yunohost/apps/$app/doc/ADMIN.md"

    return 0
}