[#ftl]
[#macro azure_baseline_arm_deployment_generationcontract occurrence]
  [@addDefaultGenerationContract subsets=["prologue", "template", "epilogue"] /]
[/#macro]

[#macro azure_baseline_arm_deployment occurrence]
    [@debug message="Entering" context=occurrence enabled=false /]

    [#local core = occurrence.Core ]
    [#local solution = occurrence.Configuration.Solution ]
    [#local resources = occurrence.State.Resources ]
    [#local links = getLinkTargets(occurrence )]
    [#local keyVaultIPRuleGroups = []]
    [#local keyVaultAdmins = solution["azure:AdministratorGroups"]![] ]

    [#-- make sure we only have one occurence --]
    [#if  ! ( core.Tier.Id == "mgmt" &&
      core.Component.Id == "baseline" &&
      core.Version.Id == "" &&
      core.Instance.Id == "" ) ]

      [@fatal
        message="The baseline component can only be deployed once as an unversioned component"
        context=core
      /]
      [#return]
    [/#if]

    [#-- Segment Seed --]
    [#local segmentSeedId = resources["segmentSeed"].Id]
    [#local segmentSeedValue = resources["segmentSeed"].Value]
    [#if !(getReference(segmentSeedId)?has_content)]

      [#if deploymentSubsetRequired("prologue", false)]
        [@addToDefaultBashScriptOutput
          content=
          [
            "case $\{DEPLOYMENT_OPERATION} in",
            "  create|update)"
          ] +
          pseudoArmStackOutputScript(
            "Seed Values",
            { segmentSeedId : segmentSeedValue },
            "seed"
          ) +
          [
            "       ;;",
            "       esac"
          ]
        /]
      [/#if]
    [/#if]

    [#-- Baseline component lookup --]
    [#local baselineLinks = getBaselineLinks(occurrence, [ "Encryption" ], false, false )]
    [#local baselineComponentIds = getBaselineComponentIds(
      baselineLinks,
      "cmk",
      "vmKeyPair")]
    [#local cmkKeyId = baselineComponentIds["Encryption"]]

    [#-- Parent Component Resources --]
    [#local tenantId = formatAzureSubscriptionReference("tenantId")]
    [#local accountId = resources["storageAccount"].Id]
    [#local secret = resources["secret"]]
    [#local accountName = resources["storageAccount"].Name]
    [#local blobId = resources["blobService"].Id]
    [#local blobName = resources["blobService"].Name]
    [#local keyvault = resources["keyVault"]]
    [#local keyVaultAccessPolicy = resources["keyVaultAccessPolicy"].Id]
    [#local registries = resources["registries"]]

    [#local storageProfile = getStorage(occurrence, "storageAccount")]

    [#-- storageAccount : Retrieve Certificate Information --]
    [#if solution.Certificate?has_content]
      [#local certificateObject = getCertificateObject(solution.Certificate, segmentQualifiers, sourcePortId, sourcePortName) ]
      [#local primaryDomainObject = getCertificatePrimaryDomain(certificateObject) ]
      [#local fqdn = formatDomainName(hostName, primaryDomainObject)]
    [#else]
        [#local fqdn = ""]
    [/#if]

    [#--
      storageAccount + keyVault : Retrieve NetworkACL Configuration
      Default network access to keyvault and storageAccounts is to Allow. Restricting
      these services is expected to occur through authentication.
    --]
    [#-- networkAcls object is used for both Storage Account and KeyVault --]
    [#local storageNetworkAclsConfiguration = getNetworkAcls("Allow", [], [], "AzureServices")]

    [@createStorageAccount
      id=accountId
      name=accountName
      kind=storageProfile.Type
      sku=getStorageSku(storageProfile.Tier, storageProfile.Replication)
      location=regionId
      customDomain=getStorageCustomDomain(fqdn)
      networkAcls=storageNetworkAclsConfiguration
      accessTier=(storageProfile.AccessTier)!{}
      azureFilesIdentityBasedAuthentication=
        (solution.Access.DirectoryService)?has_content?then(
          getStorageAzureFilesIdentityBasedAuthentication(solution.Access.DirectoryService),
          {}
        )
      isHnsEnabled=(storageProfile.HnsEnabled)!false
    /]

    [#-- Set ConnectionKey as Secret --]
    [@createKeyVaultSecret
        id=secret.Id
        name=formatAzureResourceName(
            secret.Name,
            secret.Type,
            keyvault.Name)
        properties=
            getKeyVaultSecretProperties(
                formatAzureStorageListKeys(accountId, accountName)
            )
        dependsOn=[
            getReference(accountId, accountName),
            getReference(keyvault.Id, keyvault.Name)
        ]
    /]

    [@createBlobService
      id=blobId
      name=blobName
      CORSBehaviours=solution.CORSBehaviours
      deleteRetentionPolicy=
        (solution.Lifecycle.BlobRetentionDays)?has_content?then(
          getStorageBlobServiceDeleteRetentionPolicy(solution.Lifecycle.BlobRetentionDays),
          {}
        )
      automaticSnapshotPolicyEnabled=(solution.Lifecycle.BlobAutoSnapshots)!false
      dependsOn=
        [
          getReference(accountId, accountName)
        ]
    /]

    [#-- Create All Registry Containers --]
    [#list registries?values as registry]

      [@createBlobServiceContainer
        id=registry.Id
        name=registry.Name
        publicAccess="None"
        dependsOn=
          [
            getReference(accountId, accountName),
            getReference(blobId, blobName)
          ]
      /]
    [/#list]

    [#-- Subcomponents --]
    [#list occurrence.Occurrences![] as subOccurrence]

      [#local subCore = subOccurrence.Core]
      [#local subSolution = subOccurrence.Configuration.Solution]
      [#local subResources = subOccurrence.State.Resources]

      [#-- storage containers --]
      [#if subCore.Type == BASELINE_DATA_COMPONENT_TYPE]
        [#local containerId = subResources["container"].Id]
        [#local containerName = subResources["container"].Name]

        [#if (deploymentSubsetRequired(BASELINE_COMPONENT_TYPE, true))]

          [#if subSolution.Role == "appdata"]
            [#local publicAccess = "Container"]
          [#elseif subSolution.Role == "operations"]
            [#local publicAccess = "Blob"]
          [#else]
            [#local publicAccess = "None"]
          [/#if]

          [@createBlobServiceContainer
            id=containerId
            name=containerName
            publicAccess=publicAccess
            dependsOn=
              [
                getReference(accountId, accountName),
                getReference(blobId, blobName)
              ]
          /]
        [/#if]
      [/#if]

      [#-- Keys --]
      [#if subCore.Type == BASELINE_KEY_COMPONENT_TYPE]

        [#switch subSolution.Engine]
          [#case "cmk"]

            [#local keyPair = subResources["cmk"]]

              [#-- Generate & Import CMK into keyvault --]

              [@createKeyVaultKey
                id=keyPair.Id
                name=formatAzureResourceName(
                      keyPair.Name,
                      AZURE_KEYVAULT_KEY_RESOURCE_TYPE, 
                      keyvault.Name
                    )
                parentId=keyvault.Id
                keyType="RSA"
                keySize="2048"
                dependsOn=[getReference(keyvault.Id, keyvault.Name)]
              /]

          [#break]
          [#case "ssh"]

            [#local localKeyPairId = subResources["localKeyPair"].Id]
            [#local localKeyPairPublicKey = subResources["localKeyPair"].PublicKey]
            [#local localKeyPairPrivateKey = subResources["localKeyPair"].PrivateKey]

            [#local vmKeyPair = subResources["vmKeyPair"]]

            [#if deploymentSubsetRequired("epilogue")]

              [#-- Generate & Import SSH credentials into keyvault --]

              [@addToDefaultBashScriptOutput
                content=[
                  "function az_manage_ssh_credentials() {"
                  "  info \"Checking SSH credentials ...\"",
                  "  #",
                  "  # Create SSH credential for the segment",
                  "  mkdir -p \"$\{SEGMENT_OPERATIONS_DIR}\"",
                  "  az_create_ssh_keypair \"$\{SEGMENT_OPERATIONS_DIR}\" " +
                      "\"" + regionId + "\" " +
                      "\"" + accountObject.Id + "\" || return $?",
                  "  #",
                  "  # Upload to keyvault if required.",
                  "  AZ_CHK_SECRET=$(az_check_vaultitem" + " " +
                      "\"" + keyvault.Name + "\" " +
                      "\"" + vmKeyPair.Name + "PublicKey" + "\")",
                  "  if [[ $\{AZ_CHK_SECRET} " +
                  "           = \"does not have secrets get permission on key vault\" ]]; then",
                  "    fatal \"The deployment user is not a member of the specified keyVault admin group\"",
                  "    return 1",
                  "  fi",
                  "  if [[ $\{AZ_CHK_SECRET} " +
                  "         = *NotFound* ]]; then",
                  "     pem_file=\"$\{SEGMENT_OPERATIONS_DIR}/" + localKeyPairPublicKey + ".plaintext.pub" + "\"",
                  "     az_add_secret" + " " +
                            "\"" + keyvault.Name + "\" " +
                            "\"" + vmKeyPair.Name + "PublicKey" + "\" " +
                            "\"$\{pem_file}\"",
                  "  fi",
                  "  AZ_CHK_SECRET=$(az_check_vaultitem" + " " +
                  "\"" + keyvault.Name + "\" " +
                  "\"" + vmKeyPair.Name + "PrivateKey" + "\")",
                  "  if [[ $\{AZ_CHK_SECRET} " +
                  "         = *NotFound* ]]; then",
                  "     pem_file=\"$\{SEGMENT_OPERATIONS_DIR}/" + localKeyPairPrivateKey + ".plaintext" + "\"",
                  "     az_add_secret" + " " +
                            "\"" + keyvault.Name + "\" " +
                            "\"" + vmKeyPair.Name + "PrivateKey" + "\" " +
                            "\"$\{pem_file}\"",
                  "  fi",
                  "  #"
                ] +
                pseudoArmStackOutputScript(
                  "SSH Key Pair",
                  {
                    vmKeyPair.Id : vmKeyPair.Name,
                    formatId(keyvault.Name, "Name") : keyvault.Name
                  },
                  "keypair"
                ) +
                [
                  " return 0"
                  "}",
                  "#",
                  "case $\{DEPLOYMENT_OPERATION} in",
                  "  delete)",
                  "  AZ_CHK_SECRET=$(az_check_vaultitem" + " " +
                  "\"" + keyvault.Name + "\" " +
                  "\"" + vmKeyPair.Name + "PublicKey" + "\")",
                  "  if [[ ! $\{AZ_CHK_SECRET} = *NotFound* ]]; then",
                  "    az_delete_vaultitem \"" + keyvault.Name + "\" \"" + vmKeyPair.Name + "PublicKey" + "\"",
                  "  fi",
                  "  AZ_CHK_SECRET=$(az_check_vaultitem" + " " +
                  "\"" + keyvault.Name + "\" " +
                  "\"" + vmKeyPair.Name + "PrivateKey" + "\")",
                  "  if [[ ! $\{AZ_CHK_SECRET} = *NotFound* ]]; then",
                  "    az_delete_vaultitem \"" + keyvault.Name + "\" \"" + vmKeyPair.Name + "PrivateKey" + "\"",
                  "  fi",
                  "    ;;",
                  "  create|update)",
                  "    az_manage_ssh_credentials || return $?",
                  "    ;;",
                  "esac"
                ]
              /]

            [/#if]
          [#break]
        [/#switch]

        [#-- Determine the IPAddressGroups for the KeyVault rules --]
        [#local keyVautlNetworkAddressGroups = subSolution.IPAddressGroups]
        [#list keyVautlNetworkAddressGroups as group]
          [#local keyVaultIPRuleGroups += [group]]
        [/#list]

      [/#if]
    [/#list]

    [#if deploymentSubsetRequired("prologue", false)]
      [#list keyVaultAdmins as adminGrp ]
        [#local adminId = formatId(keyvault.Id,adminGrp)]
        [@addToDefaultBashScriptOutput
          content=
          [
            "case $\{DEPLOYMENT_OPERATION} in",
            "  create|update)",
            "    ADMINGRP=$(az role definition list --name "+adminGrp+")",
            "    if [[ $\{#ADMINGRP[@]} -eq 0 ]] ; then",
            "      fatal \"Azure Administrator role does not exist: "+adminGrp+"\"",
            "      return 1",
            "    fi"
          ] +
          pseudoArmStackOutputScript(
            "AdministratorGroups",
            { adminId : adminGrp },
            "admingrp"
          ) +
          [
            "       ;;",
            "       esac"
          ]
        /]
      [/#list]
    [/#if]

    [#-- Create keyvault after generating rules --]

    [#local keyVaultIpRules = []]
    [#local keyVaultRuleCIDRs = getGroupCIDRs(getUniqueArrayElements(keyVaultIPRuleGroups))]
    [#list keyVaultRuleCIDRs as cidr]
      [#local keyVaultIpRules += [{"value" : cidr}]]
    [/#list]

    [#-- KeyVault Access Policy to allow Azure Admins access to KeyVault--]
    [#local defaultKeyVaultPermissions = getKeyVaultAccessPolicyPermissions(
      ["Get","List","Update","Create","Import","Delete","Recover","Backup","Restore"],
      ["Get","List","Set","Delete","Recover","Backup","Restore"],
      ["Get","List","Update","Create","Import","Delete","Recover","Backup","Restore","ManageContacts","ManageIssuers","GetIssuers","ListIssuers","SetIssuers","DeleteIssuers"]
    )]

    [#local keyvaultAdminsId = getOccurrenceSettingValue(
      occurrence,
      [
        ["azure", "administrators", "group"],
        ["aad", "administrators", "group"],
        ["azure", "admins"],
        ["aad", "admins"],
        [productName, "administrators"],
        [productName, "admins"]
      ],
      true
    )]

   [#if ! keyVaultAdmins?has_content ]
      [@fatal
        message="No KeyVault Admins have been defined"
        context="To create a keyvault create a new group or user Id and add it to azure:AdministratorGroups"
      /]
    [/#if]

    [#local keyVaultAccessRules = []]
    [#list keyVaultAdmins as keyvaultAdmin ]

        [#local keyVaultAccessRules += [ getKeyVaultAccessPolicyObject(
        tenantId,
        keyvaultAdmin,
        defaultKeyVaultPermissions
      ) ]]
    [/#list]

    [@createKeyVault
      id=keyvault.Id
      name=keyvault.Name
      location=regionId
      properties=
        getKeyVaultProperties(
          tenantId,
          getKeyVaultSku("A", "standard"),
          keyVaultAccessRules,
          "",
          true,
          true,
          true,
          true,
          "default",
          false,
          getNetworkAcls("Deny", keyVaultIpRules, [], "AzureServices")
        )
    /]

[/#macro]
