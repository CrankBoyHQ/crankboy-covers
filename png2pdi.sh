#!/bin/bash
#
# Playdate Asset Compiler (Definitive Gamma-Correcting Version)
#
# This script uses a single pass to intelligently diagnose and treat images.
# It now uses Gamma Correction to properly rescue extremely dark images,
# followed by local contrast enhancement for maximum detail.
#
# USAGE:
#   Place this script in a folder with your source PNG images and execute it.
#   Requires: ImageMagick, the Playdate SDK (for pdc), and awk.
#
#-------------------------------------------------------------------------------

# --- Configuration ---
FINAL_ASSETS_DIR="__final_pdi_assets"
BUILD_DIR="__build_temp"
MAX_DIMENSIONS="240x240"

# --- Layout-Aware Analysis ---
# Ignores a percentage of the width from the left during analysis.
# Set to 20 for Game Boy box art. Set to 0 to disable.
IGNORE_LEFT_BANNER_PERCENT=20

# --- Intelligent Thresholds ---
# An image's artwork is "DARK" if its mean brightness is below this (0.0 to 1.0).
DARK_IMAGE_MEAN_THRESHOLD=0.25
# An image's artwork is "LOW CONTRAST" if its std dev is below this.
LOW_CONTRAST_STD_DEV_THRESHOLD=0.15

# --- Image Rescue Configuration ---
# Gamma value for dark images. >1.0 brightens mid-tones. 1.8 is a strong lift.
DARK_IMAGE_GAMMA_CORRECTION=1.8
# Local contrast settings for both dark and low-contrast images.
LOCAL_CONTRAST_RADIUS=10
LOCAL_CONTRAST_STRENGTH=15 # As a percentage

# --- Parallelism Configuration ---
if [ -n "$(command -v nproc)" ]; then
  NUM_CORES=$(nproc)
else
  NUM_CORES=$(sysctl -n hw.ncpu)
fi

# --- Safety Checks ---
set -u
command -v magick >/dev/null 2>&1 || { echo "Error: ImageMagick is not installed. Aborting."; exit 1; }
command -v pdc >/dev/null 2>&1 || { echo "Error: Playdate SDK (pdc) is not found in PATH. Aborting."; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "Error: awk is not installed. Aborting."; exit 1; }


# --- Image Processing Functions ---

# Function to get both Mean and Standard Deviation in one pass.
get_stats_and_path() {
  filepath="$1"
  local magick_cmd=("magick" "-quiet" "$filepath")
  if (( IGNORE_LEFT_BANNER_PERCENT > 0 )); then
    magick_cmd+=("-gravity" "West" "-chop" "${IGNORE_LEFT_BANNER_PERCENT}x0%")
  fi
  magick_cmd+=("-grayscale" "Rec709Luminance" "-verbose" "info:")
  stats=$(LC_ALL=C "${magick_cmd[@]}" | LC_ALL=C awk -F'[()]' '/mean:|standard deviation:/ {print $2}')
  if [ -n "$stats" ]; then
    echo "$stats" | paste -d' ' - - | awk -v path="$filepath" '{print $1, $2, path}'
  fi
}

# Function to process a single image based on its stats.
process_image() {
  mean=$1
  std_dev=$2
  shift 2
  file="$*"

  filename=$(basename "$file")

  local magick_ops=()
  local display_val_str=""

  # The Definitive Logic Tree
  if awk -v val="$mean" -v limit="$DARK_IMAGE_MEAN_THRESHOLD" 'BEGIN {exit !(val <= limit)}'; then
    # Rule 1: Image is too dark. Apply a powerful gamma lift, then normalize,
    # then enhance local contrast for maximum detail recovery.
    magick_ops+=(-gamma "$DARK_IMAGE_GAMMA_CORRECTION" -normalize -local-contrast "${LOCAL_CONTRAST_RADIUS}x${LOCAL_CONTRAST_STRENGTH}%")
    display_val_str="Dark Image Rescue"
  elif awk -v val="$std_dev" -v limit="$LOW_CONTRAST_STD_DEV_THRESHOLD" 'BEGIN {exit !(val <= limit)}'; then
    # Rule 2: Image is balanced but low contrast.
    # A gentler normalize followed by local contrast is sufficient.
    magick_ops+=(-normalize -local-contrast "${LOCAL_CONTRAST_RADIUS}x${LOCAL_CONTRAST_STRENGTH}%")
    display_val_str="Local Enhance"
  else
    # Rule 3: Image is already good. Do nothing.
    display_val_str="None"
  fi

  echo "  -> Processing ${filename} (Mean: ${mean}, StdDev: ${std_dev}, Method: ${display_val_str})"

  full_magick_args=()
  full_magick_args+=("$file")
  full_magick_args+=(-resize "$MAX_DIMENSIONS")
  full_magick_args+=(-grayscale "Rec709Luminance")
  if [ ${#magick_ops[@]} -gt 0 ]; then
    full_magick_args+=("${magick_ops[@]}")
  fi
  full_magick_args+=(-dither "Ordered" -ordered-dither "o4x4")
  full_magick_args+=(-colors 2)
  full_magick_args+=("${BUILD_DIR}/${filename}")

  if magick -quiet "${full_magick_args[@]}"; then
      touch "${BUILD_DIR}/${filename}.success"
  else
      echo "  🚨 WARNING: Failed to convert ${filename}. Check for ImageMagick errors above. Skipping."
      touch "${BUILD_DIR}/${filename}.fail"
  fi
}

# Functions and variables for use in parallel child processes.
export -f get_stats_and_path
export -f process_image
export BUILD_DIR MAX_DIMENSIONS
export IGNORE_LEFT_BANNER_PERCENT
export DARK_IMAGE_MEAN_THRESHOLD LOW_CONTRAST_STD_DEV_THRESHOLD
export DARK_IMAGE_GAMMA_CORRECTION LOCAL_CONTRAST_RADIUS LOCAL_CONTRAST_STRENGTH


# --- Main Script Logic ---

echo "STEP 1/4: Preparing directories..."
rm -rf "$BUILD_DIR" "${BUILD_DIR}.pdx" "$FINAL_ASSETS_DIR"
mkdir "$BUILD_DIR" "$FINAL_ASSETS_DIR"

echo "STEP 2/4: Analyzing all images (ignoring left ${IGNORE_LEFT_BANNER_PERCENT}% of width)..."
ANALYSIS_DATA=$(find . -maxdepth 1 -name '*.png' -print0 | xargs -0 -P "$NUM_CORES" -I {} bash -c 'get_stats_and_path "$@"' _ {})

if [ -z "$ANALYSIS_DATA" ]; then
    echo "No PNG files found to process. Exiting."
    exit 0
fi

echo "STEP 3/4: Dithering PNGs in parallel using intelligent rules..."

job_count=0
while read -r mean std_dev file; do
    process_image "$mean" "$std_dev" "$file" &
    job_count=$((job_count + 1))
    if (( job_count >= NUM_CORES )); then
        wait
        job_count=0
    fi
done <<< "$ANALYSIS_DATA"
wait

SUCCESS_COUNT=$(find "$BUILD_DIR" -maxdepth 1 -name '*.success' | wc -l)
FAIL_COUNT=$(find "$BUILD_DIR" -maxdepth 1 -name '*.fail' | wc -l)

echo
echo "STEP 3 COMPLETE: Processed ${SUCCESS_COUNT} images. Skipped ${FAIL_COUNT} files."

echo "STEP 4/4: Compiling and finishing up..."
touch "${BUILD_DIR}/main.lua"
pdc "${BUILD_DIR}"
find "${BUILD_DIR}.pdx" -name "*.pdi" -exec mv {} "$FINAL_ASSETS_DIR" \;
rm -rf "$BUILD_DIR" "${BUILD_DIR}.pdx"

echo
echo "----------------------------------------------------"
echo "✅ Success! Your clean asset folder is ready:"
echo "    -> ${FINAL_ASSETS_DIR}/"
echo "Processed: ${SUCCESS_COUNT} | Failed: ${FAIL_COUNT}"
echo "----------------------------------------------------"
