#!/bin/bash

# install-grass: Install Grass on Any Linux!
#

if [ "$(id -u)" -ne 0 ]; then
	echo "This installer must not be run as root as it will make changes to file ownership and install files as necessary on your system." >&2
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

CSCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CONFIG_FILE=${CONFIG_FILE:-"manifest.json"}
INSTALL_PREFIX=${INSTALL_PREFIX:-"/usr"}
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
# Logging functions
####################################################################################################

function __strip_ansi() {
	sed -r "s/\x1B\[[0-9;]*[JKmsu]//g" <<<"$1"
}
function __info() {
	local _logstr _logstr_noansi
	_logstr="${C_CYAN}[${C_BOLD}INFO${C_RESET}${C_CYAN}] $1${C_RESET}"
	_logstr_noansi=$(__strip_ansi "${_logstr}")
	echo -e "${_logstr}" >&2
	if [ ${LOGGING} -eq 1 ]; then
		echo -e "$(date -I) ${_logstr_noansi}" >>"${LOG_FILE}"
	fi
}
function __warn() {
	local _logstr _logstr_noansi
	_logstr="${C_YELLOW}[${C_BOLD}WARN${C_RESET}${C_YELLOW}] $1${C_RESET}"
	_logstr_noansi=$(__strip_ansi "${_logstr}")
	echo -e "${_logstr}" >&2
	if [ ${LOGGING} -eq 1 ]; then
		echo -e "$(date -I) ${_logstr_noansi}" >>"${LOG_FILE}"
	fi
}
function __error() {
	local _logstr _logstr_noansi
	_logstr="${C_RED}[${C_BOLD}ERROR${C_RESET}${C_RED}] $1${C_RESET}"
	_logstr_noansi=$(__strip_ansi "${_logstr}")
	echo -e "${_logstr}" >&2
	if [ ${LOGGING} -eq 1 ]; then
		echo -e "$(date -I) ${_logstr_noansi}" >>"${LOG_FILE}"
	fi
}
function __success() {
	local _logstr _logstr_noansi
	_logstr="${C_GREEN}[${C_BOLD}SUCCESS${C_RESET}${C_GREEN}] $1${C_RESET}"
	_logstr_noansi=$(__strip_ansi "${_logstr}")
	echo -e "${_logstr}" >&2
	if [ ${LOGGING} -eq 1 ]; then
		echo -e "$(date -I) ${_logstr_noansi}" >>"${LOG_FILE}"
	fi
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

function __check_command() {
	if ! command -v $1 &> /dev/null; then
		return 1
	fi
	return 0
}

function __check_file() {
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
		return 0
	fi
	local _md5_checksum=$1
	if [ -n "${_md5_checksum}" ]; then
		if ! __check_command md5sum; then
			__error "md5sum utility not found, could not verify checksum of file"
			return 1
		fi
		if [ "$(md5sum ${_file_path} | awk '{print $1}')" != "${_md5_checksum}" ]; then
			__error "MD5 checksum does not match"
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
			__error "sha256sum utility not found, could not verify checksum of file"
			return 1
		fi
		if [ "$(sha256sum ${_file_path} | awk '{print $1}')" != "${_sha256_checksum}" ]; then
			__error "SHA256 checksum does not match"
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
			__error "crc32 utility not found, could not verify checksum of file"
			return 1
		fi
		if [ "$(crc32 ${_file_path} | awk '{print $1}')" != "${_crc32_checksum}" ]; then
			__error "CRC32 checksum does not matchg given: $(crc32 ${_file_path} | awk '{print $1}') expected: ${_crc32_checksum}"
			return 1
		fi
	fi
	shift 1
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
	ar x "${_deb_file}" || {
		__error "Failed to extract ${_deb_file} package"
		return 1
	}
	tar -xf control.tar.* || {
		__error "Failed to extract control.tar.*"
		return 1
	}
	tar -xf data.tar.* || {
		__error "Failed to extract data.tar.*"
		return 1
	}
	rm control.tar.* data.tar.* || {
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
        cp "${file}" "${dest_file}" || {
            __error "Failed to copy ${file} to ${dest_file}"
            return 1
        }
        if [ $_usermode -eq 1 ]; then
            chown $(whoami):$(whoami) "${dest_file}" || {
                __error "Failed to change ownership of ${dest_file}"
                return 1
            }
        fi
		chmod 0755 "${dest_file}" || {
			__error "Failed to change permissions of ${dest_file}"
			return 1
		}
    done
    echo "Files copied to ${_destination_folder}"
	if ! __check_command update-desktop-database; then
		__warning -e "update-desktop-database utility not found, please update your xdg-utils package and run:\n\nupdate-desktop-database ~/.local/share/applications if you'd like grass to be in your session menu."
	else
		# run the command as the user
		/bin/su -c "update-desktop-database ~/.local/share/applications" -s /bin/bash $USER_NAME || {
			echo "Failed to update desktop database"
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
		__error "update-ca-certificates command not found"
		return 1
	fi
	cp "${_cert_file}" /etc/ssl/certs/ || {
		__error "Failed to copy certificate file to /etc/ssl/certs/"
		return 1
	}
	c_rehash /etc/ssl/certs/ || {
		__error "Failed to update certificate hash"
		return 1
	}
	update-ca-certificates || {
		__error "Failed to update certificate store"
		return 1
	}
	__success "Certificate installed successfully"
}

function __process_node() {
	local _file_name=$1
	if [ -z "${_file_name}" ]; then
		__error "File name not provided"
		return 1
	fi
	shift 1
	if [ $# -eq 0 ]; then
		__error "Manifest file not provided"
		return 1
	fi
	local _config_file=$1
	if [ -z "${_config_file}" ]; then
		__error "Manifest file not provided"
		return 1
	fi
	if [ ! -f "${_config_file}" ]; then
		__error "Manifest file not found: ${_config_file}"
		return 1
	fi
	local _file_info _file_id _md5 _sha256 _crc32 _output_file _download_dir
	declare -a _actions
	_file_info=$(jq -r --arg file_name "$_file_name" '.[$file_name]' "${_config_file}")
	_file_identifier=$(echo "${_file_info}" | jq -r '.file_identifier')
	if [ -z "${_file_identifier}" ]; then
		__error "File identifier not found in manifest"
		return 1
	fi
	_md5=$(echo "${_file_info}" | jq -r '.md5')
	if [ -z "${_md5}" ]; then
		__error "MD5 checksum not found in manifest for file: ${_file_name}"
		return 1
	fi
	_sha256=$(echo "${_file_info}" | jq -r '.sha256')
	if [ -z "${_sha256}" ]; then
		__error "SHA256 checksum not found in manifest for file: ${_file_name}"
		return 1
	fi
	_crc32=$(echo "${_file_info}" | jq -r '.crc32')
	if [ -z "${_crc32}" ]; then
		__error "CRC32 checksum not found in manifest for file: ${_file_name}"
		return 1
	fi
	_output_file="${CSCRIPT_DIR}/.grass-install/${_file_name}"
	IFS=' ' mapfile -t _actions <<<$(echo "${_file_info}" | jq -r '.actions[]')
	if [ ${#_actions[@]} -eq 0 ]; then
		__error "No installation actions found in manifest for file: ${_file_name}"
		return 1
	fi
	for _action in "${_actions[@]}"; do
		case "${_action}" in
			"download_gdrive")
				__info "Downloading file: ${_file_name} using gdrive method to ${_output_file}..."
				__download_file_gdrive "${_file_identifier}" "${_output_file}" || return 1
				;;
			"check")
				__info "Checking file: ${_output_file}..."
				__check_file "${_output_file}" "${_md5}" "${_sha256}" "${_crc32}" || return 1
				;;
			"extract_deb")
				local _destination_dir
				_destination_dir="${CSCRIPT_DIR}/.grass-install/${_file_name%.*}"
				__info "Extracting deb package: ${_output_file} to ${_destination_dir}..."
				__extract_deb_package "${_output_file}" "${_destination_dir}" || return 1
				;;
			"install_deb_folder")
				local _source_dir
				_source_dir="${CSCRIPT_DIR}/.grass-install//${_file_name%.*}"
				__info "Installing deb package folder: ${_source_dir} to ${INSTALL_PREFIX}..."
				__install_files "${_source_dir}" "${INSTALL_PREFIX}" "${USER_MODE}" || return 1
				;;
			"install_cert")
				local _cert_file
				_cert_file="${CSCRIPT_DIR}/.grass-install/${_file_name}"
				__info "Installing certificate: ${_cert_file}..."
				__install_cert "${_cert_file}" || return 1
				;;
			*)
				echo "Invalid action: ${_action}" >&2
				return 1
				;;
		esac
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
	for file_name in $(jq -r 'keys[]' "${_manifest_file}"); do
		__process_node "${file_name}" "${_manifest_file}" || exit $?
	done
}

__process_manifest "${CONFIG_FILE}"