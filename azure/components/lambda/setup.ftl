[#ftl]

[#macro azure_lambda_arm_generationcontract_application occurrence]
    [@addDefaultGenerationContract subsets=["template", "epilogue"] /]
[/#macro]

[#macro azure_lambda_arm_setup_application occurrence]

    [@debug message="Entering Function ARM Setup" context=occurrence enabled=false /]

    [#local core = occurrence.Core]
    [#local solution = occurrence.Configuration.Solution]
    [#local resources = occurrence.State.Resources]

    [#-- Baseline Links --]
    [#local baselineLinks = getBaselineLinks(occurrence, [ "OpsData"], false, false)]
    [#local baselineAttributes = baselineLinks["OpsData"].State.Attributes]

    [#local storageAccountId = getExistingReference(baselineAttributes["ACCOUNT_ID"], "", "", "", "")]
    [#local storageAccountName = baselineAttributes["ACCOUNT_NAME"]]

    [#list occurrence.Occurrences![] as subOccurrence]

        [#local subCore = subOccurrence.Core]
        [#local subSolution = subOccurrence.Configuration.Solution]
        [#local subResources = subOccurrence.State.Resources]
        [#local function = subResources["function"]]

        [#local appSettings = []]

        [#local fragment = getOccurrenceFragmentBase(subOccurrence)]
        [#local contextLinks = getLinkTargets(subOccurrence)]
        [#assign _context =
            {
                "Id" : fragment,
                "Name" : fragment,
                "Instance" : subCore.Instance.Id,
                "Version" : subCore.Version.Id,
                "DefaultEnvironment" : defaultEnvironment(subOccurrence, contextLinks, baselineLinks),
                "Environment" : {},
                "ContextSettings" : {},
                "Links" : contextLinks,
                "BaselineLinks" : baselineLinks,
                "DefaultCoreVariables" : false,
                "DefaultEnvironmentVariables" : true,
                "DefaultLinkVariables" : false,
                "DefaultBaselineVariables" : false
            }
        ]
        [#if subSolution.Fragment?has_content ]
            [#local fragmentId = formatFragmentId(_context)]
            [#include fragmentList?ensure_starts_with("/")]
        [/#if]
        [#list getFinalEnvironment(occurrence, _context).Environment as key,value]
            [#local appSettings += [getWebAppSettingsPair(key, value)]]
        [/#list]

        [#-- Setting Kind here to make it easier to support Windows functionapps at a later time --]
        [#local functionKind = "functionapp,linux"]

        [#-- App Settings --]
        [#local runTimeSettings = getWebAppRunTime(subSolution.RunTime)]

        [#local mandatoryAppSettings =
            {
                "AzureWebJobsStorage" : formatAzureStorageAccountConnectionStringReference(storageAccountId, storageAccountName, "keys[0].value"),
                "FUNCTIONS_EXTENSION_VERSION" : runTimeSettings.ExtensionVersion,
                "FUNCTIONS_WORKER_RUNTIME" : runTimeSettings.WorkerRunTime,
                "WEBSITE_RUN_FROM_PACKAGE" : 1
            } +
            attributeIfTrue("WEBSITE_NODE_DEFAULT_VERSION", runTimeSettings.DefaultVersion?has_content!false, runTimeSettings.DefaultVersion!"")
        ]

        [#list mandatoryAppSettings as settingName,settingValue]
            [#local appSettings += [getWebAppSettingsPair(settingName, settingValue)]]
        [/#list]

        [#if deploymentSubsetRequired("lambda", true)]
            [#-- create the Function on Consumption plan     --]
            [#-- linux function apps must have reserved=true --]
            [@createWebApp
                id=function.Id
                name=function.Name
                location=regionId
                kind=functionKind
                reserved=true
                appSettings=appSettings
                siteConfigLinuxFXVersion=runTimeSettings.LinuxFXVersion!""
            /]
        [/#if]

        [#if deploymentSubsetRequired("epilogue", false)]
            [#-- Epilogue - Publish Function --]
            [@addToDefaultBashScriptOutput
                content=
                    [#-- copy zip function app locally --]
                    getBuildScript(
                        "functionFiles",
                        "lambda",
                        productName,
                        occurrence,
                        function.Name + ".zip",
                        getExistingReference("ResourceGroup")
                    ) +
                    [
                        "    info \"$\{DEPLOYMENT_OPERATION} Function App ... \"",
                        "    az_functionapp_deploy" +
                            " \"" + getExistingReference("Subscription") + "\"" +
                            " $\{RESOURCE_GROUP}" +
                            " \"" + function.Name + "\"" +
                            " \"" + "$\{functionFiles[0]}" + "\"" +
                            " $\{DEPLOYMENT_OPERATION} || return $?"
                    ]
            /]
        [/#if]
    [/#list]

[/#macro]
