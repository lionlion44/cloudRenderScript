#!/bin/bash

## TO DO ##
#   Add function to boot and shutdown computer at start and finish to use the least azure credit
bypass=false
startFrameOverrideBool=false
endFrameOverrideBool=false
versionOverrideBool=false
formatOverrideBool=false
while getopts ":bs:e:v:f:" opt; do
    case ${opt} in
        b )
            echo "Bypassing USD input transfer"
            bypass=true
            ;;
        s )
            echo "Overriding start frame"
            startFrameOverride=$OPTARG
            startFrameOverrideBool=true
            ;;
        e )
            echo "Overriding end frames"
            endFrameOverride=$OPTARG
            endFrameOverrideBool=true
            ;;
        v )
            echo "Overriding version"
            versionOverride=$OPTARG
            versionOverrideBool=true
            ;;
        f )
            echo "Overriding image format"
            formatOverride=$OPTARG
            formatOverrideBool=true
            ;;
        \? )
            echo "Invalid option: -$OPTARG" >&2
            ;;
        : )
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done
# Shift positional parameters
shift $((OPTIND -1))

# Project name
project=$1
shot=$2

# project file variables
projectDir="$HOME/Projects/Freelance/$project"
shotDir="$projectDir/USD_Shots/$shot"

# Check if project directory exists
if [[ ! -d "$projectDir" ]]; then
    echo "Error: Directory $projectDir does not exist." >&2
    exit 1
fi

# Check if shot directory exists
if [[ ! -d "$shotDir" ]]; then
    echo "Error: Directory $shotDir does not exist." >&2
    exit 1
fi

# Get version
max_version=0
# Loop through the files in the directory
mkdir -p $projectDir/Cloud_Inputs/
for file in "$projectDir/Cloud_Inputs"/*; do
    # Check if the file matches the shot pattern
    if [[ $file =~ ${shot}_v([0-9]+)\.zip ]]; then
        # Extract the version number
        version=${BASH_REMATCH[1]}
        # Update max_version if the extracted version is higher
        if [[ $((10#$version)) -gt $((10#$max_version)) ]]; then
            max_version=$version
        fi
    fi
done

# Calculate the next version number
next_version=$((10#$max_version + 1))

if [ "$bypass" = true ]; then
    next_version=$((10#$max_version))
fi

# Output the next version number
printf -v next_version_str "%02d" $next_version

if [ "$versionOverrideBool" = "true" ]; then
    printf -v next_version_str "%02d" $versionOverride
fi

start_time_zip=$(date +%s)

# zip scene
if [ "$bypass" = false ]; then
    7z a -tzip $projectDir/Cloud_Inputs/${shot}_v${next_version_str}.zip $shotDir/* -y
fi

end_time_zip=$(date +%s)


# set user and VM variables
usr=leoEvershed
vmName=linuxHeadlessVM
resourceGroup=mp_cloudRendering
keyDir="~/.ssh/$vmName.pem"

# Run the Azure CLI command and assign the output to the variable
ip=$(az network public-ip show -g $resourceGroup -n $vmName-ip --query "ipAddress" -o tsv)

# setup paths for vm
linuxShotPath="/home/$usr/Projects/$project/$shot/v${next_version_str}"
linuxOutputPath="$linuxShotPath/output"
ssh -i "$keyDir" $usr@$ip "mkdir -p $linuxOutputPath"

start_time_send=$(date +%s)
end_time_send=$(date +%s)
start_time_unzip=$(date +%s)
end_time_unzip=$(date +%s)

# transfer and unzip
if [ "$bypass" = false ]; then
    scp -i "$keyDir" $projectDir/Cloud_Inputs/${shot}_v${next_version_str}.zip $usr@$ip:$linuxShotPath
    end_time_send=$(date +%s)
    start_time_unzip=$(date +%s)
    ssh -i "$keyDir" $usr@$ip "7z x $linuxShotPath/${shot}_v${next_version_str}.zip -o$linuxShotPath/" -y
    end_time_unzip=$(date +%s)
fi

# licnese shit
ssh -i "$keyDir" $usr@$ip "cd /opt/hfs20.0.688/; source houdini_setup; sesictrl login --email arg <EMAIL> --password arg <PASSWORD>"

# Define image format
format=exr
if [ "$formatOverrideBool" = true ]; then
    format=$formatOverride
fi

# Get frame range from usd file
startTime=$(ssh -i "$keyDir" $usr@$ip "usdcat $linuxShotPath/$shot.usd | grep startTime | grep -oE '[0-9]+'")
endTime=$(ssh -i "$keyDir" $usr@$ip "usdcat $linuxShotPath/$shot.usd | grep endTime | grep -oE '[0-9]+'")
frames=$((endTime-startTime+1))

if [ "$startFrameOverrideBool" = true ] && (($startFrameOverride < $startTime)); then
    echo "Warning: The override start frame ($startFrameOverride) is less than the USD start frame ($startTime)."
    read -p "Do you want to continue? (y/n): " choice
    if [[ "$choice" != "y" ]]; then
        echo "Operation cancelled by user."
        exit 1
    fi
fi

if [ "$endFrameOverrideBool" = true ] && (($endFrameOverride > $endTime)); then
    echo "Warning: The override end frame ($endFrameOverride) is greater than the USD end frame ($endTime)."
    read -p "Do you want to continue? (y/n): " choice
    if [[ "$choice" != "y" ]]; then
        echo "Operation cancelled by user."
        exit 1
    fi
fi

# Override framerange if set in options
if [ "$startFrameOverrideBool" = true ] && [ "$endFrameOverrideBool" = true ]; then
    startTime=$startFrameOverride
    frames=$((endFrameOverride-startFrameOverride+1))
    endTime=$endFrameOverride
fi
if [ "$startFrameOverrideBool" = true ] && [ "$endFrameOverrideBool" = false ]; then
    startTime=$startFrameOverride
    frames=$((endTime-startFrameOverride+1))
fi
if [ "$startFrameOverrideBool" = false ] && [ "$endFrameOverrideBool" = true ]; then
    frames=$((endFrameOverride-startTime+1))
    endTime=$endFrameOverride
fi

# Monitor folder in background and transfer contents
mkdir $projectDir/Cloud_Outputs/$shot/v${next_version_str}
while true; do
    listOutput=$(ssh -i "$keyDir" $usr@$ip "ls -1 $linuxOutputPath")
    IFS=$'\n' read -rd '' -a file_array <<<"$listOutput"
    
    for file in "${file_array[@]}"; do
        scp -i "$keyDir" $usr@$ip:$linuxOutputPath/$file $projectDir/Cloud_Outputs/$shot/v${next_version_str}
        ssh -i "$keyDir" $usr@$ip "rm $linuxOutputPath/$file"

        # Exit background process if the last frame is transfered
        if [[ $file =~ ([0-9]+)\.${format}$ ]]; then
            currentFrame="${BASH_REMATCH[1]}"
            printf -v exitFrame "%04d" $endTime
            if [[ $currentFrame = $exitFrame ]]; then
                echo "exiting"
                exit 0
            fi
        fi
    done
done &

# Get pid of background ssh
localSshPid=$!

cleanup() {
    echo "killing ssh scripts"
    killpid=$(ssh -i "$keyDir" $usr@$ip "cat /home/$usr/scripts/huskPid.txt")
    ssh -i "$keyDir" $usr@$ip "if ps -p $killpid > /dev/null; then kill $killpid; fi; rm /home/$usr/scripts/huskPid.txt"
    if ps -p $localSshPid > /dev/null
    then
        kill $localSshPid
    fi
    exit 0
}

trap cleanup SIGINT

start_time_render=$(date +%s)

# Render
ssh -i "$keyDir" $usr@$ip "husk -V 1 $linuxShotPath/$shot.usd -o $linuxOutputPath/${shot}_\\\$F4.$format -f $startTime -n $frames & echo \$! > /home/$usr/scripts/huskPid.txt"

end_time_render=$(date +%s)

start_time_outputSend=$(date +%s)

if ps -p $localSshPid > /dev/null
then
    echo "Waiting for image transfer to finish script"
    wait $localSshPid
fi

end_time_outputSend=$(date +%s)

# exit cleanup
ssh -i "$keyDir" $usr@$ip "rm /home/$usr/scripts/huskPid.txt"

elapsed_seconds_zip=$((end_time_zip - start_time_zip))
hours_zip=$((elapsed_seconds_zip / 3600))
minutes_zip=$(( (elapsed_seconds_zip % 3600) / 60 ))
seconds_zip=$((elapsed_seconds_zip % 60))

elapsed_seconds_send=$((end_time_send - start_time_send))
hours_send=$((elapsed_seconds_send / 3600))
minutes_send=$(( (elapsed_seconds_send % 3600) / 60 ))
seconds_send=$((elapsed_seconds_send % 60))

elapsed_seconds_unzip=$((end_time_unzip - start_time_unzip))
hours_unzip=$((elapsed_seconds_unzip / 3600))
minutes_unzip=$(( (elapsed_seconds_unzip % 3600) / 60 ))
seconds_unzip=$((elapsed_seconds_unzip % 60))

elapsed_seconds_render=$((end_time_render - start_time_render))
hours_render=$((elapsed_seconds_render / 3600))
minutes_render=$(( (elapsed_seconds_render % 3600) / 60 ))
seconds_render=$((elapsed_seconds_render % 60))

elapsed_seconds_outputSend=$((end_time_outputSend - start_time_outputSend))
hours_outputSend=$((elapsed_seconds_outputSend / 3600))
minutes_outputSend=$(( (elapsed_seconds_outputSend % 3600) / 60 ))
seconds_outputSend=$((elapsed_seconds_outputSend % 60))

lines=(
    "--Complete--"
    "Version: ${next_version_str}"
    "Output Directory: $projectDir/Cloud_Outputs/$shot/v${next_version_str}"
    "Time to Zip: ${hours_zip}h ${minutes_zip}m ${seconds_zip}s"
    "Time to Send: ${hours_send}h ${minutes_send}m ${seconds_send}s"
    "Time to Unzip: ${hours_unzip}h ${minutes_unzip}m ${seconds_unzip}s"
    "Time to Render: ${hours_render}h ${minutes_render}m ${seconds_render}s"
    "Excess time Sent Transfering Output: ${hours_outputSend}h ${minutes_outputSend}m ${seconds_outputSend}s"
)

for line in "${lines[@]}"; do
    echo "$line"
done
