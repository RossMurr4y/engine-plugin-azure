[#ftl]

[#macro azure_computecluster_arm_generationcontract_application occurrence ]
    [@addDefaultGenerationContract subsets=[ "parameters", "template"] /]
[/#macro]

[#macro azure_computecluster_arm_setup_application occurrence]
    [@debug message="Entering" context=occurrence enabled=false /]

    [#local core          = occurrence.Core]
    [#local solution      = occurrence.Configuration.Solution]
    [#local resources     = occurrence.State.Resources]
    [#local links         = solution.Links]
    [#local buildSettings = occurrence.Configuration.Settings.Build]

    [#-- Resources --]
    [#local role       = resources["role"]]
    [#local scaleSet   = resources["scaleSet"]]
    [#local nic        = resources["networkInterface"]]
    [#local nsgRules   = resources["nsgRules"]]
    [#local autoscale  = resources["autoscale"]]
    [#local extension  = resources["bootstrap"]]
    [#local publicIp   = resources["publicIp"]]

    [#-- Profiles --]
    [#local sku       = getSkuProfile(occurrence, core.Type)]
    [#local vmImage   = getVMImageProfile(occurrence, core.Type)]
    [#local vmStorage = getStorage(occurrence, core.Type)]

    [#-- Baseline Lookup --]
    [#local baselineLinks     = getBaselineLinks(occurrence, [ "AppData", "SSHKey" ], false, false)]
    [#local dataAttributes    = baselineLinks["AppData"].State.Attributes]
    [#local keyAttributes     = baselineLinks["SSHKey"].State.Attributes]
    [#local baselineResources = baselineLinks["SSHKey"].State.Resources]
    [#local sshKey            = baselineResources["vmKeyPair"]]
    [#local storageName       = dataAttributes["ACCOUNT_NAME"]]
    [#local storageAccountId  = dataAttributes["ACCOUNT_ID"]]
    [#local keyvaultId        = keyAttributes["KEYVAULT_ID"]]

    [#-- Default Storage Config --]
    [#local stageStorage = 
        {
            "Account" : {
                "Id" : storageAccountId,
                "Name" : storageName
            },
            "Container" : getRegistryPrefix("scripts", occurrence)?remove_ending("/"),
            "BlobName" : core.ShortName + ".zip",
            "BlobPath" : formatRelativePath(
                            productName,
                            buildSettings["BUILD_UNIT"].Value,
                            buildSettings["BUILD_REFERENCE"].Value,
                            core.ShortName + ".zip")
        }
    ]

    [#-- Network Lookup --]
    [#local occurrenceNetwork = getOccurrenceNetwork(occurrence)]
    [#local networkLink = occurrenceNetwork.Link!{} ]
    [#local networkLinkTarget = getLinkTarget(occurrence, networkLink, false) ]

    [#if ! networkLinkTarget?has_content ]
        [@fatal message="Network could not be found" context=networkLink /]
        [#return]
    [/#if]

    [#local networkResources = networkLinkTarget.State.Resources]
    [#local subnet           = networkResources["subnets"][core.Tier.Id]["subnet"]]
    [#local nsg              = networkResources["networkSecurityGroup"]]

    [#-- Ports --]
    [#local appGatewayBackendAddressPoolIds = []]
    [#list solution.Ports?values as port ]
        [#if port.LB.Configured]
            [#local lbLink = getLBLink(occurrence, port)]
            [#if isDuplicateLink(links, lbLink) ]
                [@fatal
                    message="Duplicate Link Name"
                    context=links
                    detail=lbLink /]
                [#continue]
            [/#if]
            [#local links += lbLink]
        [/#if]
    [/#list]

    [#-- Links --]
    [#list links?values as link]

        [#local linkTarget = getLinkTarget(occurrence, link)]

        [#if !linkTarget?has_content]
            [#continue]
        [/#if]

        [#local linkTargetCore = linkTarget.Core]
        [#local linkTargetConfiguration = linkTarget.Configuration]
        [#local linkTargetResources = linkTarget.State.Resources]
        [#local linkTargetAttributes = linkTarget.State.Attributes]
        [#local linkTargetSettings = linkTarget.Configuration.Environment.General]

        [#switch linkTargetCore.Type]
            [#case LB_PORT_COMPONENT_TYPE]
                [#switch linkTargetAttributes["ENGINE"]]
                    [#case "application"]
                        [#local appGatewayBackendAddressPoolIds +=
                            [linkTargetResources["backendAddressPool"].Id]]
                        [#break]
                [/#switch]
                [#break]

            [#case S3_COMPONENT_TYPE]
                [#local stageStorage = 
                    {
                        "Account" : {
                            "Id" : linkTargetAttributes["ACCOUNT_ID"],
                            "Name" : linkTargetAttributes["ACCOUNT_NAME"]
                        },
                        "Container" : linkTargetAttributes["CONTAINER_NAME"],
                        "BlobName" : core.ShortName + ".zip",
                        "BlobPath" : formatRelativePath(
                                        productName,
                                        buildSettings["BUILD_UNIT"].Value,
                                        buildSettings["BUILD_REFERENCE"].Value,
                                        core.ShortName + ".zip")
                    }
                ]

                [#break]

            [#case DB_COMPONENT_TYPE]

                [#local dbSecrets = getSettingSecrets(linkTargetSettings, "ENV") +
                    [{ "DB_PASSWORD" : linkTargetAttributes["SECRET"] }] ]
                    
                [#list dbSecrets as dbSecret]
                    [#list dbSecret?values as secretName]
                        [@createKeyVaultParameterLookup
                            secretName=secretName
                            vaultId=keyvaultId
                        /]
                    [/#list]
                [/#list]

                [#local dbDetails = 
                    [{ "DB_NAME" : linkTargetAttributes["DB_NAME"] },
                    { "DB_USERNAME" : linkTargetAttributes["USERNAME"] } ]]

                [#break]

        [/#switch]

    [/#list]

    [#-- Public IP --]
    [#if publicIp??]
        [@createPublicIPAddress
            id=publicIp.Id
            name=publicIp.Name
            location=regionId
            allocationMethod="Static"
            dependsOn=[]
        /]
    [/#if]

    [#-- Scaling Policies --]
    [#local profiles = []]

    [#list solution.azure\:ScalingProfiles as profileName, profile]
        [#local rules = []]
        [#list profile.ScalingRules as name, rule]
            [#local rules += [getAutoScaleRule(
                rule.MetricName,
                scaleSet.Reference,
                rule.TimeGrain,
                rule.Statistic,
                rule.TimeWindow,
                rule.TimeAggregation,
                rule.Operator,
                rule.Threshold,
                rule.Direction,
                rule.ActionType,
                rule.Cooldown,
                rule.ActionValue!""
            )]]
        [/#list]

        [#local profiles +=
            [getAutoScaleProfile(
                profileName,
                profile.MinCapacity,
                profile.MaxCapacity,
                profile.DefaultCapacity,
                rules
            )]]

    [/#list]

    [@createAutoscaleSettings
        id=autoscale.Id
        name=autoscale.Name
        location=regionId
        targetId=scaleSet.Reference
        profiles=profiles
        dependsOn=[scaleSet.Reference]
    /]

    [#-- Network Security Group Rules --]
    [#local priority = 200]
    [#list nsgRules?values as rule]
        
        [#local destination = getReference(
            publicIp.Id,
            publicIp.Name,
            "", "", "", "",
            true,
            "properties.ipAddress")]
        [@createNetworkSecurityGroupSecurityRule
            id=rule.Id
            name=rule.Name
            nsgName=nsg.Name
            access="allow"
            direction="Inbound"
            sourceAddressPrefix=rule.CIDR!""
            sourceAddressPrefixes=rule.CIDRs![]
            destinationAddressPrefix=destination
            destinationPortProfileName=rule.Port
            priority=priority
        /]
        [#local priority++]
    [/#list]

    [#-- Scale Set Config --]
    [#local username = getOccurrenceSettingValue(occurrence, "MASTER_USERNAME", !solution.Enabled)]
    [#local keySecretName = sshKey.Name + "PublicKey"]
    [@createKeyVaultParameterLookup
        secretName=keySecretName
        vaultId=keyvaultId
    /]

    [#local osConfig =
        getVirtualMachineProfileLinuxConfig(
            [getVirtualMachineProfileLinuxConfigPublicKey(
                "/home/" + username + "/.ssh/authorized_keys",
                getParameterReference(keySecretName)
            )]
        )]

    [#local nicIpConfigName = nic.Name + "ipConfig"]
    [#local nicIpConfig = 
        getIPConfiguration(
            nicIpConfigName,
            getExistingReference(subnet.Id),
            true, 
            publicIp.Reference, 
            "", "", [], "", "", "", "Dynamic", "IPv4", [],
            appGatewayBackendAddressPoolIds,
            lbBackendAddressPoolIds,
            lbInboundNatRuleIds
        )]

    [@createNetworkInterface
        id=nic.Id
        name=nic.Name
        location=regionId
        nsgId=nsg.Reference
        ipConfigurations=[nicIpConfig]
        dependsOn=(publicIp?has_content)?then([publicIp.Reference], [])
    /]

    [#local storageAccountType = [vmStorage.Tier, vmStorage.Replication]?join('_')]
    
    [#local vmProfile =
        getVirtualMachineProfile(
            storageAccountType,
            vmImage.Publisher,
            vmImage.Offering,
            vmImage.Image,
            getVirtualMachineNetworkProfile([
                getVirtualMachineNetworkProfileNICConfig(
                    nic.Reference,
                    nic.Name,
                    true,
                    [
                        getSubResourceReference(
                            getSubReference(
                                nic.Id,
                                nic.Name,
                                "ipConfigurations",
                                nicIpConfigName
                            )
                        ) + 
                        getIPConfiguration(nicIpConfigName, subnet.Reference)

                    ]
                )
            ]),
            osConfig,
            productName,
            username
        )
    ]

    [@createVMScaleSet
        id=scaleSet.Id
        name=scaleSet.Name
        identity={"type": "SystemAssigned"}
        location=regionId
        skuName=sku.Name
        skuTier=sku.Tier
        skuCapacity=sku.Capacity
        vmProfile=vmProfile
        dependsOn=publicIp?has_content?then([publicIp.Reference], [])
    /]

    [#-- Scale Set Registry Access --]
    [@createRoleAssignment
        id=role.Id
        name=role.Name
        roleDefinitionId=getRoleReference(role.Assignment)
        principalId=scaleSet.PrincipalId
        dependsOn=[scaleSet.Reference]
    /]

    [#-- Extensions --]
    [@addParametersToDefaultJsonOutput
        id="storage"
        parameter=formatAzureStorageAccountConnectionStringReference(
            stageStorage.Account.Id,
            stageStorage.Account.Name,
            "keys[0].value"
        )
    /]

    [@addParametersToDefaultJsonOutput id="container" parameter=stageStorage.Container /]
    [@addParametersToDefaultJsonOutput id="blob" parameter=stageStorage.BlobPath /]
    [@addParametersToDefaultJsonOutput id="file" parameter=stageStorage.BlobName /]
    [@armParameter name="storage" /]
    [@armParameter name="container" /]
    [@armParameter name="blob" /]
    [@armParameter name="file" /]

    [#-- Construct Index List & Concatenate Exec commands --]
    [#local indices = []]
    [#local extSettings = {}]
    [#local extProtectedSettings = {}]
    [#local commandsToExecute = []]
    [#local bootstrapProfile = getBootstrapProfile(occurrence, core.Type)]

    [#if (bootstrapProfile.Bootstraps)??]

        [#-- Inject ENV Variables --]
        [#if dbSecrets??]

            [#list dbSecrets as dbSecret]
                [#list dbSecret as key,secretName]
                    [#local secretCmd = 'echo ' + key?ensure_ends_with("=', parameters('" + secretName + "'), ") + "' | sudo tee -a /etc/environment > /dev/null'" ]
                    [#local commandsToExecute += [secretCmd]]
                [/#list]
            [/#list]

            [#list dbDetails as dbDetail]
                [#list dbDetail as key,value]
                    [#local cmd = 'echo ' + key + "=" + value + " | sudo tee -a /etc/environment > /dev/null'" ]
                    [#local commandsToExecute += [cmd]]
                [/#list]
            [/#list]

            [#local commandsToExecute += ["source /etc/environment'"]]
        [/#if]

        [#list bootstrapProfile.Bootstraps
            ?filter(x -> (bootstraps[x]).Index?has_content) as bootstrapName]
            [#local indices += [bootstraps[bootstrapName].Index]]
        [/#list]

    [/#if]
    [#local indices = indices?sort]
    
    [#local extensionScriptConfig = {}]
    [#list indices as index]

        [#local extConfig = getBootstrapByIndex(index)]

        [#list extConfig.ProtectedSettings?values as setting]
            [#if setting.Key == "commandToExecute"]
                [#local commandsToExecute += [setting.Value]]
            [#else]
                [#local extProtectedSettings += { setting.Key : setting.Value }]
            [/#if]
        [/#list]
        [#if extConfig.Settings??]
            [#list extConfig.Settings?values as setting]
                [#local extSettings += { setting.Key : setting.Value }]
            [/#list]
        [/#if]

        [#local extensionScriptConfig = 
            mergeObjects(extensionScriptConfig, extConfig)]

    [/#list]

    [#local extProtectedSettings = mergeObjects(
        extProtectedSettings,
        {} +
        attributeIfContent("commandToExecute", commandsToExecute, concatenate(commandsToExecute, ", ' && ")?ensure_starts_with("[concat('")?ensure_ends_with("')]"))
    )]

    [@createVMScaleSetExtension
        id=extension.Id
        name=extension.Name
        scriptConfig=extensionScriptConfig
        settings=extSettings
        protectedSettings=extProtectedSettings
        provisionAfterExtensions=provisionAfterExtensions
        dependsOn=[scaleSet.Reference]
    /]

[/#macro]
