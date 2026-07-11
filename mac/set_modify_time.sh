#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 file" >&2
    exit 1
fi

target_file="$1"
if [ ! -f "$target_file" ]; then
    echo "error: file does not exist: $target_file" >&2
    exit 1
fi

time_str="2025-11-16 20:30:00"
ctime=$(date -j -f "%Y-%m-%d %H:%M:%S" "$time_str" "+%s")

utc_time=$ctime
utc_formatted=$(date -u -r "$utc_time" +"%Y:%m:%d %H:%M:%S")

# Format the local timestamp in UTC+8.
formatted=$(TZ="Asia/Shanghai" date -r "$ctime" +"%Y:%m:%d %H:%M:%S")

echo "Processing: $target_file"

# Update the video metadata timestamps.
exiftool -overwrite_original -api QuickTimeUTC=0 "-CreateDate=$utc_formatted" "-ModifyDate=$utc_formatted" \
            "-TrackCreateDate=$utc_formatted" "-TrackModifyDate=$utc_formatted" \
            "-MediaCreateDate=$utc_formatted" "-MediaModifyDate=$utc_formatted" "$target_file"

# Restore the file creation time.
SetFile -d "$(date -j -f "%Y:%m:%d %H:%M:%S" "$formatted" +"%m/%d/%Y %H:%M:%S")" "$target_file"

# Synchronize the file modification time.
touch -t "$(date -j -f "%Y:%m:%d %H:%M:%S" "$formatted" +"%Y%m%d%H%M.%S")" "$target_file"
