#!/bin/bash

if [ $# -ne 1 ]; then
    echo "usage: $0 dir"
    exit 1
fi

DIR="$1"

# 1. DateTimeOriginal
exiftool -r -overwrite_original \
  -if '$DateTimeOriginal' \
  "-FileCreateDate<DateTimeOriginal" \
  "-FileModifyDate<DateTimeOriginal" \
  "$DIR"

# 2. CreateDate
exiftool -r -overwrite_original \
  -if 'not $DateTimeOriginal and $CreateDate' \
  "-FileCreateDate<CreateDate" \
  "-FileModifyDate<CreateDate" \
  "$DIR"

# 3. DateCreated + TimeCreated
exiftool -r -overwrite_original \
  -if 'not $DateTimeOriginal and not $CreateDate and $DateCreated and $TimeCreated' \
  '-FileCreateDate<${DateCreated} ${TimeCreated}' \
  '-FileModifyDate<${DateCreated} ${TimeCreated}' \
  "$DIR"

# 4. ProfileDateTime
exiftool -r -overwrite_original \
  -if 'not $DateTimeOriginal and not $CreateDate and not ($DateCreated and $TimeCreated) and $ProfileDateTime' \
  "-FileCreateDate<ProfileDateTime" \
  "-FileModifyDate<ProfileDateTime" \
  "$DIR"
