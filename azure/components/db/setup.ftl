[#ftl]

[#macro azure_db_arm_deployment_generationcontract occurrence]
    [@addDefaultGenerationContract subsets=["prologue", "parameters", "template"] /]
[/#macro]

[#macro azure_db_arm_deployment occurrence]

    [@debug message="Entering" context=occurrence enabled=false /]

    [#local core       = occurrence.Core]
    [#local solution   = occurrence.Configuration.Solution]
    [#local resources  = occurrence.State.Resources]
    [#local attributes = occurrence.State.Attributes]

    [#local engine = solution.Engine]
    [#local engineVersion = solution.EngineMinorVersion?has_content?then(
    solution.EngineVersion + solution.EngineMinorVersion,
    solution.EngineVersion)]

    [#-- Resources --]
    [#local server   = resources["dbserver"]]
    [#local db       = resources["database"]]
    [#local configs  = resources["dbconfigs"]]
    [#local vnetRule = resources["dbvnetrule"]]

    [#local masterAccount      = attributes["USERNAME"]?keep_before("@")]
    [#local masterSecret       = attributes["SECRET"]]
    [#local masterSecretId     = formatId(db.Id, SECRET_ATTRIBUTE_TYPE)]
    [#local masterSecretLength = solution.GenerateCredentials.CharacterLength]

    [#-- Hibernation --]
    [#local hibernate  = solution.Hibernate.Enabled && isOccurrenceDeployed(occurrence)]
    [#local createMode = "Default"]

    [#-- Baseline Links --]
    [#local baselineLinks      = getBaselineLinks(occurrence, ["SSHKey"], false, false)]
    [#local baselineAttributes = baselineLinks["SSHKey"].State.Attributes]
    [#local keyVaultId         = baselineAttributes["KEYVAULT_ID"]]
    [#local keyVaultName       = getReference(keyVaultId, "", NAME_ATTRIBUTE_TYPE)]

    [#-- Network Resources --]
    [#local occurrenceNetwork = getOccurrenceNetwork(occurrence)]
    [#local networkLink       = occurrenceNetwork.Link!{}]
    [#local networkLinkTarget = getLinkTarget(occurrence, networkLink)]
    [#if ! networkLinkTarget?has_content]
        [@fatal message="Network could not be found" context=networkLink /]
        [#return]
    [/#if]
    [#local networkResources = networkLinkTarget.State.Resources]
    [#local subnet = getSubnet(core.Tier, networkResources)]

    [#-- Credential Management --]
    [#if !hibernate]
        [#if deploymentSubsetRequired("prologue", false)]
            [#if createMode = "Default"]

                [@addToDefaultBashScriptOutput
                    content=[
                        "  # Check Keyvault for Master Secret",
                        "  if [[ $(az_check_vaultitem" + " " +
                            "\"" + keyVaultName + "\" " +
                            "\"" + masterSecret + "\") " +
                            "= *SecretNotFound* ]]; then",
                        "   info \"Generating Master Password... \"",
                        "   master_password=\"\"",
                        "   while ! [[ \"$\{master_password}\" =~ [[:alpha:]] && \"$\{master_password}\" =~ [[:digit:]] ]]; do",
                        "   master_password=\"$(generateComplexString " +
                            "\"" + masterSecretLength + "\" )\"",
                        "   done",
                        "   info \"Uploading Master Password to Keyvault... \"",
                        "    az_add_secret" + " " +
                            "\"" + keyVaultName + "\" " +
                            "\"" + masterSecret + "\" " +
                            "\"$\{master_password}\" || return $?",
                        "  #"
                    ] +
                    pseudoArmStackOutputScript(
                        "DB Master Secret",
                        { masterSecretId : masterSecret },
                        SECRET_ATTRIBUTE_TYPE
                    ) +
                    ["fi"]
                /]
            [/#if]
        [/#if]
    [/#if]

    [#-- Server Settings --]
    [#local sku = getProcessor(occurrence, "db", solution.Profiles.Processor)]

    [#-- Resource Creation --]
    [#if !hibernate]
        [#switch engine]
            [#case "postgres"]
                [@createPostgresServer
                    id=server.Id
                    name=server.Name
                    location=regionId
                    createMode=createMode
                    adminName=masterAccount
                    adminSecret=masterSecret
                    keyvaultId=keyVaultId
                    skuName=sku.Processor
                    version=engineVersion
                    backupRetentionDays=solution.Backup.RetentionPeriod
                    storageGB=solution.Size
                    storageAutogrow=solution["azure:AutoGrow"]
                /]

                [#local configReferences = []]
                [#list configs as key,value]
                    [#local conf = solution.DBParameters[key]]
                    [@createPostgresServerConfiguration
                        id=value.Id
                        name=value.Name
                        source=key
                        value=conf
                        dependsOn=[server.Reference]
                    /]
                    [#local configReferences += [value.Reference]]
                [/#list]

                [@createPostgresServerDatabase
                    id=db.Id
                    name=db.Name
                    dependsOn=[
                        server.Reference
                    ] + configReferences
                /]

                [#-- TODO(rossmurr4y):
                    refactor `ignoreMissingEndpoint` alongside Service Endpoints.
                --]
                [@createPostgresServerVNetRule
                    id=vnetRule.Id
                    name=vnetRule.Name
                    subnetId=getReference(subnet.Id, subnet.Name)
                    ignoreMissingEndpoint=true
                    dependsOn=[
                        server.Reference
                    ]
                /]
                [#break]

            [#case "mysql"]
                [@createMySqlServer
                    id=server.Id
                    name=server.Name
                    location=regionId
                    createMode=createMode
                    adminName=masterAccount
                    adminSecret=masterSecret
                    keyvaultId=keyVaultId
                    skuName=sku.Processor
                    version=engineVersion
                    backupRetentionDays=solution.Backup.RetentionPeriod
                    storageGB=solution.Size
                    storageAutogrow=solution["azure:AutoGrow"]
                /]

                [#local configReferences = []]
                [#list configs as key,value]
                    [#local conf = solution.DBParameters[key]]
                    [@createMySqlServerConfiguration
                        id=value.Id
                        name=value.Name
                        source=key
                        value=conf
                        dependsOn=[server.Reference]
                    /]
                    [#local configReferences += [value.Reference]]
                [/#list]

                [@createMySqlServerDatabase
                    id=db.Id
                    name=db.Name
                    dependsOn=[
                        server.Reference
                    ] + configReferences
                /]

                [@createMySqlServerVNetRule
                    id=vnetRule.Id
                    name=vnetRule.Name
                    subnetId=getReference(subnet.Id, subnet.Name)
                    ignoreMissingEndpoint=true
                    dependsOn=[
                        server.Reference
                    ]
                /]
                [#break]

        [/#switch]
    [/#if]
[/#macro]
