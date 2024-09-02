#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

GITHUB_REPOSITORY_NAME=${GITHUB_REPOSITORY#$GITHUB_REPOSITORY_OWNER/}
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$GITHUB_REPOSITORY_OWNER-$GITHUB_REPOSITORY_NAME}"

# Change underscores to hyphens.
app="${app//_/-}"

# --region string                    The target region (see 'flyctl platform regions')
region="${INPUT_REGION:-${FLY_REGION:-iad}}"

# --org string                       The target Fly.io organization
org="${INPUT_ORG:-${FLY_ORG:-personal}}"

# --image string                     The Docker image to deploy
image="$INPUT_IMAGE"

# --config string                    Path to application configuration file
config="${INPUT_CONFIG:-fly.toml}"

# --build-arg stringArray            Set of build time variables in the form of NAME=VALUE pairs.
build_args=""

# --build-secret stringArray         Set of build secrets of NAME=VALUE pairs.
build_secrets=""

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  # Manage your Fly applications.
  # destroy = Delete one or more applications from the Fly platform.
  #         -y, --yes = Accept all confirmations
  flyctl apps destroy "$app" -y || true
  exit 0
fi

if [ -n "$INPUT_BUILD_ARGS" ]; then
  for ARG in $(echo "$INPUT_BUILD_ARGS" | tr " " "\n"); do
    build_args="$build_args --build-arg ${ARG}"
  done
fi

if [ -n "$INPUT_BUILD_SECRETS" ]; then
  for ARG in $(echo "$INPUT_BUILD_SECRETS" | tr " " "\n"); do
    build_secrets="$build_secrets --build-secret ${ARG}"
  done
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"
  # Create and configure a new app from source code or a Docker image.
  # --no-deploy = Do not immediately deploy the new app after fly launch creates and configures it
  # --copy-config = Use the configuration file if present without prompting
  # --name = Name of the new app
  # --image = The Docker image to deploy
  # --region = The target region (see 'flyctl platform regions')
  # --org = The target Fly.io organization
  # --build-arg = Set of build time variables in the form of NAME=VALUE pairs. Can be specified multiple times.
  # --build-secret = Set of build secrets of NAME=VALUE pairs. Can be specified multiple times.
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org" ${build_args} ${build_secrets}
  # Restore the original config file
  cp "$config.bak" "$config"
fi

if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach "$INPUT_POSTGRES" --app "$app" || true
fi

# Trigger the deploy of the new version.
echo "Contents of config $config file: " && cat "$config"
# Deploy Fly applications from source or an image using a local or remote builder.
# --config = Path to application configuration file
# --app = application name
# --regions = Deploy to machines only in these regions.
# --image = The Docker image to deploy
# --strategy = The strategy for replacing running instances. Options are canary, rolling, bluegreen, or immediate. The default strategy is rolling.
# --ha = Create spare machines that increases app availability (default true)
# --vm-size = The VM size to set machines to. See "fly platform vm-sizes" for valid values
# --vm-cpu-kind = The kind of CPU to use ('shared' or 'performance')
# --vm-cpus = Number of CPUs
# --vm-memory = Memory (in megabytes) to attribute to the VM

if [ -n "$INPUT_VM" ]; then
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA ${build_args} ${build_secrets} --vm-size "$INPUT_VMSIZE"
else
  flyctl deploy --config "$config" --app "$app" --regions "$region" --image "$image" --strategy immediate --ha=$INPUT_HA ${build_args} ${build_secrets} --vm-cpu-kind "$INPUT_CPUKIND" --vm-cpus $INPUT_CPU --vm-memory "$INPUT_MEMORY"
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json > status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT
