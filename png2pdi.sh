#!/bin/sh
#
# Playdate Asset Compiler
#
# This script converts a folder of PNG images into a clean directory
# containing only the compiled Playdate image assets (.pdi files).
#
# It performs the following steps:
#   1. Creates a temporary build directory for dithered PNGs.
#   2. Converts source PNGs to dithered, 1-bit PNGs in the build directory.
#   3. Compiles the build directory into a .pdx package.
#   4. Extracts ONLY the compiled .pdi files from inside the .pdx package.
#   5. Moves the .pdi files to a final, clean assets directory.
#   6. Deletes all temporary build files and the .pdx package.
#
# USAGE:
#   Place this script in a folder with your source PNG images and execute it.
#   Requires: OptiPNG, ImageMagick, and the Playdate SDK (for pdc).
#
#-------------------------------------------------------------------------------

# --- Configuration ---
# The final, clean directory that will contain ONLY the compiled .pdi files.
FINAL_ASSETS_DIR="__final_pdi_assets"

# The name of the temporary directory for intermediate work.
BUILD_DIR="__build_temp"


# --- Safety Checks ---
# Exit immediately if a command fails or if trying to use an unset variable.
set -eu

# Check if required commands are installed.
command -v optipng >/dev/null 2>&1 || { echo "Error: optipng is not installed. Aborting."; exit 1; }
command -v magick >/dev/null 2>&1 || { echo "Error: ImageMagick is not installed. Aborting."; exit 1; }
command -v pdc >/dev/null 2>&1 || { echo "Error: Playdate SDK (pdc) is not found in PATH. Aborting."; exit 1; }


# --- Main Script Logic ---

echo "STEP 1/6: Preparing directories..."
# Clean up any artifacts from previous runs.
rm -rf "$BUILD_DIR" "${BUILD_DIR}.pdx" "$FINAL_ASSETS_DIR"

# Create our temporary build folder and the final destination folder.
mkdir "$BUILD_DIR" "$FINAL_ASSETS_DIR"

echo "STEP 2/6: Optimizing and Dithering PNGs..."
# Loop through all PNG files and place the dithered versions in the build directory.
for file in ./*.png; do
  [ -f "$file" ] || continue
  filename=$(basename "$file")
  echo "  -> Processing ${filename}"

  # Optimize source file first
  optipng -quiet "$file"

  # Convert the image and place the dithered version in the build directory.
  magick "$file" -colorspace Gray -dither FloydSteinberg -colors 2 "${BUILD_DIR}/${filename}"
done

echo "STEP 3/6: Optimizing new dithered PNGs..."
optipng -quiet "${BUILD_DIR}"/*.png

echo "STEP 4/6: Compiling assets into a .pdx package..."
# Create a placeholder main.lua inside the build directory so pdc has a source.
touch "${BUILD_DIR}/main.lua"

# Run pdc ON the build directory. This creates a new package: __build_temp.pdx
pdc "${BUILD_DIR}"

echo "STEP 5/6: Extracting compiled .pdi files from the package..."
# Find all .pdi files inside the newly created .pdx directory and move them.
# A .pdx is just a folder, so we can access its contents directly.
find "${BUILD_DIR}.pdx" -name "*.pdi" -exec mv {} "$FINAL_ASSETS_DIR" \;

echo "STEP 6/6: Cleaning up temporary files..."
# Remove the intermediate build directory and the temporary .pdx package.
rm -rf "$BUILD_DIR" "${BUILD_DIR}.pdx"

echo
echo "----------------------------------------------------"
echo "✅ Success! Your clean asset folder is ready:"
echo "    -> ${FINAL_ASSETS_DIR}/"
echo "----------------------------------------------------"
