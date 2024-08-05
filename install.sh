#!/usr/bin/env bash

# install-grass: Install Grass on Any Linux!
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
CONFIG_FILE=${CONFIG_FILE:-"manifest.json"}
INSTALL_PREFIX=${INSTALL_PREFIX:-"/usr"}
CACHE_DIR=${CACHE_DIR:-"${CSCRIPT_DIR}/.grass-install"}
USER_MODE=${USER_MODE:-0}
DEBUG=${DEBUG:-0}
LOGGING=${LOGGING:-1}
LOG_FILE=${LOG_FILE:-"/var/log/grass-install.log"}

# Colors
C_RED=$(tput setaf 1)
C_GREEN=$(tput setaf 2)
C_YELLOW=$(tput setaf 3)
C_BLUE=$(tput setaf 4)
C_MAGENTA=$(tput setaf 5)
C_CYAN=$(tput setaf 6)
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
		if [ ${DEBUG} -eq 1 ] && [ "${_loglevel}" == "DEBUG" ]; then
			echo -e "${_logstr}" >&2
		elif [ "${_loglevel}" != "DEBUG" ]; then
			if [ "${_loglevel}" == "ERROR" ]; then
				echo -e "${_logstr}" >&2
			else
				echo -e "${_logstr}"
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
	if ! command -v $1 &> /dev/null; then
		return 1
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
        if ! mkdir -p "${_destination_folder}"; then
            __error "Failed to create destination folder: ${_destination_folder}"
            return 1
        fi
    fi
    find "${_base_folder}/usr" -type d | while read -r dir; do
        dest_dir="${_destination_folder}${dir#${_base_folder}/usr}"
        if [ ! -d "${dest_dir}" ]; then
            mkdir -p "${dest_dir}" || {
				__error "Failed to create folder: ${dest_dir}"
			}
        fi
    done
    find "${_base_folder}/usr" -type f | while read -r file; do
        dest_file="${_destination_folder}${file#${_base_folder}/usr}"
        __run_command cp ${file} ${dest_file} || {
            __error "Failed to copy ${file} to ${dest_file}"
            return 1
        }
        if [ $_usermode -eq 1 ]; then
            __run_command chown $(whoami):$(whoami) "${dest_file}" || {
                __error "Failed to change ownership of ${dest_file}"
                return 1
            }
        fi
		__run_command chmod 0755 "${dest_file}" || {
			__error "Failed to change permissions of ${dest_file}"
			return 1
		}
    done
    __success "Files copied to ${_destination_folder} successfully"
	return 0
}
function __update_desktop_database() {
	if ! __check_command $(which update-desktop-database); then
		__warning -e "update-desktop-database utility not found, please update your xdg-utils package and run:\n\nupdate-desktop-database ~/.local/share/applications if you'd like grass to be in your session menu."
	else
		$(which su) -s $(which bash) $USER_NAME -c "update-desktop-database /home/${USER_NAME}/.local/share/applications" || {
			__error "Failed to update desktop database"
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
	if ! __check_command $(which update-ca-certificates); then
		__error "update-ca-certificates command not found"
		return 1
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
        __error "No actions found in manifest for file: ${_node_name}"
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
					__download_file_gdrive "${_file_id}" "${_output_file}" || return 
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
                __info "Installing certificate: ${_output_file}..."
                __install_cert "${_output_file}" || return $?
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
    local _manifest_file=$1
    if [ -z "${_manifest_file}" ]; then
        echo "Manifest file not provided" >&2
        return 1
    fi
    if [ ! -f "${_manifest_file}" ]; then
        echo "Manifest file not found: ${_manifest_file}" >&2
        return 1
    fi
    for node_name in $(jq -r '.install | keys[]' "${_manifest_file}"); do
        _manifest_install_json=$(jq -r --arg node_name "${node_name}" '.install[$node_name]' "${_manifest_file}")
        __process_node "${node_name}" "${_manifest_install_json}" || exit $?
    done
}

####################################################################################################
# Main
####################################################################################################

__logo() {
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

__logo
__process_manifest "${CONFIG_FILE}"