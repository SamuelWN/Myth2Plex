#!/bin/bash                                                                                                         #
# mythpostprocess.sh written by Justin Decker, copyright 2015. For licensing purposes, use GPLv2                    #
#                                                                                                                   #
# Minor changes by Samuel Walters-Nevet                                                                             #
#    FFMpeg comments modified from:                                                                                 #
#       ArchWiki ( https://wiki.archlinux.org/index.php/FFmpeg )                                                    #
#       FFMpeg docs ( https://trac.ffmpeg.org/wiki/Encode/H.264 )                                                   #
#                                                                                                                   #
# This script does four things:                                                                                     #
# - Flags and removes commercials from the recording.                                                               #
# - Transcodes video to h264 but retains the original audio (if you use an HDHomeRun                                #
#   like I do, then that will probably be AC3 and doesn't need transcoding.)                                        #
# - Adjusts the database with the new stream name/info.                                                             #
# - Creates a symlink with a pretty name to a different folder and prunes any broken                                #
#   links and empty dirs as well as no longer needed video files (to keep up with MythTV's auto expiration system.) #
#                                                                                                                   #
# To use, create as a job that looks like this:                                                                     #
#       /path/to/script/mythpostprocess.sh "%CHANID%" "%STARTTIMEUTC%"                                              #
#####################################################################################################################

# The following values adjust the script parameters:
#
# Set this to where the pretty links should reside, making sure to include the trailing /.
PRETTYDIRNAME="/storage/htpc/recordedtv/"
# Set this to the URL prefix of your Plex Media Server. Only needed if you want to notify Plex to refresh the library.
PMSURL="http://localhost:32400/"
# Set this to the section number of your recorded TV shows library.
#   To find this out, go to your plex media server and navigate to the desired library. Look at the URL for that page, and at the end you should see:
#   /section/<number>
#   The number here is your section number.
PMSSEC="2"


#########################
# FFmpeg Configuration: #
#########################
# Number of threads to use for encoding. 0 uses all.
THREADS=0

# Used when you want a specific quality output.
#   General usage is to use the highest -crf value that still provides an acceptable quality.
#   Lower values are higher quality; 0 is lossless, 18 is visually lossless, and 23 is the default value.
#   A sane range is between 18 and 28.
CRF=22

# libx264 preset. Options are:  "ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", and "veryslow"
#   A preset is a collection of options that will provide a certain encoding speed to compression ratio.
#   A slower preset will provide better compression. This means that, for example, if you target a certain file size or constant bit rate, you will achieve better quality with a slower preset.
#   Similarly, for constant quality encoding, you will simply save bitrate by choosing a slower preset.
#   Use the slowest -preset you have patience for
PRESET="medium"
#################################
#  End of FFmpeg Configuration  #
#################################


# Set this to the location of the mythtv config.xml file. It's needed to determine the mysql login. If you're running mythbuntu, you shouldn't need to change this.
CONFIGXML="/home/mythtv/.mythtv/config.xml"

# Leave everything below this line alone unless you know what you're doing.
#
# Discover mysql username and password from mythtv config.xml. Alternatively you can manually enter them after the = sign.
DBUSER="$(awk -F '[<>]' '/UserName/{print $3}' $CONFIGXML)"
DBPASS="$(awk -F '[<>]' '/Password/{print $3}' $CONFIGXML)"

CHANID=$1 && STARTTIME=$2

# Populate recording information from sql database
TITLE=$(mysql mythconverg --user=$DBUSER --password=$DBPASS -se "SELECT title FROM recorded WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";")
SUBTITLE=$(mysql mythconverg --user=$DBUSER --password=$DBPASS -se "SELECT subtitle FROM recorded WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";")
DATE=$(mysql mythconverg --user=$DBUSER --password=$DBPASS -se "SELECT starttime FROM recorded WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";")
FILENAME=$(mysql mythconverg --user=$DBUSER --password=$DBPASS -se "SELECT basename FROM recorded WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";")
STORAGEGROUP=$(mysql mythconverg --user=$DBUSER --password=$DBPASS -se "SELECT storagegroup FROM recorded WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";")
DIRNAME=$(mysql mythconverg --user=$DBUSER --password=$DBPASS -se "SELECT dirname FROM storagegroup WHERE groupname=\"$STORAGEGROUP\";")
FILEPATH="$DIRNAME$FILENAME"
NEWNAME=$(echo ${CHANID}_${STARTTIME}).mkv
NEWFILEPATH="$DIRNAME$NEWNAME"
PRETTYNAME="$TITLE $SUBTITLE $DATE.mkv"
PRETTYSUBDIR="$PRETTYDIRNAME$TITLE/"
PRETTYFILEPATH="$PRETTYSUBDIR$PRETTYNAME"

# Flag commercials
mythcommflag --chanid "$CHANID" --starttime "$STARTTIME"
# Generate a cut list
mythutil --gencutlist --chanid "$CHANID" --starttime "$STARTTIME"
# Remove commercials from mpeg file
mythtranscode --chanid "$CHANID" --starttime "$STARTTIME" --mpeg2 --honorcutlist

# To fix seeking, we'll prune the database values containing the previous bookmarks.
mysql mythconverg --user=$DBUSER --password=$DBPASS -se "DELETE FROM recordedmarkup WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";"
mysql mythconverg --user=$DBUSER --password=$DBPASS -se "DELETE FROM recordedseek WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";"

# Convert cut video to H264, preserving audio (and subtitles where supported.)
ffmpeg -i "$FILEPATH".tmp -c:v libx264 -preset $PRESET -crf $CRF -c:a copy -c:s copy -threads $THREADS -f matroska "$NEWFILEPATH"

# Rename intro shot to match our new file
mv "$FILEPATH".png "$NEWFILEPATH".png

# Update the file metadata to point to our newly cut and transcoded file.
NEWFILESIZE=`du -b "$NEWFILEPATH" | cut -f1`
mysql mythconverg --user=$DBUSER --password=$DBPASS -se "UPDATE recorded SET basename=\"$NEWNAME\",filesize=\"$NEWFILESIZE\",transcoded=\"1\" WHERE chanid=\"$CHANID\" AND starttime=\"$STARTTIME\";"

# Delete the now useless files
rm "$FILEPATH"
rm "$FILEPATH".tmp

# create pretty name and path for file
mkdir -p "$PRETTYSUBDIR"
ln -s "$NEWFILEPATH" "$PRETTYFILEPATH"
# Prune all dead links and empty folders
find -L $PRETTYDIRNAME -type l -delete
find $PRETTYDIRNAME -type d -empty -delete

# Notify Plex to refresh the library
curl "$PMSURL"library/sections/"$PMSSEC"/refresh
