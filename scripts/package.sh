#!/bin/bash

set -e

PACKAGE="${PACKAGE:-commercial}"
REPO="${REPO:-https://github.com/openshift/openshift-docs.git}"
BRANCH="${BRANCH:-standalone-logging-docs-main}"
# Default to podman, but allow using docker through environment variable
CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
# By default, use container for building, but allow using local asciibinder
USE_LOCAL="${USE_LOCAL:-false}"
# Optional comma-separated list of specific branches to process
SPECIFIC_BRANCHES="${SPECIFIC_BRANCHES:-}"
# Parameter for offline mode (defaults to false)
OFFLINE="${OFFLINE:-false}"
# URL for the offline patch
OFFLINE_PATCH_URL="${OFFLINE_PATCH_URL:-https://github.com/openshift/openshift-docs/pull/92770.patch}"
# Parameter to control cleanup of _package folder (defaults to false)
CLEAN="${CLEAN:-false}"

# Determine if sudo is needed (typically only in GHA if files are created by root in container)
SUDO_CMD=""
if [ "$GITHUB_ACTIONS" == "true" ]; then
  echo "Running in GitHub Actions. Sudo prefix will be used if necessary."
  SUDO_CMD="sudo"
fi

## CLONE REPO
echo "---> Cloning docs from $BRANCH branch in $REPO"
# Clone OpenShift Docs into current directory
git clone --branch $BRANCH --depth 1 --no-single-branch $REPO .docs_source

cd .docs_source

# Prepare for offline mode if OFFLINE is true
if [ "$OFFLINE" = "true" ]; then
  echo "---> Downloading offline patch from $OFFLINE_PATCH_URL"
  # Download the patch once and save it to a temporary file
  PATCH_FILE=$(mktemp)
  curl -L "$OFFLINE_PATCH_URL" -o "$PATCH_FILE"
else
  echo "---> Skipping offline patch (OFFLINE=false)"
  PATCH_FILE=""
fi

# Convert comma-separated list to array
IFS=',' read -ra BRANCH_ARRAY <<< "$SPECIFIC_BRANCHES"

if [ -z "$SPECIFIC_BRANCHES" ]; then
  echo "---> No specific branches provided, processing all branches from _distro_map.yml"
  # Original behavior - process all branches in the _distro_map.yml
  for remote in $(cat _distro_map.yml | yq eval ".*.branches | keys | .[]" - | sort | uniq)
  do
      git fetch origin $remote
      echo "checkout $remote"
      git checkout $remote 2>/dev/null || git checkout --force --track remotes/origin/$remote

      # Apply patch to each branch if in offline mode
      if [ "$OFFLINE" = "true" ]; then
        echo "---> Applying offline patch to branch $remote"
        # Apply the patch and commit the changes
        git apply --ignore-whitespace "$PATCH_FILE" || echo "Warning: Could not apply patch to $remote"
        # If the patch applied successfully, commit the changes
        if [ $? -eq 0 ]; then
          git add -A
          git commit -m "Apply offline patch (temporary)" || echo "Nothing to commit"
        fi
      fi
  done
else
  echo "---> Processing only specified branches: $SPECIFIC_BRANCHES"
  # Process only the specified branches
  for remote in "${BRANCH_ARRAY[@]}"
  do
      # Trim any whitespace from branch name
      remote=$(echo "$remote" | xargs)
      if [ -n "$remote" ]; then
          git fetch origin $remote
          echo "checkout $remote"
          git checkout $remote 2>/dev/null || git checkout --force --track remotes/origin/$remote

          # Apply patch to each branch if in offline mode
          if [ "$OFFLINE" = "true" ]; then
            echo "---> Applying offline patch to branch $remote"
            curl -L "$OFFLINE_PATCH_URL" | git apply || echo "Warning: Could not apply patch to $remote"
          fi
      fi
  done
fi

echo "---> Packaging $PACKAGE docs content"
git checkout $BRANCH

# Handle the _package directory based on CLEAN setting
if [ "$CLEAN" = "true" ]; then
  echo "---> Cleaning _package directory (CLEAN=true)"
  $SUDO_CMD rm -rf ../_package
fi

# Create _package directory (mkdir -p will not fail if directory already exists)
echo "---> Ensuring _package directory exists"
mkdir -p ../_package

# Check if we're using local asciibinder or container
if [ "$USE_LOCAL" = "true" ]; then
  # Check if asciibinder is actually installed
  if command -v asciibinder >/dev/null 2>&1; then
    echo "Using local asciibinder installation"
    asciibinder package --site=$PACKAGE 2>/dev/null
  else
    echo "Warning: Local asciibinder not found. Falling back to container."
    $CONTAINER_ENGINE run --rm -v `pwd`:/docs:Z quay.io/openshift-cs/asciibinder asciibinder package --site=$PACKAGE 2>/dev/null
  fi
else
  echo "Using $CONTAINER_ENGINE container for build"
  $CONTAINER_ENGINE run --rm -v `pwd`:/docs:Z quay.io/openshift-cs/asciibinder sh -c "git config --global --add safe.directory /docs && asciibinder package --site=$PACKAGE" 2>/dev/null
fi

## MOVING FILES INTO THE RIGHT PLACES
$SUDO_CMD cp -rf _package/${PACKAGE}/* ../_package/

# Make sure to clean up any uncommited changes from patches
echo "---> Cleaning up repository"
git checkout $BRANCH
git reset --hard HEAD
git clean -fd

# Clean up the temporary patch file if it exists
if [ -n "$PATCH_FILE" ] && [ -f "$PATCH_FILE" ]; then
  rm -f "$PATCH_FILE"
fi

cd ..
$SUDO_CMD rm -rf .docs_source