#!/usr/bin/env bash

# getgrass: Install Grass on Any Linux!
#

if [ "$(id -u)" -ne 0 ]; then
	echo "This installer must be run as root as it will make changes to file ownership and install files as necessary on your system." >&2
	exit 1
fi
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
	echo "This script must not be sourced" >&2
	exit 1
fi
if [ -n "${SUDO_USER}" ]; then
	USER_NAME=${SUDO_USER:-${USER}}
else
	USER_NAME=$(logname 2>/dev/null || echo ${SUDO_USER:-${USER}})
fi

CSCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ACTION=""
CONFIG_FILE=${CONFIG_FILE:-"manifest.json"}
INSTALL_PREFIX=${INSTALL_PREFIX:-"/usr"}
CACHE_DIR=${CACHE_DIR:-"${CSCRIPT_DIR}/.grass-install"}
USER_MODE=${USER_MODE:-0}
DEBUG=${DEBUG:-0}
LOGGING=${LOGGING:-1}
QUIET=${QUIET:-0}
LOG_FILE=${LOG_FILE:-"/var/log/grass-install.log"}
LOGO=${LOGO:-1}
DRY_RUN=${DRY_RUN:-0}

# Colors
C_RED=$(tput setaf 1)
C_GREEN=$(tput setaf 2)
C_YELLOW=$(tput setaf 3)
C_BLUE=$(tput setaf 4)
C_MAGENTA=$(tput setaf 5)
C_CYAN=$(tput setaf 6)
C_WHITE=$(tput setaf 7)
C_GRAY=$(tput setaf 8)
C_RESET=$(tput sgr0)
C_BOLD=$(tput bold)
C_UNDERLINE=$(tput smul)

####################################################################################################
# DeLib logging library
####################################################################################################

function __strip_ansi() {
	sed -r "s/\x1B\[[0-9;]*[JKmsu]//g" <<<"$1"
}
function __log() {
	local _logstr _logstr_noansi _loglevel
	_loglevel=$1
	if [ -z "${_loglevel}" ]; then
		_loglevel="INFO"
	fi
	shift 1
	declare -a _fd=()
	IFS=$'\n' mapfile -t _fd <<<"$*"
	for _line in "${_fd[@]}"; do
		_logstr=$(__strip_ansi "${_line}")
		case "${_loglevel}" in
			"INFO")
				_logstr="${C_CYAN}[${C_BOLD}INFO   ${C_RESET}${C_CYAN}] ${_logstr}${C_RESET}"
				;;
			"WARN")
				_logstr="${C_YELLOW}[${C_BOLD}WARN   ${C_RESET}${C_YELLOW}] ${_logstr}${C_RESET}"
				;;
			"ERROR")
				_logstr="${C_RED}[${C_BOLD}ERROR ${C_RESET}${C_RED}] ${_logstr}${C_RESET}"
				;;
			"SUCCESS")
				_logstr="${C_GREEN}[${C_BOLD}SUCCESS${C_RESET}${C_GREEN}] ${_logstr}${C_RESET}"
				;;
			"DEBUG")
				_logstr="${C_MAGENTA}[${C_BOLD}DEBUG  ${C_RESET}${C_MAGENTA}] ${_logstr}${C_RESET}"
				;;
			*)
				_logstr="${C_CYAN}[${C_BOLD}INFO   ${C_RESET}${C_CYAN}] ${_logstr}${C_RESET}"
				;;
		esac
		if [ ${QUIET} -eq 0 ]; then
			if [ ${DEBUG} -eq 1 ] && [ "${_loglevel}" == "DEBUG" ]; then
				echo -e "${_logstr}" >&2
			elif [ "${_loglevel}" != "DEBUG" ]; then
				if [ "${_loglevel}" == "ERROR" ]; then
					echo -e "${_logstr}" >&2
				else
					echo -e "${_logstr}"
				fi
			fi
		fi
		if [ ${LOGGING} -eq 1 ]; then
			echo -e "$(date -I) ${_logstr}" >>"${LOG_FILE}"
		fi
	done
}
function __info() {
	__log "INFO" "$1"
}
function __warn() {
	__log "WARN" "$1"
}
function __error() {
	__log "ERROR" "$1"
}
function __success() {
	__log "SUCCESS" "$1"
}
function __debug() {
	__log "DEBUG" "$1"
}
function _exit_trap() {
	local _exit_code=$?
	if [ ${_exit_code} -eq 0 ]; then
		__success "Installation completed successfully"
	else
		__error "Installation failed with exit(${_exit_code}).  Please use the log located at: ${LOG_FILE} when submitting a bug report."
	fi
	return ${_exit_code}
}
trap _exit_trap EXIT ERR SIGINT SIGTERM

####################################################################################################
# DeLib Core library
####################################################################################################

function __check_command() {
	if ! command -v "$1" &> /dev/null; then
		if [ ! -f "$(which "$1" 2>/dev/null)" ]; then
			__debug "$1 command not found"
			return 1
		fi
	fi
	if [ ! -x "$(command -v "$1")" ]; then
		if [ ! -x "$(which "$1" 2>/dev/null)" ]; then
			__debug "$1 command not executable"
			return 1
		fi
	fi
	return 0
}
function __run_command() {
	local _command=$1
	if [ -z "${_command}" ]; then
		__error "Command not provided"
		return 1
	fi
	shift 1
	declare -a _args=($*)
	__debug "Running command: ${_command} ${_args[*]}"
	LASTEXITCODE=0
	local _std=$(mktemp /tmp/std.XXXXXX)
	eval "${_command} ${_args[*]}" &> "${_std}" || {
		LASTEXITCODE=$?
		declare -a _std_out=()
		IFS=$'\n' mapfile -t _std_out < "${_std}"
		for _line in "${_std_out[@]}"; do
			_logstr=$(__strip_ansi "${_line}")
			__error "${_logstr}"
		done
		__debug "Command: ${_command} ${_args[*]} failed with exit code: ${LASTEXITCODE}"
		rm -f "${_std}" &>/dev/null
		return $?
	}
	declare -a _std_out=()
	IFS=$'\n' mapfile -t _std_out < "${_std}"
	for _line in "${_std_out[@]}"; do
		__debug "${_line}"
	done
	__debug "Command: ${_command} ${_args[*]} completed successfully"
	rm -f "${_std}" &>/dev/null
	return 0
}
function __os_flavor() {
	if [ -f /etc/os-release ]; then
		__os_flavor=$(. /etc/os-release && echo "${ID}")
	elif [ -f /etc/lsb-release ]; then
		__os_flavor=$(. /etc/lsb-release && echo "${DISTRIB_ID}")
	else
		echo "unknown"
	fi
}
function __os_version() {
	local _os_version
	if [ -f /etc/os-release ]; then
		_os_version=$(. /etc/os-release && echo "${VERSION_ID}")
	elif [ -f /etc/lsb-release ]; then
		_os_version=$(. /etc/lsb-release && echo "${DISTRIB_RELEASE}")
	else
		echo "unknown"
		return 1
	fi
	echo "${_os_version}"
	return 0
}
function __os_arch() {
	local _os_arch
	_os_arch=$(uname -m)
	echo "${_os_arch}"
	return 0
}

####################################################################################################
# DeiLib installer manifest library
####################################################################################################

function __download_file_gdrive() {
	local _file_id=$1
	if [ -z "${_file_id}" ]; then
		__error "File ID not provided"
		return 1
	fi
	shift 1
	local _output_file=$1
	if [ -z "${_output_file}" ]; then
		__error "Output file not provided"
		return 1
	fi
	if [ -f "${_output_file}" ]; then
		__warn "Output file already exists: ${_output_file}"
		return 0
	fi
	local _tmpfile _url _confirm _conf _uuid _download_dir
	_tmpfile=$(mktemp /tmp/gdrive.XXXXXX) 
	_confirm=$(wget --quiet --save-cookies "${_tmpfile}" --keep-session-cookies --no-check-certificate --content-disposition "https://drive.google.com/uc?export=download&id=${_file_id}" -O-)
	_conf=$(echo "${_confirm}" | sed -n 's/.*name="id" value="\([^"]*\)".*/\1/p')
	_uuid=$(echo "${_confirm}" | sed -n 's/.*name="uuid" value="\([^"]*\)".*/\1/p')
	_download_dir="${_output_file%/*}"
	if [ ! -d "${_download_dir}" ]; then
		if ! mkdir -p "${_download_dir}"; then
			__error "Failed to create download destination directory: ${_download_dir}"
			return 1
		fi
	fi
	wget --quiet --load-cookies "${_tmpfile}" "https://drive.usercontent.google.com/download?id=${_file_id}&export=download&confirm=t&uuid=${_uuid}" -O ${_output_file} || {
		__error "Failed to download file"
		return 1
	}
	rm -f "${_tmpfile}" || {
		__warn "Failed to remove temporary file: ${_tmpfile}"
	}
	__success "File downloaded to: ${_output_file}"
	return 0
}
function __download_file_direct() {
	local _file_url=$1
	if [ -z "${_file_url}" ]; then
		__error "File URL not provided"
		return 1
	fi
	shift 1
	local _output_file=$1
	if [ -z "${_output_file}" ]; then
		__error "Output file not provided"
		return 1
	fi
	if [ -f "${_output_file}" ]; then
		__warn "Output file already exists: ${_output_file}"
		return 0
	fi
	_download_dir="${_output_file%/*}"
	if [ ! -d "${_download_dir}" ]; then
		if ! mkdir -p "${_download_dir}"; then
			__error "Failed to create download destination directory: ${_download_dir}"
			return 1
		fi
	fi
	__info "Downloading file: ${_file_url}..."
	wget --quiet --no-check-certificate "${_file_url}" -O "${_output_file}" || {
		__error "Failed to download file"
		return 1
	}
	__success "File downloaded to: ${_output_file}"
	return 0
}
function __checksum_file() {
	local _file_path=$1
	if [ -z "${_file_path}" ]; then
		__error "File path not provided"
		return 1
	fi
	if [ ! -f "${_file_path}" ]; then
		__error "File not found: ${_file_path}"
		return 1
	fi
	shift 1
	if [ $# -eq 0 ]; then
		__error "Checksums type argument missing"
		return 1
	fi
	local _checksum_type=$1
	if [ -z "${_checksum_type}" ]; then
		__error "Checksum type not provided"
		return 1
	fi
	if [ "${_checksum_type}" != "md5" ] && [ "${_checksum_type}" != "sha256" ] && [ "${_checksum_type}" != "crc32" ]; then
		__error "Invalid checksum type: ${_checksum_type}"
		return 1
	fi
	shift 1
	if [ $# -eq 0 ]; then
		__error "Checksum value argument missing"
		return 1
	fi
	local _checksum=$1
	if [ -z "${_checksum}" ]; then
		__error "Checksum value not provided"
		return 1
	fi
	shift 1
	case "${_checksum_type}" in
		"md5")
			if ! __check_command md5sum; then
				__error "md5sum utility not found, could not verify checksum of file, please install the coreutils package."
				return 1
			fi
			if [ "$(md5sum ${_file_path} | awk '{print $1}')" != "${_checksum}" ]; then
				__error "MD5 checksum does not match given: $(md5sum ${_file_path} | awk '{print $1}') expected: ${_checksum}"
				return 1
			fi
			;;
		"sha256")
			if ! __check_command sha256sum; then
				__error "sha256sum utility not found, could not verify checksum of file.  Please install the coreutils package."
				return 1
			fi
			if [ "$(sha256sum ${_file_path} | awk '{print $1}')" != "${_checksum}" ]; then
				__error "SHA256 checksum does not match given: $(sha256sum ${_file_path} | awk '{print $1}') expected: ${_checksum}"
				return 1
			fi
			;;
		"crc32")
			if ! __check_command crc32; then
				__error "crc32 utility not found, could not verify checksum of file"
				return 1
			fi
			if [ "$(crc32 ${_file_path} | awk '{print $1}')" != "${_checksum}" ]; then
				__error "CRC32 checksum does not match given: $(crc32 ${_file_path} | awk '{print $1}') expected: ${_checksum}"
				return 1
			fi
			;;
		*)
			__error "Invalid checksum type: ${_checksum_type}"
			return 1
			;;
	esac
	__success "File: ${_file_path} checksums verified successfully"
	return 0
}
function __extract_deb_package() {
	local _deb_file=$1
	local _target_dir=$2
	if [ -z "${_deb_file}" ] || [ -z "${_target_dir}" ]; then
		__error "Usage: __extract_deb_package <deb_file> <target_dir>"
		return 1
	fi
	if [ ! -f "${_deb_file}" ]; then
		__error "File not found: ${_deb_file}"
		return 1
	fi
	if [ ! -d "${_target_dir}" ]; then
		if ! mkdir -p "${_target_dir}"; then
			__error "Failed to create target directory: ${_target_dir}"
			return 1
		fi
	fi
	if ! __check_command ar; then
		__error "ar command not found"
		return 1
	fi
	if ! __check_command tar; then
		__error "tar command not found"
		return 1
	fi
	pushd "${_target_dir}" &>/dev/null || return 1
	__run_command ar x "${_deb_file}" || {
		__error "Failed to extract ${_deb_file} package"
		return 1
	}
	__run_command tar -xf control.tar.* || {
		__error "Failed to extract control.tar.*"
		return 1
	}
	__run_command tar -xf data.tar.* || {
		__error "Failed to extract data.tar.*"
		return 1
	}
	__run_command rm control.tar.* data.tar.* || {
		__error "Failed to remove control.tar.* data.tar.*"
		return 1
	}
	popd &>/dev/null || return 1
	__success "Package extracted to ${_target_dir}"
	return 0
}
function __install_files() {
    local _base_folder=$1
    shift 1
    local _destination_folder=$1
    if [ -z "${_destination_folder}" ]; then
        __error "Destination folder not provided"
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
        __error "Base folder not provided"
        return 1
    fi
    if [ ! -d "${_base_folder}" ]; then
        __error "Base folder not found: ${_base_folder}"
        return 1
    fi
    if [ ! -d "${_destination_folder}" ]; then
		if [ $DRY_RUN -eq 1 ]; then
			__info "DRY RUN: Would have created destination folder: ${_destination_folder}"
		else 
			if ! mkdir -p "${_destination_folder}"; then
				__error "Failed to create destination folder: ${_destination_folder}"
				return 1
			fi
		fi
    fi
    find "${_base_folder}/usr" -type d | while read -r dir; do
        dest_dir="${_destination_folder}${dir#${_base_folder}/usr}"
		if [ ! -d "${dest_dir}" ]; then
			if [ $DRY_RUN -eq 1 ]; then
				__info "DRY RUN: Would have created folder: ${dest_dir}"
			else
				mkdir -p "${dest_dir}" || {
					__error "Failed to create folder: ${dest_dir}"
				}
			fi
		fi
    done
    find "${_base_folder}/usr" -type f | while read -r file; do
        dest_file="${_destination_folder}${file#${_base_folder}/usr}"
		if [ ! -f "${dest_file}" ]; then
			if [ $DRY_RUN -eq 1 ]; then
				__info "DRY RUN: Would have copied ${file} to ${dest_file}"
			else
				__run_command cp ${file} ${dest_file} || {
					__error "Failed to copy ${file} to ${dest_file}"
					return 1
				}
			fi
		else
			if [ $DRY_RUN -eq 1 ]; then
				__info "DRY RUN: Would have overwritten ${dest_file}"
			else
				__run_command cp -f ${file} ${dest_file} || {
					__error "Failed to overwrite ${file} to ${dest_file}"
					return 1
				}
			fi
		fi
        if [ $_usermode -eq 1 ]; then
			if [ $DRY_RUN -eq 1 ]; then
				__info "DRY RUN: Would have changed ownership of ${dest_file} to ${USER_NAME}:${USER_NAME}"
			else
				__run_command chown ${USER_NAME}:${USER_NAME} "${dest_file}" || {
					__error "Failed to change ownership of ${dest_file}"
					return 1
				}
			fi
        fi
		if [ $DRY_RUN -eq 1 ]; then
			__info "DRY RUN: Would have changed permissions of ${dest_file} to 0755"
		else
			__run_command chmod 0755 "${dest_file}" || {
				__error "Failed to change permissions of ${dest_file}"
				return 1
			}
		fi
    done
    __success "Files copied to ${_destination_folder} successfully"
	return 0
}
function __install_cert() {
	local _cert_file=$1
	if [ -z "${_cert_file}" ]; then
		__error "Certificate file not provided"
		return 1
	fi
	if [ ! -f "${_cert_file}" ]; then
		__error "Certificate file not found: ${_cert_file}"
		return 1
	fi
	if ! __check_command update-ca-certificates; then
		__error "update-ca-certificates command not found, your system is missing the equivilent ca-certificates package.  Please install the ca-certificates package to continue."
		return 1
	fi
	if ! __check_command c_rehash; then
		__error "c_rehash command not found, your system is missing the equivilent ca-certificates package.  Please install the ca-certificates package to continue."
		return 1
	fi
	if [ ${DRY_RUN} -eq 1 ]; then
		__info "DRY RUN: Would have copied certificate file: ${_cert_file} to /etc/ssl/certs/"
		__info "DRY RUN: Would have updated certificate hash in /etc/ssl/certs/"
		__info "DRY RUN: Would have updated certificate store"
		return 0
	fi
	__run_command cp "${_cert_file}" /etc/ssl/certs/ || {
		__error "Failed to copy certificate file to /etc/ssl/certs/"
		return 1
	}
	__run_command c_rehash /etc/ssl/certs/ || {
		__error "Failed to update certificate hash"
		return 1
	}
	__run_command update-ca-certificates || {
		__error "Failed to update certificate store"
		return 1
	}
	__success "Certificate installed successfully"
}
function __uninstall_files() {
	local _base_folder _destination_folder
	_base_folder=$1
	if [ -z "${_base_folder}" ]; then
		__error "Base folder not provided"
		return 1
	fi
	if [ ! -d "${_base_folder}" ]; then
		__error "Base folder not found: ${_base_folder}"
		return 1
	fi
	shift 1
	_destination_folder=$1
	if [ ! -d "${_destination_folder}" ]; then
		__error "Destination folder not found: ${_destination_folder}"
		return 1
	fi
	shift 1
	find "${_base_folder}/usr" -type f | while read -r file; do
		dest_file="${_destination_folder}${file#${_base_folder}/usr}"
		if [ ! -f "${dest_file}" ]; then
			__warn "File not found: ${dest_file}, skipping"
			continue
		fi
		if [ ${DRY_RUN} -eq 1 ]; then
			__info "DRY RUN: Would have removed file: ${dest_file}"
			continue
		fi
		__run_command rm -f "${dest_file}" || {
			__error "Failed to remove file: ${dest_file}"
			return 1
		}
	done
	__success "Files removed successfully"
	return 0
}
function __uninstall_cert() {
	local _cert_file=$1
	if [ -z "${_cert_file}" ]; then
		__error "Certificate file not provided"
		return 1
	fi
	if [ ! -f "${_cert_file}" ]; then
		__error "Certificate file not found: ${_cert_file}"
		return 1
	fi
	if ! __check_command update-ca-certificates; then
		__error "update-ca-certificates command not found, your system is missing the equivilent ca-certificates package.  Please install the ca-certificates package to continue."
		return 1
	fi
	if ! __check_command c_rehash; then
		__error "c_rehash command not found, your system is missing the equivilent ca-certificates package.  Please install the ca-certificates package to continue."
		return 1
	fi
	if [ ${DRY_RUN} -eq 1 ]; then
		__info "DRY RUN: Would have removed certificate file: /etc/ssl/certs/$(basename "${_cert_file}")"
		__info "DRY RUN: Would have updated certificate hash in /etc/ssl/certs/"
		__info "DRY RUN: Would have updated certificate store"
		return 0
	fi
	__run_command rm -f /etc/ssl/certs/$(basename "${_cert_file}") || {
		__error "Failed to remove certificate file: ${_cert_file}"
		return 1
	}
	__run_command c_rehash /etc/ssl/certs/ || {
		__error "Failed to update certificate hash"
		return 1
	}
	__run_command update-ca-certificates || {
		__error "Failed to update certificate store"
		return 1
	}
	__success "Certificate removed successfully"
}
function __update_desktop_database() {
	if ! __check_command update-desktop-database; then
		__warn "update-desktop-database utility not found, please update your xdg-utils package and run:\n\nupdate-desktop-database ~/.local/share/applications if you'd like grass to be in your session menu."
		return 0
	else
		__info "Updating ${USER_NAME}'s X desktop database..."
		if [ ${DRY_RUN} -eq 1 ]; then
			__info "DRY RUN: Would have updated ${USER_NAME}'s Xdesktop database"
			return 0
		fi
		__run_command "$(which su) -s $(which bash) $USER_NAME -c \"update-desktop-database /home/${USER_NAME}/.local/share/applications\"" || {
			__error "Failed to update ${USER_NAME}'s Xdesktop database"
			return 1
		}
	fi
	__success "Desktop database updated successfully"
	return 0
}
function __display_dependencies() {
	local _base_folder=$1
	if [ -z "${_base_folder}" ]; then
		__error "Base folder not provided"
		return 1
	fi
	if [ ! -d "${_base_folder}" ]; then
		__error "Base folder not found: ${_base_folder}"
		return 1
	fi
	local _control_file
	_control_file=$(cat "${_base_folder}/control")
	declare -a _depends_array=($(echo "$_control_file" | sed -n 's/^Depends: //p' | tr ', ' '\n' | tr '\n' ' '))
	__info "The following dependencies are required:"
	for _dep in "${_depends_array[@]}"; do
		__info " - ${_dep}"
	done
	__info "Please install the dependencies manually using your system's package manager"
}
function __process_node() {
    local _node_name=$1
    if [ -z "${_node_name}" ]; then
        __error "File name not provided"
        return 1
    fi
    shift 1
    local _config_json=$1
    if [ -z "${_config_json}" ]; then
        __error "Manifest JSON not provided"
        return 1
    fi
    declare -a _actions
    echo "${_config_json}" | jq '.' &>/dev/null || {
        __error "Invalid JSON provided for file: ${_file_name}"
        return 1
    }
	shift 1
	declare -a _actions
    mapfile -t _actions <<<"$(echo "${_config_json}" | jq -r '.actions[] | .name')"
    if [ -z "${_actions[*]}" ] || [ ${#_actions[@]} -eq 0 ]; then
        __error "No actions found in manifest for node: ${_node_name}"
        return 1
    fi
	local _index
	_index=0
    for _action in "${_actions[@]}"; do
        local _name _args _action_json
		_action_json=$(echo "${_config_json}" | jq -r --arg index "${_index}" '.actions[($index|tonumber)]')
		_name=$(echo "${_action_json}" | jq -r '.name')
		_args_json=$(echo "${_action_json}" | jq -r '.args')
		__debug "Processing action: ${_name} with args: ${_args_json}"
        case "${_name}" in
            "download")
                local _type _file_id
				_type=$(echo "${_args_json}" | jq -r '.type')
				_output_file="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.filename')"
				_file_name=$(basename "${_output_file}")
				_file_id=$(echo "${_args_json}" | jq -r '.file_id')
				if [ "${_type}" == "gdrive" ]; then
					__info "Downloading file: ${_file_name} using gdrive method to ${_output_file}..."
					__download_file_gdrive "${_file_id}" "${_output_file}" || return $?
				else
					__error "Unsupported download type: ${_type}"
					return 1
				fi
				;;
            "check")
                local _checksum_type _value _output_file
				_checksum_type=$(echo "${_args_json}" | jq -r '.type')
                _value=$(echo "${_args_json}" | jq -r '.value')
				_output_file="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.filename')"
                __info "Checking file: ${_output_file}..."
                __checksum_file "${_output_file}" "${_checksum_type}" "${_value}" || return $?
                ;;
            "extract_deb")
                local _destination_dir _output_file _source_dir
				_destination_dir="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.destination_folder')"
				_output_file="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.filename')"
                __info "Extracting deb package: ${_output_file} to ${_destination_dir}..."
                __extract_deb_package "${_output_file}" "${_destination_dir}" || return $?
                ;;
            "install_folder")
                local _source_dir
				_source_dir="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.source_folder')"
                __info "Installing deb package folder: ${_source_dir} to ${INSTALL_PREFIX}..."
                __install_files "${_source_dir}" "${INSTALL_PREFIX}" "${USER_MODE}" || return $?
                ;;
            "install_cert")
				local _output_file
				_output_file="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.filename')"
                __info "Installing certificate: ${_output_file}..."
                __install_cert "${_output_file}" || return $?
                ;;
			"uninstall_folder")
				local _source_dir
				_source_dir="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.source_folder')"
				__info "Uninstalling via deb package cache folder: ${_source_dir}..."
				__uninstall_files "${_source_dir}" "${INSTALL_PREFIX}" || return $?
				;;
			"uninstall_cert")
				local _output_file
				_output_file="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.filename')"
				__info "Uninstalling certificate: ${_output_file}..."
				__uninstall_cert "${_output_file}" || return $?
				;;
            "update_desktop_database")
                __info "Updating desktop database..."
                __update_desktop_database || return $?
                ;;
            "display_dependencies")
                local _source_dir
				_source_dir="${CACHE_DIR}/$(echo "${_args_json}" | jq -r '.source_folder')"
                __display_dependencies "${_source_dir}" || return $?
                ;;
            *)
                __error "Invalid action: ${_name}"
                return 1
                ;;
        esac
		_index=$((_index + 1))
    done
}
function __process_manifest() {
    local _manifest_file _action _manifest_json
	_manifest_file="$1"
    if [ -z "${_manifest_file}" ]; then
        echo "Manifest file not provided" >&2
        return 1
    fi
    if [ ! -f "${_manifest_file}" ]; then
        echo "Manifest file not found: ${_manifest_file}" >&2
        return 1
    fi
	shift 1
	_manifest_action="$1"
	if [ -z "${_manifest_action}" ]; then
		__error "Action not provided, please run -h | --help for usage information"
		return 1
	fi
	if ! __check_command jq; then
		__error "jq binary not found, please install jq via your system's package manager to continue"
		return 1
	fi
	if ! __check_command ar; then
		__error "ar binary not found, please install binutils and libarchive-rip-perl via your system's package manager to continue"
		return 1
	fi
	local _actions=()
	IFS=$'\n' mapfile -t _actions <<<"$(jq -r --arg action "${_manifest_action}" '.[$action] | keys[]' "${_manifest_file}")"
	if [ ${#_actions[@]} -eq 0 ]; then
		__error "No actions found in manifest for action: ${_manifest_action}"
		return 1
	fi
    for node_name in "${_actions[@]}"; do
        _manifest_json=$(jq -r --arg action "${_manifest_action}" --arg node_name "${node_name}" '.[$action][$node_name]' "${_manifest_file}")
		__process_node "${node_name}" "${_manifest_json}" || return $?
    done
}

####################################################################################################
# Main
####################################################################################################

__logo() {
	if [ ${LOGO} -eq 0 ]; then
		return 0
	fi
	cat <<EOF
                  ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
             ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
          ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
         ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
        ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
       ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓████▓░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░██▓░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒███░░██████░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░██░▓██░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓░█████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░███░░░░░██████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░█████░░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░████▒█░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░███░███▒██░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░▒█████░██░███░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░░██████░█░████░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░███████░▒█████░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░███████░██████░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░░░░░██████▒░██████░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░░░▓██░█████░█░██████░███████░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░░█████░████░██░██████░██████░░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░██████░██░████░██████░███▓░░░░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░██████░░█████░░██████░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░██▓░░░░████░░░░░█████░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
      ${C_GREEN}░░░░░░░░░░░███▓░░░░░░░░░░░░░▒███░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
       ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
        ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
         ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
          ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
             ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}
                 ${C_GREEN}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${C_RESET}

        ${C_YELLOW}GetGrass-Installer${C_RESET} ${C_CYAN}Install ${C_GREEN}Grass Desktop Node${C_CYAN} on ${C_BOLD}Any Linux${C_RESET}${C_CYAN}!${C_RESET}

                ${C_CYAN}Author:${C_RESET} ${C_WHITE}${C_BOLD}The Grass OGs${C_RESET} ${C_CYAN}<${C_RESET}${C_WHITE}${C_BOLD}https://getgrass.io${C_RESET}${C_CYAN}>${C_RESET}
                ${C_CYAN}License:${C_RESET} ${C_YELLOW}${C_BOLD}MIT${C_RESET} ${YELLOW}|${C_RESET} ${C_YELLOW}Version:${C_RESET} ${C_GREEN}${C_BOLD}0.1.0${C_RESET}

EOF
}
__parse_args() {
	local _bargs
	_bargs=()
	if [ $# -eq 0 ] || [ -z "$1" ]; then
		ACTION="install"
		__warn "No action provided, defaulting to ${C_BOLD}install${C_RESET}"
		return 0
	else
		ACTION="$1"
		if [ "${ACTION}" == "-h" ] || [ "${ACTION}" == "--help" ] || [ "x${ACTION}x" == "xx" ]; then
			__usage "default"
			return 0
		fi
		shift 1
	fi
	case "$ACTION" in
		"install")
			while [ $# -gt 0 ]; do
				case "$1" in
					-c|--config-file)
						if [ -z "$2" ]; then
							__error "-c | --config-file requires a file argument"
							__usage "install"
							return 1
						fi
						CONFIG_FILE="$2"
						shift 2
						;;
					-i|--install-prefix)
						if [ -z "$2" ]; then
							__error "-i | --install-prefix requires a directory argument"
							__usage "install"
							return 1
						fi
						INSTALL_PREFIX="$2"
						shift 2
						;;
					-e|--cache-dir)
						if [ -z "$2" ]; then
							__error "-e | --cache-dir requires a directory argument"
							__usage "install"
							return 1
						fi
						CACHE_DIR="$2"
						shift 2
						;;
					-l|--log-file)
						if [ -z "$2" ]; then
							__error "-l | --log-file requires a file argument"
							__usage "install"
							return 1
						fi
						LOG_FILE="$2"
						shift 2
						;;
					-u|--user-mode)
						USER_MODE=1
						shift 1
						;;
					-d|--debug)
						DEBUG=1
						shift 1
						;;
					-x|--no-logging)
						LOGGING=0
						shift 1
						;;
					-D|--dry-run)
						DRY_RUN=1
						shift 1
						;;
					-h|--help)
						__usage "install"
						return 1
						;;
					*)
						_bargs+=("$1")
						shift 1
						;;
				esac
			done
			;;
		"uninstall")
			while [ $# -gt 0 ]; do
				case "$1" in
					-c|--config-file)
						if [ -z "$2" ]; then
							__error "-c | --config-file requires a file argument"
							__usage "uninstall"
							return 1
						fi
						CONFIG_FILE="$2"
						shift 2
						;;
					-i|--install-prefix)
						if [ -z "$2" ]; then
							__error "-i | --install-prefix requires a directory argument"
							__usage "uninstall"
							return 1
						fi
						INSTALL_PREFIX="$2"
						shift 2
						;;
					-e|--cache-dir)
						if [ -z "$2" ]; then
							__error "-e | --cache-dir requires a directory argument"
							__usage "uninstall"
							return 1
						fi
						CACHE_DIR="$2"
						shift 2
						;;
					-l|--log-file)
						if [ -z "$2" ]; then
							__error "-l | --log-file requires a file argument"
							__usage "uninstall"
							return 1
						fi
						LOG_FILE="$2"
						shift 2
						;;
					-u|--user-mode)
						USER_MODE=1
						shift 1
						;;
					-d|--debug)
						DEBUG=1
						shift 1
						;;
					-x|--no-logging)
						LOGGING=0
						shift 1
						;;
					-D|--dry-run)
						DRY_RUN=1
						shift 1
						;;
					-h|--help)
						__usage "uninstall"
						return 1
						;;
					*)
						_bargs+=("$1")
						;;
				esac
			done
			;;
		*)
			__error "Invalid action: ${ACTION}"
			__usage "default"
			return 1
			;;
	esac
	if [ ${#_bargs[@]} -gt 0 ]; then
		__error "Invalid arguments provided: ${C_BOLD}${_bargs[*]}${C_RESET}, please see -h | --help for usage instructions"
		return 1
	fi
	return 0
}
__usage() {
	local _action
	if [ $# -eq 0 ]; then
		_action="default"
	else
		_action="$1"
		shift 1
	fi
	cat <<EOF
${C_GREEN}GetGrass${C_RESET} Desktop Node Installer
Authors: ${C_BOLD}${C_WHITE}The Grass OGs${C_RESET} ${C_GREEN}<${C_UNDERLINE}${C_BLUE}https://getgrass.io${C_RESET}${C_GREEN}>${C_RESET}

EOF
	# NOTE: When choosing to add new actions or edit be mindful of spatial awareness and tabs :)
	case "${_action}" in
		"default")
			cat <<EOF
Usage: ${C_BOLD}$0${C_RESET} [action] [options]

${C_BOLD}Actions${C_RESET}:
	install     Install the Grass Desktop Node
	uninstall   Uninstall the Grass Desktop Node

${C_BOLD}Options${C_RESET}:

	-h, --help            ${C_GRAY}<switch>${C_RESET}   Display this help message, and exit

For more information, you can run -h or --help for usage instructions on each action.
EOF
			;;
		"install")
			cat <<EOF
Usage: ${C_BOLD}$0${C_RESET} install [options]

Help page for the ${C_BOLD}install${C_RESET} action

${C_BOLD}Options${C_RESET}:

    -h, --help            ${C_GRAY}<switch>${C_RESET}   Display this help message, and exit
    -c, --config-file     ${C_GRAY}<file>${C_RESET}     Configuration file to use
    -i, --install-prefix  ${C_GRAY}<dir>${C_RESET}      Installation prefix, if specified then we install the
                                     application in this directory rather than the defaults.
    -e, --cache-dir       ${C_GRAY}<dir>${C_RESET}      Cache directory, if specified then we use this directory
                                     to store downloaded files.  Its important that you keep
                                     this directory around as its important for uninstallation.
    -u, --user-mode       ${C_GRAY}<switch>${C_RESET}   Install in user mode, if specified then we try to install
                                     the application in the user's home directory.
    -d, --debug           ${C_GRAY}<switch>${C_RESET}   Enable debug mode, if specified then you get a lot of
                                     debug information in the terminal.
    -x, --no-logging      ${C_GRAY}<switch>${C_RESET}   Disable logging, if specified
    -l, --log-file        ${C_GRAY}<file>${C_RESET}     Log file to use, if -x | --no-logging is specified
                                     then this option is ignored.
    -q, --quiet           ${C_GRAY}<switch>${C_RESET}   Quiet mode, if specified we don't print anything
                                     in the terminal.
    -D, --dry-run        ${C_GRAY}<switch>${C_RESET}   Dry run mode, if specified we don't install anything
                                      but we print the steps that would be taken.  Downloads still occur into
                                      the cache directory.
EOF
			;;
		"uninstall")
			cat <<EOF
Usage: ${C_BOLD}$0${C_RESET} uninstall [options]

Help page for the ${C_BOLD}uninstall${C_RESET} action

${C_BOLD}Options${C_RESET}:

    -h, --help            ${C_GRAY}<switch>${C_RESET}   Display this help message, and exit
    -c, --config-file     ${C_GRAY}<file>${C_RESET}     Configuration file to use
    -i, --install-prefix  ${C_GRAY}<dir>${C_RESET}      Installation prefix, if specified then we install the
                                     application in this directory rather than the defaults.
    -e, --cache-dir       ${C_GRAY}<dir>${C_RESET}      Cache directory, if specified then we use this directory
                                     to store downloaded files.  Its important that you keep
                                     this directory around as its important for uninstallation.
    -u, --user-mode       ${C_GRAY}<switch>${C_RESET}   Install in user mode, if specified then we try to install
                                     the application in the user's home directory.
    -d, --debug           ${C_GRAY}<switch>${C_RESET}   Enable debug mode, if specified then you get a lot of
                                     debug information in the terminal.
    -x, --no-logging      ${C_GRAY}<switch>${C_RESET}   Disable logging, if specified then we don't print
                                     anything in the terminal.
    -l, --log-file        ${C_GRAY}<file>${C_RESET}     Log file to use, if -x | --no-logging is specified
                                     then this option is ignored.
    -q, --quiet           ${C_GRAY}<switch>${C_RESET}   Quiet mode, if specified we don't print anything
                                     in the terminal.
    -D, --dry-run        ${C_GRAY}<switch>${C_RESET}   Dry run mode, if specified we don't uninstall anything
                                    but we print the steps that would be taken.  Downloads still occur into
                                    the cache directory.
EOF
			;;
		*)
			__error "Invalid usage action: ${_action}"
			return 1
			;;
	esac
	QUIET=1
	LOGGING=0
	return 0
}
__main() {
	local _args
	_args=($*)
	__parse_args ${_args[*]} || exit $?
	case "${ACTION}" in
		"install")
			__logo
			__process_manifest "${CONFIG_FILE}" "${ACTION}" || exit $?
			;;
		"uninstall")
			__logo
			__process_manifest "${CONFIG_FILE}" "${ACTION}" || exit $?
			;;
		*)
			exit $? # Invalid action
			;;
	esac
}
__main $@