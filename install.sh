#!/bin/bash

CSCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
GRASS_DEB_DOWNLOAD_DIR="${CSCRIPT_DIR}/grass_4.26.0_amd64.deb"
GRASS_DOWNLOAD_DIR="${CSCRIPT_DIR}/grass-node"
GRASS_MD5="1216fa71e80f7e4ad3e9591fbd61a984"
GRASS_SHA256="76119d415a021893d033dfc19e7b44cceedbaa7cea5f23a8d56e82abde188cd9"
GRASS_CRC32="cfa14a38"
INSTALL_PREFIX=${INSTALL_PREFIX:-"/usr"}
USER_MODE=${USER_MODE:-0}

if [ "$(id -u)" -ne 0 ]; then
	echo "This installer must not be run as root as it will make changes to file ownership and install files as nessecary on your system." >&2
	exit 1
fi
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
	echo "This script must not be sourced" >&2
	return 1
fi
if [ -n "${SUDO_USER}" ]; then
	USER_NAME=${SUDO_USER}
else
	USER_NAME=${USER_NAME:-$(whoami)}
fi

function __download_gdrive() {
	local _file_id=$1
	if [ -z "${_file_id}" ]; then
		echo "File ID not provided" >&2
		return 1
	fi
	shift 1
	local _output_file=$1
	if [ -z "${_output_file}" ]; then
		echo "Output file not provided" >&2
		return 1
	fi
	if [ -f "${_output_file}" ]; then
		echo "Output file already exists: ${_output_file}" >&2
		return 0
	fi
	local _tmpfile=$(mktemp /tmp/gdrive.XXXXXX)
	local _url=
	local _confirm=$(wget --quiet --save-cookies $_tmpfile --keep-session-cookies --no-check-certificate --content-disposition "https://drive.google.com/uc?export=download&id=${_file_id}" -O-)
	local _conf=$(echo $_confirm | sed -n 's/.*name="id" value="\([^"]*\)".*/\1/p')
	local _uuid=$(echo $_confirm | sed -n 's/.*name="uuid" value="\([^"]*\)".*/\1/p')
	echo "Downloading file: ${_file_id}..."
	wget --quiet --load-cookies $_tmpfile "https://drive.usercontent.google.com/download?id=${_file_id}&export=download&confirm=t&uuid=${_uuid}" -O ${_output_file} || {
		echo "Failed to download file" >&2
		return 1
	}
	return 0
}

function __check_command() {
	if ! command -v $1 &> /dev/null; then
		return 1
	fi
	return 0
}

function __check_file() {
	local _file_path=$1
	if [ -z "${_file_path}" ]; then
		echo "File path not provided" >&2
		return 1
	fi
	if [ ! -f "${_file_path}" ]; then
		echo "File not found: ${_file_path}" >&2
		return 1
	fi
	shift 1
	if [ $# -eq 0 ]; then
		return 0
	fi
	local _md5_checksum=$1
	if [ -n "${_md5_checksum}" ]; then
		if ! __check_command md5sum; then
			echo "md5sum utility not found, could not verify checksum of file" >&2
			return 1
		fi
		if [ "$(md5sum ${_file_path} | awk '{print $1}')" != "${_md5_checksum}" ]; then
			echo "MD5 checksum does not match" >&2
			return 1
		fi
	fi
	shift 1
	if [ $# -eq 0 ]; then
		return 0
	fi
	local _sha256_checksum=$1
	if [ -n "${_sha256_checksum}" ]; then
		if ! __check_command sha256sum; then
			echo "sha256sum utility not found, could not verify checksum of file" >&2
			return 1
		fi
		if [ "$(sha256sum ${_file_path} | awk '{print $1}')" != "${_sha256_checksum}" ]; then
			echo "SHA256 checksum does not match" >&2
			return 1
		fi
	fi
	shift 1
	if [ $# -eq 0 ]; then
		return 0
	fi
	local _crc32_checksum=$1
	if [ -n "${_crc32_checksum}" ]; then
		if ! __check_command crc32; then
			echo "crc32 utility not found, could not verify checksum of file" >&2
			return 1
		fi
		if [ "$(crc32 ${_file_path} | awk '{print $1}')" != "${_crc32_checksum}" ]; then
			echo "CRC32 checksum does not match" >&2
			return 1
		fi
	fi
	shift 1
	return 0
}

function __extract_deb_package() {
	local _deb_file=$1
	local _target_dir=$2
	if [ -z "${_deb_file}" ] || [ -z "${_target_dir}" ]; then
		echo "Usage: __extract_deb_package <deb_file> <target_dir>" >&2
		return 1
	fi
	if [ ! -f "${_deb_file}" ]; then
		echo "File not found: ${_deb_file}" >&2
		return 1
	fi
	if [ ! -d "${_target_dir}" ]; then
		if ! mkdir -p "${_target_dir}"; then
			echo "Failed to create target directory: ${_target_dir}" >&2
			return 1
		fi
	fi
	if ! __check_command ar; then
		echo "ar command not found" >&2
		return 1
	fi
	if ! __check_command tar; then
		echo "tar command not found" >&2
		return 1
	fi
	pushd "${_target_dir}" &>/dev/null || return 1
	ar x "${_deb_file}" || {
		echo "Failed to extract ${_deb_file} package" >&2
		return 1
	}
	tar -xf control.tar.* || {
		echo "Failed to extract control.tar.*" >&2
		return 1
	}
	tar -xf data.tar.* || {
		echo "Failed to extract data.tar.*" >&2
		return 1
	}
	rm control.tar.* data.tar.* || {
		echo "Failed to remove control.tar.* data.tar.*" >&2
		return 1
	}
	popd &>/dev/null || return 1
	echo "Package extracted to ${_target_dir}"
	return 0
}

function __install_files() {
    local _base_folder=$1
    shift 1
    local _destination_folder=$1
    if [ -z "${_destination_folder}" ]; then
        echo "Destination folder not provided" >&2
        return 1
    fi
    shift 1
    local _usermode
	_usermode=$1
    if [ -z "${_usermode}" ]; then
		_usermode=0
	fi
    shift 1
    if [ -z "${_base_folder}" ]; then
        echo "Base folder not provided" >&2
        return 1
    fi
    if [ ! -d "${_base_folder}" ]; then
        echo "Base folder not found: ${_base_folder}" >&2
        return 1
    fi
    if [ ! -d "${_destination_folder}" ]; then
        if ! mkdir -p "${_destination_folder}"; then
            echo "Failed to create destination folder: ${_destination_folder}" >&2
            return 1
        fi
    fi
    find "${_base_folder}/usr" -type d | while read -r dir; do
        dest_dir="${_destination_folder}${dir#${_base_folder}/usr}"
        if [ ! -d "${dest_dir}" ]; then
            mkdir -p "${dest_dir}"
        fi
    done
    find "${_base_folder}/usr" -type f | while read -r file; do
        dest_file="${_destination_folder}${file#${_base_folder}/usr}"
        cp "${file}" "${dest_file}" || {
            echo "Failed to copy ${file} to ${dest_file}" >&2
            return 1
        }
        if [ $_usermode -eq 1 ]; then
            chown $(whoami):$(whoami) "${dest_file}" || {
                echo "Failed to change ownership of ${dest_file}" >&2
                return 1
            }
        fi
		chmod 0755 "${dest_file}" || {
			echo "Failed to change permissions of ${dest_file}" >&2
			return 1
		}
    done
    echo "Files copied to ${_destination_folder}"
	if ! __check_command update-desktop-database; then
		echo -e "update-desktop-database utility not found, please update your xdg-utils package and run:\n\nupdate-desktop-database ~/.local/share/applications if you'd like grass to be in your session menu." >&2
	else
		# run the command as the user
		/bin/su -c "update-desktop-database ~/.local/share/applications" -s /bin/bash $USER_NAME || {
			echo "Failed to update desktop database" >&2
			return 1
		}
	fi
    echo "Fetching dependencies..."
    if [ -f "${_base_folder}/control" ]; then
        local _control_file
		_control_file=$(cat "${_base_folder}/control")
        declare -a _depends_array=($(echo "$_control_file" | sed -n 's/^Depends: //p' | tr ', ' '\n' | tr '\n' ' '))
        echo -e "The following dependencies are required:\n"
        for _dep in "${_depends_array[@]}"; do
            echo " - ${_dep}"
        done
        echo -e "\nPlease install the dependencies manually using your system's package manager"
    fi
}

__download_gdrive "1acd81bX1Gv8JOU_NqzYkxcg_76H9CGUW" "${GRASS_DEB_DOWNLOAD_DIR}" || exit $?
__check_file "${GRASS_DEB_DOWNLOAD_DIR}" "${GRASS_MD5}" "${GRASS_SHA256}" "${GRASS_CRC32}" || exit $?
__extract_deb_package "${GRASS_DEB_DOWNLOAD_DIR}" "${GRASS_DOWNLOAD_DIR}" || exit $?
__install_files "${GRASS_DOWNLOAD_DIR}" "${INSTALL_PREFIX}" "${USER_MODE}" || exit $?