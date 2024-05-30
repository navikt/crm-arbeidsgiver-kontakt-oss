#!/bin/bash

SCRIPT_PATH=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
cd $SCRIPT_PATH/..

# Check exit code function
error() {
    echo ""
    if [[ $1 -eq 0 ]]; then
        echo "Installation completed."
        echo ""
        exit $1
    else
        if [[ -n $2 ]]; then
            echo "$2"
            echo ""
        fi
        
        echo "Installation failed."
        echo ""
        exit $1
    fi
}

isPackageAliasInstalled() {
    local package_alias="$1"
    installed_aliases=$(sf package installed list --target-org "$org_alias" --json | jq -r '.result[] | .SubscriberPackageName')

    if [[ $installed_aliases == *"$package_alias"* ]]; then
        echo "Package alias $package_alias is already installed."
        return 0
    else
        return 1
    fi
}


getLatestPackageVersionId() {
    local package_id="$1"
    package_versions=$(sf package version list --packages "$package_id" --concise --json)
    latest_version_id=$(echo "$package_versions" | jq -r '.result | sort_by(.MajorVersion, .MinorVersion, .PatchVersion, .BuildNumber) | last | .SubscriberPackageVersionId')

    if [[ -z "$latest_version_id" || "$latest_version_id" == "null" ]]; then
        echo "Error: Unable to find latest package version for package ID: $package_id."
        exit 1
    fi

    # Extract the version ID starting with 04t
    latest_version_id=$(echo "$latest_version_id" | grep -oE '04t[a-zA-Z0-9]{15}')
    
    echo "$latest_version_id"
}

# Function to install dependencies
installDependencies() {
    # Check if packageAliases is present in sfdx-project.json
    if ! jq -e '.packageAliases' sfdx-project.json > /dev/null; then
        echo "No packageAliases found in sfdx-project.json. Skipping dependency installation."
        return
    fi

    for package_alias in $(jq -r '.packageAliases | keys[]' sfdx-project.json); do
        echo "Checking package alias: $package_alias"
        if isPackageAliasInstalled "$package_alias"; then
            continue
        fi
        
        package_id=$(jq -r --arg alias "$package_alias" '.packageAliases[$alias]' sfdx-project.json)
        echo "Package ID for $package_alias: $package_id"

        if [ -z "$package_id" ]; then
            echo "Warning: Package alias $package_alias not found in sfdx-project.json. Skipping..."
            continue
        fi

        package_version_id=$(getLatestPackageVersionId "$package_id")
        echo "Latest package version ID for $package_alias: $package_version_id"

        echo "Installing package: $package_alias (version ID: $package_version_id)"
        
        sf package install --package "$package_version_id" --installation-key "$secret" --target-org "$org_alias" --wait 10 --publish-wait 10 --noprompt || {
            echo "Error: Failed to install package $package_alias (version ID: $package_version_id)"
            exit 1
        }
    done

    echo "All dependencies have been installed successfully."
}

deployingMetadata() {
    if [[ $npm_config_without_deploy ]]; then
        echo "Skipping..."
    else
        sf project deploy start -r --ignore-errors || { error $? '"sf project deploy start" command failed.'; }
    fi
}

assignPermission() {
    sf org assign permset \
    --name Arbeidsgiver_base \
    --name Arbeidsgiver_opportunity \
    --name Arbeidsgiver_NavApp \
    || { error $? '"sf org assign permset" command failed.'; }
}

insertingTestData() {
    sf data import tree --plan dummy-data/plan.json || { error $? '"sf data import tree" command failed.'; }
}

runPostInstallScripts() {
    sf apex run --file ./scripts/assignRecordTypes.cls || { error $? '"sf apex run" command failed for Apex class: "assignRecordTypes".'; }
    sf apex run --file ./scripts/relateNavUnitToAccount.cls || { error $? '"sf apex run" command failed for Apex class: "relateNavUnitToAccount".'; }
    sf apex run --file ./scripts/setQueueIdOnNavUnit.cls || { error $? '"sf apex run" command failed for Apex class: "relateNavUnitToAccount".'; }
}

publishCommunity() {
    if [[ $npm_config_without_publish ]]; then
        echo "Skipping..."
    else
        sf community publish --name "Kontaktskjema" || { error $? '"sf community publish" command failed for community: "Kontaktskjema".'; }
    fi
}

openOrg() {
    if [[ -n $npm_config_open_in ]]; then
        sf org open --browser "$npm_config_open_in" --path "lightning/app/standard__LightningService" || { error $? '"sf org open" command failed.'; }
    else
        sf org open --path "lightning/app/standard__LightningService" || { error $? '"sf org open" command failed.'; }
    fi
}

info() {
    echo "Usage: npm run mac:build [options]"
    echo ""
    echo "Options:"
    echo "  --package-key=<key>         Package key to install - THIS IS REQUIRED"
    echo "  --org-alias=<alias>         Alias for the scratch org"
    echo "  --org-duration=<days>       Duration of the scratch org"
    echo "  --without-deploy            Skip deploy"
    echo "  --without-publish           Skip publish of community: \"arbeidsgiver-dialog\""
    echo "  --open-in=<option>          Browser where the org opens."
    echo "                              <options: chrome|edge|firefox>"
    echo "  --start-step=<step-nummer>  Start from a specific step"
    echo "  --step=<step-nummer>        Run a specific step"
    echo "                              <steps: clean=1|create=2|dependencies=3|deploy=4|permissions=5|test data=6|run scripts=7|publishing site=8|open=9>"
    echo "                              <steps: clean=1|create=2|dependencies=3|deploy=4|permissions=5|test data=6|open=7>"
    echo "  --info                      Show this help"
    echo ""
    exit 0
}

if [[ $npm_config_info ]]; then
    info
elif [[ -z $npm_config_package_key ]] && [[ -z $npm_config_step ]] && [[ -z $npm_config_start_step ]]; then
    echo "Package key is required."
    echo ""
    info
fi

sf plugins inspect @dxatscale/sfpowerscripts >/dev/null 2>&1 || { 
    echo >&2 "\"@dxatscale/sfpowerscripts\" is required, but it's not installed."
    echo "Run \"sf plugins install @dxatscale/sfpowerscripts\" to install it."
    echo ""
    echo "Aborting...."
    echo ""
    exit 1
}
sf plugins inspect sfdmu >/dev/null 2>&1 || {
    echo >&2 "\"sfdmu\" is required, but it's not installed."
    echo "Run \"sf plugins install sfdmu\" to install it."
    echo ""
    echo "Aborting..."
    echo ""
    exit 1
}

command -v jq >/dev/null 2>&1 || {
    echo >&2 "\"jq\" is required, but it's not installed."
    echo "Run \"brew install jq\" to install it if you have Homebrew installed."
    echo ""
    echo "Aborting..."
    echo ""
    exit 1
}

org_alias=$(sf org:display --verbose --json | jq -r '.result.alias')
secret=$npm_config_package_key
devHubAlias=$(sf config get target-dev-hub --json | jq -r '.result[0].value')
    
echo "Current scratch org alias is: $org_alias"
echo "Current devhub alias is: $devHubAlias"

operations=(
    #cleaningPreviousScratchOrg
    #creatingScratchOrg
    installDependencies
    deployingMetadata
    assignPermission
    insertingTestData
    runPostInstallScripts
    publishCommunity
    openOrg
)

operationNames=(
    #"Cleaning previous scratch org"
    #"Creating scratch org"
    "Installing dependencies"
    "Deploying/Pushing metadata"
    "Assigning permissions"
    "Inserting test data"
    "Running post install scripts"
    "Publishing arbeidsgiver-dialog site"
    "Opening org"
)

if  [[ -n $npm_config_step ]] && [[ -z $npm_config_start_step ]]; then
    if [[ "$npm_config_step" =~ ^[0-9]+$ ]] && [[ $npm_config_step -ge 1 ]]; then
        j=$((npm_config_step - 1))
    else
        echo "Invalid step number: $npm_config_step"
        exit 1
    fi

    echo "Running Step $npm_config_step/${#operations[@]}: ${operationNames[$j]}..."
    ${operations[$j]}
    echo ""
    exit 0
fi

for i in ${!operations[@]}; do
    echo "Step $((i+1))/${#operations[@]}: ${operationNames[$i]}..."
    if [[ $((i+1)) -ge $npm_config_start_step ]]; then
        ${operations[$i]}
    else
        echo "Skipping..."
    fi

    echo ""
done

error $?