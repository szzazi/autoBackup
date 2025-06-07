#!/bin/bash
#########################################################
# Automatic local backupper.
# Input: File list which wan to backup
#	Exclude file list
# Output: Compressed result with timerstamp in name.
########################################################

echo "Starting at `date`"
echo "Current directory: \"`echo $PWD`\""
echo "Directory files:"
ls -la

# Parameters
ProgramDir="/usr/local/bin/autoBackup"
SourceDirsList="sourceList.txt"
ExcludeList="excludeList.txt"
Destination="backup"
ServerTargetFolder="nas"

cd $ProgramDir

# Copy files
for path in $(cat $SourceDirsList)
do
    #echo $path
    Target=$Destination #$path
    mkdir -p $Target
    rsync -avr --exclude-from $ExcludeList $path $Target
done

# Generate filename
host=`hostname | tr '.' '_'`
timestamp=`date +"%Y%m%d_%H%M%S"`
bckpFilename="$timestamp-$host.zip"

# Compress backup
echo "Compress files"
zip -r "$bckpFilename" $Destination

# Mount remote drive
echo "Mount network storage"
sh ./mountBaskupFolder.sh

# Copy backup
echo "Copy backup file"
cp $bckpFilename $ServerTargetFolder

#Unmount remote drive
echo "Unmount backup storage"
sh ./unmountBaskupFolder.sh

echo "Remove backup locally"
rm $bckpFilename
#rm -r $Destination

# End
echo "Done"
