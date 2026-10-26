#!/bin/bash

#=================================================
# COMMON VARIABLES AND CUSTOM HELPERS
#=================================================

# YunoHost CI does not accept systemd DynamicUser.
# Additionally, on trixie, DynamicUser=yes is broken for cockpit's
# `cockpit.service` (the dynamic user cannot access the wsinstance sockets,
# resulting in HTTP 502 — see issue #46).
# Therefore we always convert DynamicUser=yes units into system users.

# Convert DynamicUser=yes units into system users.
#
# Strategy:
#   * For every cockpit unit file under /usr/lib/systemd/system/ that contains
#     `DynamicUser=yes`, create a drop-in override in
#     /etc/systemd/system/<unit>.d/dynamicuser.conf that sets `DynamicUser=no`.
#     Drop-in files persist across apt upgrades of the cockpit package
#     (unlike direct edits to /usr/lib/systemd/system/<unit>, which apt
#     overwrites with upstream versions).
#   * Create the static users / groups referenced by `User=` / `Group=` so
#     that the services can start once DynamicUser is disabled.
#   * Add the supplementary group memberships that cockpit needs to access
#     its own sockets (e.g. cockpit-systemd-service → cockpit-wsinstance-socket).
#   * Record what was created in app settings so it can be reverted on remove.
myynh_handle_dynamicuser() {
    declare -a created_users=()
    declare -A created_users_set=()
    declare -a created_dropins=()

    # Helper ensuring uniqueness
    add_user_unique() {
        local u="$1"
        [[ -z "$u" ]] && return
        if [[ -z "${created_users_set[$u]+_}" ]]
        then
            created_users+=("$u")
            created_users_set["$u"]=1
        fi
    }

    # Always convert: DynamicUser is known to be broken for cockpit
    # both in YunoHost CI and on trixie (issue #46).
    #
    # We match any unit that has an explicit `DynamicUser=` line (yes OR no).
    # Matching `DynamicUser=no` too is intentional: ynh5 and earlier rewrote
    # `/usr/lib/systemd/system/cockpit*` directly to `DynamicUser=no`, so when
    # upgrading from ynh5 the main unit files already say `DynamicUser=no` and
    # a naive `DynamicUser=yes` check would skip them — leaving no drop-in to
    # survive the next apt upgrade of the cockpit package.
    for f in /usr/lib/systemd/system/cockpit*
    do
        # Skip directories / symlinks / missing entries
        [[ -f "$f" ]] || continue

        # Skip files without any DynamicUser setting
        grep -q '^DynamicUser=' "$f" || continue

        # Unit name (basename of the file)
        local unit_name
        unit_name=$(basename "$f")

        # Extract User= ; if present and missing, create the user and its group.
        # (Done regardless of whether the value is yes/no: once we force
        # DynamicUser=no via the drop-in, the service needs a real user to run as.)
        local user
        user=$(grep -E '^User=' "$f" | head -n1 | cut -d= -f2-)
        if [[ -n "$user" ]]
        then
            if ! ynh_system_user_exists --username="$user"
            then
                ynh_system_user_create --username="$user"
                add_user_unique "$user"
            fi
        fi

        # Extract Group= ; if present and missing, create the user/group
        local group
        group=$(grep -E '^Group=' "$f" | head -n1 | cut -d= -f2-)
        if [[ -n "$group" ]]
        then
            if ! ynh_system_group_exists --group="$group"
            then
                ynh_system_user_create --username="$group"
                add_user_unique "$group"
            fi
        fi

        # Create a drop-in override that disables DynamicUser.
        # /etc/systemd/system/<unit>.d/ is NOT overwritten by apt, so the
        # override survives upgrades of the cockpit package.
        local dropin_dir="/etc/systemd/system/${unit_name}.d"
        local dropin_file="${dropin_dir}/dynamicuser.conf"
        mkdir -p "$dropin_dir"
        cat > "$dropin_file" << 'EOF'
# Managed by YunoHost (cockpit_ynh). Do not edit.
[Service]
DynamicUser=no
EOF
        created_dropins+=("$dropin_file")
    done

    # Add supplementary group memberships required for cockpit to access its
    # own Unix sockets (issue #46).
    #
    # `cockpit.service` runs as User=cockpit-systemd-service Group=cockpit-wsinstance-socket.
    # The wsinstance sockets are owned by root:cockpit-wsinstance-socket (mode 0660).
    # On some trixie setups the Group= directive alone is not enough to grant
    # socket access — adding the user to the group as a supplementary group
    # makes the setup robust.
    if ynh_system_user_exists --username="cockpit-systemd-service" \
        && ynh_system_group_exists --group="cockpit-wsinstance-socket"
    then
        usermod -a -G cockpit-wsinstance-socket cockpit-systemd-service
    fi

    # Reload systemd configuration after modifications
    systemctl daemon-reload

    # Store settings (used by myynh_remove_non_dynamic_users on remove)
    ynh_app_setting_set --key=is_dynamicuser --value=0

    local dynamicusers
    dynamicusers=$(printf "%s;" "${created_users[@]}")
    ynh_app_setting_set --key=dynamicusers --value="$dynamicusers"

    local dropins
    dropins=$(printf "%s;" "${created_dropins[@]}")
    ynh_app_setting_set --key=dynamicuser_dropins --value="$dropins"
}

# Revert what myynh_handle_dynamicuser did: remove drop-in overrides and
# the static users/groups it created. Called by the remove script.
myynh_remove_non_dynamic_users() {
    if [[ "$(ynh_app_setting_get --key=is_dynamicuser)" == "0" ]]
    then
        # Remove drop-in files first and reload systemd so the running
        # units are no longer tied to the static users we are about to delete.
        local dropins
        dropins=$(ynh_app_setting_get --key=dynamicuser_dropins)
        IFS=';' read -r -a dropins <<< "$dropins"
        for d in "${dropins[@]}"
        do
            if [[ -n "$d" && -f "$d" ]]
            then
                rm -f "$d"
                # Remove the directory if it is now empty
                rmdir "$(dirname "$d")" 2>/dev/null || true
            fi
        done

        systemctl daemon-reload

        # Retrieve the user list and convert it back to an array
        local created_users
        created_users=$(ynh_app_setting_get --key=dynamicusers)
        IFS=';' read -r -a created_users <<< "$created_users"

        # Remove each created user (and its homonymous group)
        for u in "${created_users[@]}"
        do
            if [[ -n "$u" ]] && ynh_system_user_exists --username="$u"
            then
                delete_system_user --username="$u"
            fi
        done

        # Clean up app settings
        ynh_app_setting_delete --key=is_dynamicuser
        ynh_app_setting_delete --key=dynamicusers
        ynh_app_setting_delete --key=dynamicuser_dropins
    fi
}

# Delete a system user.
# Fork of ynh_system_user_delete which is now deprecated and gives a linter issue.
#
# usage: delete_system_user --username=user_name
# | arg: --username=    - Name of the system user that will be deleted
delete_system_user() {
    # ============ Argument parsing =============
    local -A args_array=([u]=username=)
    local username
    ynh_handle_getopts_args "$@"
    # ===========================================

    # Check if the user exists on the system
    if ynh_system_user_exists --username="$username"; then
        deluser "$username"
    else
        ynh_print_warn "The user $username was not found"
    fi

    # Check if the group exists on the system
    if ynh_system_group_exists --group="$username"; then
        delgroup "$username"
    fi
}
