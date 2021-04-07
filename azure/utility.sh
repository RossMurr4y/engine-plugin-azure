#!/usr/bin/env bash

# Utility Functions for the Azure provider
#
# This script is designed to be sourced into other scripts

# -- Storage --

function az_get_storage_connection_string(){
  local storageAccountName="$1"; shift
  local resourceGroup="$1"; shift

  args=(
    "name ${storageAccountName}"
  )

  if [[ -n "${resourceGroup}" ]]; then
    args=("${args[@]}" "resource-group ${resourceGroup}")
  fi

  az storage account show-connection-string \
    ${args[@]/#/--} | jq '.["connectionString"]' || return $?
}

function az_check_blob_container_access() {
  local storageAccountName="$1"; shift
  local containerName="$1"; shift

  az storage container show-permission \
    --name ${containerName} \
    --account-name ${storageAccountName} > /dev/null
}

function az_copy_to_blob(){
  local storageAccountName="$1"; shift
  local containerName="$1"; shift
  local blobName="$1"; shift
  local fileName="$1"; shift

  az storage blob upload \
    --account-name "${storageAccountName}" \
    --container-name "${containerName}" \
    --name "${blobName}" \
    --file "${file}" > /dev/null || return $?
}

function az_copy_from_blob(){
  local storageAccountName="$1"; shift
  local containerName="$1"; shift
  local blobName="$1"; shift
  local fileName="$1"; shift
  local resourceGroup="$1"; shift

  connectionString=$(az_get_storage_connection_string "${storageAccountName}")

  az storage blob download \
    --connection-string "${connectionString}" \
    --container-name "${containerName}" \
    --name "${blobName}" \
    --file "${fileName}" \
    --no-progress \
    --output none || return $?
}

function az_interact_storage_queue(){
  local storageAccountName="$1"; shift
  local queueName="$1"; shift
  local action="$1"; shift

  connectionString=$(az_get_storage_connection_string "${storageAccountName}")
  az storage queue ${action} --name "${queueName}" --connection-string "${connectionString}"  || return $?
}

# sync is in public preview as of Jan 2020.
function az_sync_with_blob(){
  local storageAccountName="$1"; shift
  local containerName="$1"; shift
  local destinationSuffix="$1"; shift
  if namedef_supported; then
    local -n syncFiles="$1"; shift
  else
    eval "local syncFiles=(\"\${${1}[@]}\")"; shift
  fi

  pushTempDir "${FUNCNAME[0]}_XXXXXX"
  local tmp_dir="$(getTopTempDir)"

  # Copy files locally so we can sync with Blog Storage
  for file in "${syncFiles[@]}" ; do
    if [[ -f "${file}" ]]; then
      case "$(fileExtension "${file}")" in
        zip)
          unzip -DD -q "${file}" -d "${tmp_dir}"
          ;;
        *)
          cp "${file}" "${tmp_dir}"
          ;;
      esac
    fi
  done

  connectionString=$(az_get_storage_connection_string "${storageAccountName}")

  args=(
    "connection-string ${connectionString}"
    "account-name ${storageAccountName}"
    "container ${containerName}"
    "source ${tmp_dir}"
  )

  # -- Only show errors unless debugging --
  if [[ ! $(willLog "${LOG_LEVEL_DEBUG}") ]]; then
    args=("${args[@]}" "only-show-errors" )
  fi

  if [[ -n "${destinationSuffix}" ]]; then
    args=("${args[@]}" "destination ${destinationSuffix}")
  fi

  az storage blob sync ${args[@]/#/--} || return $?
}

function az_delete_blob_dir(){
  local storageAccountName="$1"; shift
  local sourcePath="$1"; shift
  local pattern="$1"; shift

  args=(
    "auth-mode login"
    "account-name ${storageAccountName}"
    "source ${sourcePath}"
  )

  # -- Only show errors unless debugging --
  if [[ ! $(willLog "${LOG_LEVEL_DEBUG}")  ]]; then
    args=("${args[@]}" "only-show-errors" )
  fi

  if [[ -n "${pattern}" ]]; then
    args=("${args[@]}" "pattern ${pattern}")
  fi

  az storage blob delete-batch ${args[@]/#/--} > /dev/null || return $?
}

# -- Keys --
function az_create_pki_credentials() {
  local dir="$1"; shift
  local region="$1"; shift
  local account="$1"; shift
  local keytype="$1"; shift

  if [[ ! -f "${dir}/.azure-${account}-${region}-${keytype}-crt.pem" ]]; then
      openssl genrsa -out "${dir}/.azure-${account}-${region}-${keytype}-prv.pem.plaintext" 2048 || return $?
      openssl rsa -in "${dir}/.azure-${account}-${region}-${keytype}-prv.pem.plaintext" -pubout > "${dir}/.azure-${account}-${region}-${keytype}-crt.pem" || return $?
  fi

  if [[ ! -f "${dir}/.gitignore" ]]; then
    cat << EOF > "${dir}/.gitignore"
*.plaintext
*.decrypted
*.ppk
EOF
  fi

  return 0
}

function az_create_ssh_keypair() {
  local dir="$1"; shift
  local region="$1"; shift
  local account="$1"; shift

  file="${dir}/.azure-${account}-${region}-ssh.plaintext"

  if [[ ! -e "${file}" ]]; then
    ssh-keygen -m PEM -t rsa -b 2048 -f "${file}" -q -N ""
  fi

  if [[ ! -f "${dir}/.gitignore" ]]; then
    cat << EOF > "${dir}/.gitignore"
*.plaintext
*.decrypted
*.ppk
EOF
  fi

}

function az_show_key_credentials() {
  local vaultName="$1"; shift
  local keyName="$1"; shift

  local keyId="https://${vaultName}.azure.net/keys/${keyName}"

  az keyvault key show --id "${keyId}"
}

# -- Secrets --
function az_add_secret() {
  local vaultName="$1"; shift
  local keyName="$1"; shift
  local secret="$1"; shift

  info "Adding secret ${keyName} to vault ${vaultName} ..."
  if [[ -f ${secret} ]]; then
    az keyvault secret set --vault-name "${vaultName}" --name "${keyName}" --file "${secret}" 2>&1 > /dev/null
  else
    az keyvault secret set --vault-name "${vaultName}" --name "${keyName}" --value "${secret}" 2>&1 > /dev/null
  fi
}

function az_check_secret() {
  local vaultName="$1"; shift
  local secretName="$1"; shift

  local secretId="https://${vaultName}.vault.azure.net/secrets/${secretName}"

  az keyvault secret show --id "${secretId}" 2>&1 > /dev/null
}

function az_delete_secret() {
  local vaultName="$1"; shift
  local keyName="$1"; shift

  local keyId="https://${vaultName}.vault.azure.net/keys/${keyName}"

  #azure returns a large object upon successful deletion, so we redirect that.
  az keyvault key show --id "${keyId}" 2>&1 > /dev/null && \
  { az keyvault secret delete --id "${keyId}" > /dev/null || return $?; }

  return 0
}

# -- CDN --

function az_purge_frontdoor_endpoint() {
  local resourceGroup="$1"; shift
  local frontDoorName="$1"; shift

  local paths=("/*")
  [[ -n "$1" ]] && local paths=("$@")

  az network front-door purge-endpoint \
    --resource-group "${resourceGroup}" \
    --name "${frontDoorName}" \
    --content-paths "${paths[@]}"
}

# -- Lambda --

# downloads project files from .zip into a Function App.
# This will restart the app automatically.
# TODO(rossmurr4y): https://github.com/Azure/azure-cli/issues/10773
# remove requirement for subscription param when resolved
function az_functionapp_deploy() {
  local subscription="$1"; shift
  local resourceGroup="$1"; shift
  local function="$1"; shift
  local file="$1"; shift
  local action="$1"; shift

  cat <<EOF
"${action^}"ing FunctionApp:
Subscription:  "${subscription}"
ResourceGroup: "${resourceGroup}"
Function Name: "${function}"
File:          "${file:-"n/a"}"
EOF

  case ${action} in
    delete)
      az functionapp delete \
        --subscription "${subscription}" \
        --resource-group "${resourceGroup}" \
        --name "${function}" \
        --output none || return $?
        ;;
    *)
      az functionapp deployment source config-zip \
        --subscription "${subscription}" \
        --resource-group "${resourceGroup}" \
        --name "${function}" \
        --src "${file}" --verbose --debug || return $?
        ;;
  esac
}
