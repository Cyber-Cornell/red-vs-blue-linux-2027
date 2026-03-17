#!/bin/sh

# ==============================================================================
# Script Name: docker_audit.sh
# Description: Lists running containers, exposed ports, and Compose file paths.
#              Portable: Runs on sh, dash, ash, bash.
# ==============================================================================

# 1. Dependency Check
if ! command -v docker >/dev/null 2>&1; then
  printf "Error: Docker command not found.\n" >&2
  exit 1
fi

# 2. Format Helper
# %-20s : Container Name (20 chars)
# %-30s : Ports (30 chars)
# %s    : Compose File
FMT="%-25s | %-30s | %s\n"

# 3. Print Header
printf "%s\n" "----------------------------------------------------------------------------------------------------"
printf "$FMT" "Container Name" "Public Ports" "Compose File Location"
printf "%s\n" "----------------------------------------------------------------------------------------------------"

# 4. Get Running Containers (IDs)
# We use 'docker ps -q' to get IDs.
# We then loop through them. This is safer than parsing 'docker ps' text output which can truncate lines.

docker ps -q | while read -r container_id; do

  # --- A. Get Name ---
  # --format '{{.Name}}' returns names with a leading slash (e.g., /webserver).
  # We use sed to strip the leading slash.
  name=$(docker inspect --format '{{.Name}}' "$container_id" | sed 's/^\///')

  # --- B. Get Ports ---
  # We extract the NetworkSettings.Ports map.
  # The format will look like: map[80/tcp:[{0.0.0.0 8080}]]
  # We use a custom template to iterate cleanly over published ports only.
  ports=$(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}} -> {{(index $conf 0).HostPort}}, {{end}}{{end}}' "$container_id" | sed 's/, $//')

  if [ -z "$ports" ]; then
    ports="(internal only)"
  fi

  # --- C. Get Docker Compose File ---
  # Docker Compose adds labels to containers.
  # com.docker.compose.project.working_dir = The folder where docker-compose up was run.
  # com.docker.compose.project.config_files = The specific yaml file(s) used.

  work_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_id")
  config_file=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$container_id")

  # Determine what to display
  if [ -n "$config_file" ]; then
    # Often config_files is just "docker-compose.yml", so we combine it with work_dir for full path
    case "$config_file" in
    /*) compose_path="$config_file" ;;          # It's absolute
    *) compose_path="$work_dir/$config_file" ;; # It's relative, join them
    esac
  elif [ -n "$work_dir" ]; then
    # Fallback if specific config file label is missing but working dir exists
    compose_path="$work_dir (Implicit)"
  else
    compose_path="N/A (Not started via Compose)"
  fi

  # --- D. Print Row ---
  # We check if compose_path is empty (in case parsing failed completely)
  if [ -z "$compose_path" ]; then compose_path="N/A"; fi

  printf "$FMT" "$name" "$ports" "$compose_path"

done
