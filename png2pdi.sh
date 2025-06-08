#!/bin/sh
#
# Playdate Asset Compiler
#
# This script converts a folder of PNG images into a clean directory
# containing only the compiled Playdate image assets (.pdi files).
#
# It performs the following steps:
#   1. Creates a temporary build directory for dithered PNGs.
#   2. Analyzes image contrast and dynamically dithers source PNGs into the build directory.
#   3. Compiles the build directory into a .pdx package.
#   4. Extracts ONLY the compiled .pdi files from inside the .pdx package.
#   5. Moves the .pdi files to a final, clean assets directory.
#   6. Deletes all temporary build files and the .pdx package.
#
# USAGE:
#   Place this script in a folder with your source PNG images and execute it.
#   Requires: ImageMagick, the Playdate SDK (for pdc), and bc.
#
#-------------------------------------------------------------------------------

# --- Configuration ---
# The final, clean directory that will contain ONLY the compiled .pdi files.
FINAL_ASSETS_DIR="__final_pdi_assets"

# The name of the temporary directory for intermediate work.
BUILD_DIR="__build_temp"

# The maximum dimensions for the output images.
# Images will be scaled down to fit within this box, preserving aspect ratio.
MAX_DIMENSIONS="240x240"

# --- Dynamic Contrast Configuration ---
# The script will calculate contrast and apply a stretch between MAX and MIN.
# Standard deviation is used as the measure of contrast.
MAX_CONTRAST_STRETCH=5.0
MIN_CONTRAST_STRETCH=0.0
# Any image with std dev below this gets the MAX stretch.
LOW_CONTRAST_THRESHOLD=0.1
# Any image with std dev above this gets the MIN stretch.
HIGH_CONTRAST_THRESHOLD=0.3


# --- Safety Checks ---
# Exit immediately if a command fails or if trying to use an unset variable.
set -eu

# Check if required commands are installed.
command -v magick >/dev/null 2>&1 || { echo "Error: ImageMagick is not installed. Aborting."; exit 1; }
command -v pdc >/dev/null 2>&1 || { echo "Error: Playdate SDK (pdc) is not found in PATH. Aborting."; exit 1; }
command -v bc >/dev/null 2>&1 || { echo "Error: bc (basic calculator) is not installed. Aborting."; exit 1; }


# --- Main Script Logic ---

echo "STEP 1/4: Preparing directories..."
rm -rf "$BUILD_DIR" "${BUILD_DIR}.pdx" "$FINAL_ASSETS_DIR"
mkdir "$BUILD_DIR" "$FINAL_ASSETS_DIR"

echo "STEP 2/4: Analyzing, Resizing, and Dithering PNGs..."
# Loop through all PNG files and place the dithered versions in the build directory.
for file in ./*.png; do
  [ -f "$file" ] || continue
  filename=$(basename "$file")

  # --- Dynamic Contrast Calculation ---
  # 1. Get the standard deviation of the grayscale image. This is our contrast metric.
  #    We pipe to `head -n 1` to ensure we only get one value, even if magick
  #    outputs the statistic for multiple channels.
  STD_DEV=$(magick "$file" -grayscale Rec709Luminance -verbose info: | grep "standard deviation" | head -n 1 | awk -F'[()]' '{print $2}')

  # 2. Decide the contrast amount based on the thresholds.
  #    We use `bc` for float comparison and test if the output is 1 (true).
  if [ "$(echo "$STD_DEV <= $LOW_CONTRAST_THRESHOLD" | bc -l)" -eq 1 ]; then
    # Image has very low contrast, use the maximum stretch.
    DYNAMIC_CONTRAST_AMOUNT="$MAX_CONTRAST_STRETCH"
  elif [ "$(echo "$STD_DEV >= $HIGH_CONTRAST_THRESHOLD" | bc -l)" -eq 1 ]; then
    # Image has high contrast, use the minimum stretch (effectively none).
    DYNAMIC_CONTRAST_AMOUNT="$MIN_CONTRAST_STRETCH"
  else
    # Image contrast is in the middle range. We'll calculate a value that
    # scales from MAX_STRETCH down to MIN_STRETCH as the STD_DEV increases.
    # This is a simple linear interpolation.
    RANGE=$(echo "$HIGH_CONTRAST_THRESHOLD - $LOW_CONTRAST_THRESHOLD" | bc -l)
    DELTA=$(echo "$HIGH_CONTRAST_THRESHOLD - $STD_DEV" | bc -l)
    STRETCH_RANGE=$(echo "$MAX_CONTRAST_STRETCH - $MIN_CONTRAST_STRETCH" | bc -l)
    DYNAMIC_CONTRAST_AMOUNT=$(echo "($DELTA / $RANGE) * $STRETCH_RANGE + $MIN_CONTRAST_STRETCH" | bc -l)
  fi

  # Add a '%' to the final number for ImageMagick.
  DYNAMIC_CONTRAST_AMOUNT="${DYNAMIC_CONTRAST_AMOUNT}%"
  echo "  -> Processing ${filename} (StdDev: ${STD_DEV}, Stretch: ${DYNAMIC_CONTRAST_AMOUNT})"

  # 3. Perform the conversion using the dynamically calculated value.
  magick "$file" \
    -resize "$MAX_DIMENSIONS" \
    -grayscale Rec709Luminance \
    -contrast-stretch "$DYNAMIC_CONTRAST_AMOUNT" \
    -dither Ordered -ordered-dither o4x4 \
    -colors 2 \
    "${BUILD_DIR}/${filename}"
done

echo "STEP 3/4: Compiling assets into a .pdx package..."
# Create a placeholder main.lua inside the build directory so pdc has a source.
touch "${BUILD_DIR}/main.lua"

# Run pdc ON the build directory. This creates a new package: __build_temp.pdx
pdc "${BUILD_DIR}"

echo "STEP 4/4: Extracting compiled .pdi files from the package..."
# Find all .pdi files inside the newly created .pdx directory and move them.
# A .pdx is just a folder, so we can access its contents directly.
find "${BUILD_DIR}.pdx" -name "*.pdi" -exec mv {} "$FINAL_ASSETS_DIR" \;

echo "STEP 5/5: Cleaning up temporary files..."
# Remove the intermediate build directory and the temporary .pdx package.
rm -rf "$BUILD_DIR" "${BUILD_DIR}.pdx"

echo
echo "----------------------------------------------------"
echo "✅ Success! Your clean asset folder is ready:"
echo "    -> ${FINAL_ASSETS_DIR}/"
echo "----------------------------------------------------"
