#!/bin/bash


function display_menu_and_get_choice() {
  # Print the menu
  echo "================================================="
  echo "Install ARO Cluster. Choose an option (1-5): "
  echo "================================================="
  options=(
    "Terraform Init"
    "Terraform Validate"
    "Terraform Plan"
    "Terraform Apply"
    "Terraform Destroy"
    "Delete Resource Group"
    "Quit"
  )

  # Select an option
  COLUMNS=0
  select opt in "${options[@]}"; do
    case $opt in
    "Terraform Init")
      terraform init
      exit
      ;;
    "Terraform Validate")
      terraform validate
      exit
      ;;
    "Terraform Plan")
      op="plan"
      call_terraform_for_plan_or_apply $op
      break
      ;;
    "Terraform Apply")
      op="apply"
      call_terraform_for_plan_or_apply $op
      break
      ;;
    "Terraform Destroy")
      op="destroy"
      call_terraform_for_plan_or_apply $op
      break
      ;;
    "Delete Resource Group")
      delete_resource_group
      exit
      ;;
    "Quit")
      exit
      ;;
    *) echo "Invalid option $REPLY" ;;
    esac
  done
}

function call_terraform_for_plan_or_apply() {
  local op=$1

  echo ""
  local resourcePrefix="arotmp${RANDOM}"
  local TMP_VAR=""
  read -p "Please enter resource prefix (default [$resourcePrefix]): " TMP_VAR
  resourcePrefix="${TMP_VAR:-$resourcePrefix}"

  TMP_VAR=""
  local location="eastus"
  read -p "Please enter location (default [$location]): " TMP_VAR
  location="${TMP_VAR:-$location}"

  TMP_VAR=""
  local aroDomain="${resourcePrefix}${RANDOM}"
  read -p "Please enter domain (default [$aroDomain]): " TMP_VAR
  aroDomain="${TMP_VAR:-$aroDomain}"

  # aroDomain="${resourcePrefix,,''}"
  local aroClusterServicePrincipalDisplayName="${aroDomain}-aro-sp"
  pullSecret=$(cat pull-secret.txt)

  # Name and location of the resource group for the Azure Red Hat OpenShift (ARO) cluster
  local aroResourceGroupName="${resourcePrefix}RG"

  # Subscription id, subscription name, and tenant id of the current subscription
  subscriptionId=$(az account show --query id --output tsv)
  subscriptionName=$(az account show --query name --output tsv)
  tenantId=$(az account show --query tenantId --output tsv)

  terraform_apply_or_plan $op $resourcePrefix $location $aroDomain $tenantId \
    $aroClusterServicePrincipalDisplayName $aroResourceGroupName \
    $subscriptionId $subscriptionName
}


function az_register() {
  printf "\n -> Executing az provider register commands...\n"

  # Register the necessary resource providers
  az provider register --namespace 'Microsoft.RedHatOpenShift' --wait
  az provider register --namespace 'Microsoft.Compute' --wait
  az provider register --namespace 'Microsoft.Storage' --wait
  az provider register --namespace 'Microsoft.Authorization' --wait
}

function az_check_and_create_resource_group() {
  local location=$1
  local aroResourceGroupName=$2
  local subscriptionName=$3

  printf "\n -> Checking and creating resource group using location=%s, aroResourceGroupName=%s and subscriptionName=%s\n" $location $aroResourceGroupName $subscriptionName

  # Check if the resource group already exists
  echo "    - Checking if [$aroResourceGroupName] resource group actually exists in the [$subscriptionName] subscription..."

  az group show --name $aroResourceGroupName &>/dev/null

  if [[ $? != 0 ]]; then
    echo "    - No [$aroResourceGroupName] resource group actually exists in the [$subscriptionName] subscription"
    echo "    - Creating [$aroResourceGroupName] resource group in the [$subscriptionName] subscription..."

    # Create the resource group
    az group create --name $aroResourceGroupName --location $location 1>/dev/null

    if [[ $? == 0 ]]; then
      echo "    - [$aroResourceGroupName] resource group successfully created in the [$subscriptionName] subscription"
    else
      echo "    - Failed to create [$aroResourceGroupName] resource group in the [$subscriptionName] subscription"
      exit
    fi
  else
    echo "    - [$aroResourceGroupName] resource group already exists in the [$subscriptionName] subscription"
  fi
}

function create_service_principal_for_rbac() {
  local appServicePrincipalJson=$1
  local tenantId=$2
  local aroClusterServicePrincipalDisplayName=$3

  if [ ! -f "${appServicePrincipalJson}" ]; then
    # Create the service principal for the Azure Red Hat OpenShift (ARO) cluster
    printf "\n -> Creating service principal with tenantId=%s, aroClusterServicePrincipalDisplayName=%s\n" $tenantId $aroClusterServicePrincipalDisplayName
    # echo "Creating service principal with [$aroClusterServicePrincipalDisplayName] display name in the [$tenantId] tenant..."
    az ad sp create-for-rbac \
      --name $aroClusterServicePrincipalDisplayName > ${appServicePrincipalJson}
  fi
}

function create_role_assignment() {
  local roleName="$1"
  local aroClusterServicePrincipalObjectId="$2"
  local aroResourceGroupName="$3"
  local aroClusterServicePrincipalDisplayName="$4"
  local subscriptionId="$5"
  local createRoleAssignmentJson="$6"

  printf "\n -> creating role assignment for role=$roleName"
  printf "\n        aroClusterServicePrincipalObjectId=$aroClusterServicePrincipalObjectId"
  printf "\n        aroResourceGroupName=$aroResourceGroupName"
  printf "\n        subscriptionId=$subscriptionId"
  printf "\n        aroClusterServicePrincipalDisplayName=$aroClusterServicePrincipalDisplayName\n"

  if [ ! -f "${createRoleAssignmentJson}" ]; then
    # Assign the given roleName to the new service principal with resource group scope
    az role assignment create \
      --role "$roleName" \
      --assignee-object-id $aroClusterServicePrincipalObjectId \
      --assignee-principal-type 'ServicePrincipal' > "${createRoleAssignmentJson}" \
      --scope /subscriptions/${subscriptionId}/resourceGroups/${aroResourceGroupName}
      # --resource-group $aroResourceGroupName \

    if [[ $? == 0 ]]; then
      printf "[$aroClusterServicePrincipalDisplayName] service principal successfully assigned [$roleName] with [$aroResourceGroupName] resource group scope\n"
    else
      printf "Failed to assign [$roleName] role with [$aroResourceGroupName] resource group scope to the [$aroClusterServicePrincipalDisplayName] service principal\n"
      exit
    fi
  else
    printf "   -> JSON (%s) containing role assignment already exists. Not creating role assignment...\n" "$createRoleAssignmentJson"
  fi
}


function terraform_apply_or_plan() {
  local op="$1"
  local resourcePrefix="$2"
  local location="$3"
  local aroDomain="$4"
  local tenantId="$5"
  local aroClusterServicePrincipalDisplayName="$6"
  local aroResourceGroupName="$7"
  local subscriptionId="$8"
  local subscriptionName="$9"
  local pullSecret=$(cat pull-secret.txt)

  local appServicePrincipalJson="${aroResourceGroupName}-app-service-principal.json"
  local createUserAccessRoleAssignmentJson="${aroResourceGroupName}-create-user-access-role-assignment.json"
  local createContributorRoleAssignmentJson="${aroResourceGroupName}-create-contributor-role-assignment.json"

  # local aroResourceProviderServicePrincipalObjectId=$9
  local extraOptions="-auto-approve"
  local mainPlanFile="main.tfplan"

  if [ "$op" == 'plan' ]; then
    extraOptions="-out ${mainPlanFile}"   # to output the plan
  elif [ "$op" == 'apply' -a -f "${mainPlanFile}" ]; then
    extraOptions="${mainPlanFile}"  # to specify the plan file
  fi

  local TMP_VAR=""
  local resourceCreateTimeout="1h"
  read -p "Please enter timeout value for resource creation (default [$resourceCreateTimeout]): " TMP_VAR
  resourceCreateTimeout="${TMP_VAR:-$resourceCreateTimeout}"

  az_register

  if [ "$op" != 'destroy' ]; then
    az_check_and_create_resource_group $location $aroResourceGroupName $subscriptionName
    create_service_principal_for_rbac $appServicePrincipalJson $tenantId $aroClusterServicePrincipalDisplayName
  fi

  if [ ! -f "${appServicePrincipalJson}" ]; then
    printf "\n\n -> *** Service Principal JSON (%s) does not exist. Can NOT continue...\n\n" "${appServicePrincipalJson}"
    exit 1
  fi

  local aroClusterServicePrincipalClientId=$(jq -r '.appId' ${appServicePrincipalJson})
  local aroClusterServicePrincipalClientSecret=$(jq -r '.password' ${appServicePrincipalJson})
  local aroClusterServicePrincipalObjectId=$(az ad sp show --id $aroClusterServicePrincipalClientId | jq -r '.id')

  if [ "$op" != 'destroy' ]; then
    create_role_assignment 'User Access Administrator' \
      $aroClusterServicePrincipalObjectId \
      $aroResourceGroupName \
      $aroClusterServicePrincipalDisplayName \
      $subscriptionId \
      $createUserAccessRoleAssignmentJson
    create_role_assignment 'Contributor' \
      $aroClusterServicePrincipalObjectId \
      $aroResourceGroupName \
      $aroClusterServicePrincipalDisplayName \
      $subscriptionId \
      $createContributorRoleAssignmentJson
  fi

  # Get the service principal object ID for the OpenShift resource provider
  local aroResourceProviderServicePrincipalObjectId=$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query [0].id -o tsv)

  printf "\n   -> key ids/values used"
  for i in op resourcePrefix location aroDomain tenantId \
            aroClusterServicePrincipalDisplayName aroResourceGroupName \
            subscriptionId subscriptionName extraOptions \
            aroClusterServicePrincipalClientId aroClusterServicePrincipalObjectId \
            aroResourceProviderServicePrincipalObjectId resourceCreateTimeout
  do
    printf "\n     - $i=${!i}"
  done
  printf "\n\n"

  printf "\n\n -> Running terraform $op command...\n"
  if [ "$op" == 'apply' -a -f "${mainPlanFile}" ]; then
    terraform apply ${mainPlanFile}
  else
    # cat <<TERRAFORM_CMD
    terraform $op \
      -compact-warnings \
      $extraOptions \
      -var "resource_prefix=$resourcePrefix" \
      -var "resource_group_name=$aroResourceGroupName" \
      -var "location=$location" \
      -var "domain=$aroDomain" \
      -var "timeout_resource_create=$resourceCreateTimeout" \
      -var "aro_cluster_aad_sp_client_id=$aroClusterServicePrincipalClientId" \
      -var "aro_cluster_aad_sp_client_secret=$aroClusterServicePrincipalClientSecret" \
      -var "aro_cluster_aad_sp_object_id=$aroClusterServicePrincipalObjectId" \
      -var "aro_rp_aad_sp_object_id=$aroResourceProviderServicePrincipalObjectId" \
      -var "pull_secret=$pullSecret"
  # TERRAFORM_CMD
  fi

}


function confirm_login() {
  echo "Are you already logged in using az login? "
  select answer in "Yes" "No"; do
      case $answer in
          Yes) 
            echo ""
            display_menu_and_get_choice
            break;;
          No)
            echo "Please login first"
            exit 1;;
      esac
  done
}

function delete_resource_group() {
  local resourceGroupToDelete=""
  read -p "Please enter resource group name: " resourceGroupToDelete
  printf "\n -> All the resources in resource group \"${resourceGroupToDelete}\" will be deleted"
  printf "\n    Do you want to continue?\n"
  select answer in "Yes" "No"; do
      case $answer in
          Yes)
            printf "\n -> DELETING all the resources in resource group \"${resourceGroupToDelete}\"...\n"
            az group delete -y --name "${resourceGroupToDelete}"
            printf "\n    Done!!!\n"
            rm -f ${resourceGroupToDelete}*.json
            break;;
          No)
            break;;
      esac
  done
}


confirm_login
# display_menu_and_get_choice

# if [[ $op == 'plan' ]]; then
#   terraform plan \
#     -compact-warnings \
#     -out main.tfplan \
#     -var "resource_prefix=$resourcePrefix" \
#     -var "location=$location" \
#     -var "domain=$aroDomain" \
#     -var "pull_secret=$pullSecret" \
#     -var "aro_cluster_aad_sp_client_id=$aroClusterServicePrincipalClientId" \
#     -var "aro_cluster_aad_sp_client_secret=$aroClusterServicePrincipalClientSecret" \
#     -var "aro_cluster_aad_sp_object_id=$aroClusterServicePrincipalObjectId" \
#     -var "aro_rp_aad_sp_object_id=$aroResourceProviderServicePrincipalObjectId"
# else
#   if [[ -f "main.tfplan" ]]; then
#     terraform apply \
#       -compact-warnings \
#       -auto-approve \
#       main.tfplan \
#       -var "resource_prefix=$resourcePrefix" \
#       -var "resource_group_name=$aroResourceGroupName" \
#       -var "location=$location" \
#       -var "domain=$aroDomain" \
#       -var "pull_secret=$pullSecret" \
#       -var "aro_cluster_aad_sp_client_id=$aroClusterServicePrincipalClientId" \
#       -var "aro_cluster_aad_sp_client_secret=$aroClusterServicePrincipalClientSecret" \
#       -var "aro_cluster_aad_sp_object_id=$aroClusterServicePrincipalObjectId" \
#       -var "aro_rp_aad_sp_object_id=$aroResourceProviderServicePrincipalObjectId"
#   else
#     terraform apply \
#       -compact-warnings \
#       -auto-approve \
#       -var "resource_prefix=$resourcePrefix" \
#       -var "resource_group_name=$aroResourceGroupName" \
#       -var "location=$location" \
#       -var "domain=$aroDomain" \
#       -var "pull_secret=$pullSecret" \
#       -var "aro_cluster_aad_sp_client_id=$aroClusterServicePrincipalClientId" \
#       -var "aro_cluster_aad_sp_client_secret=$aroClusterServicePrincipalClientSecret" \
#       -var "aro_cluster_aad_sp_object_id=$aroClusterServicePrincipalObjectId" \
#       -var "aro_rp_aad_sp_object_id=$aroResourceProviderServicePrincipalObjectId"
#   fi
# fi
