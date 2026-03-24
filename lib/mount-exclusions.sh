#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later OR Proprietary
# Copyright (c) 2024 Nyia Keeper Contributors
# Nyia Keeper Mount Exclusions Library - KISS Design
# Simple Docker overlay mounts to exclude sensitive files

# Fallback print functions
if ! declare -f print_verbose >/dev/null 2>&1; then
    print_verbose() { [[ "${VERBOSE:-false}" == "true" ]] && echo "🔍 $*"; return 0; }
fi

# Source shared cache utilities
if ! declare -f is_exclusions_cache_valid >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/exclusions-cache-utils.sh" 2>/dev/null || true
fi

# Inline fallback if portable_sha256sum not yet defined (defensive for isolated sourcing)
if ! declare -f portable_sha256sum >/dev/null 2>&1; then
    portable_sha256sum() {
        if command -v sha256sum >/dev/null 2>&1; then sha256sum
        elif command -v shasum >/dev/null 2>&1; then shasum -a 256
        else openssl dgst -sha256 | sed 's/^.* //'; fi
    }
fi

# Platform-aware case sensitivity for file matching
# Optional argument: project path — used to detect NTFS mounts on WSL2
get_find_case_args() {
    local project_path="${1:-}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS: case-insensitive filesystem
        echo "-iname"
    elif [[ -n "$project_path" ]] && is_ntfs_path "$project_path"; then
        # WSL2 NTFS mount: case-insensitive filesystem
        echo "-iname"
    else
        # Native Linux: case-sensitive filesystem
        echo "-name"
    fi
}

# Feature control
ENABLE_MOUNT_EXCLUSIONS=${ENABLE_MOUNT_EXCLUSIONS:-true}

# Exclusion cache logic version — bump this when exclusion scan logic changes
EXCL_CACHE_VERSION="2"

# Compute a cache key combining logic version + exclusions.conf content hash.
# Returns: "<version>:<cksum_output>" or "<version>:noconf" if no config file.
compute_cache_key() {
    local project_path="${1:-$(pwd)}"
    local conf_file="$project_path/.nyiakeeper/exclusions.conf"
    if [[ -f "$conf_file" ]]; then
        echo "${EXCL_CACHE_VERSION}:$(cksum "$conf_file" 2>/dev/null | cut -d' ' -f1-2)"
    else
        echo "${EXCL_CACHE_VERSION}:noconf"
    fi
}

# Create explanation files for excluded content
setup_explanation_files() {
    local excluded_file="/tmp/nyia-excluded-file.txt"
    local excluded_dir="/tmp/nyia-excluded-dir"
    
    # Create explanation file
    if [[ ! -f "$excluded_file" ]]; then
        cat > "$excluded_file" << 'EOF'
🔒 FILE EXCLUDED FOR SECURITY

This file was automatically excluded from the container mount because it may contain sensitive information (secrets, credentials, API keys, etc.).

This is a security feature to prevent accidental exposure of sensitive data to AI assistants.

To include this file:
- Use --disable-exclusions flag to disable all exclusions
- Or add an override in .nyiakeeper/exclusions.conf:
    !filename.yaml          (keeps all files named filename.yaml)
    !path/to/specific.yaml  (keeps only that exact path)

Nyia Keeper Mount Exclusions System
EOF
    fi

    # Create explanation directory
    if [[ ! -d "$excluded_dir" ]]; then
        mkdir -p "$excluded_dir"
        cat > "$excluded_dir/README.md" << 'EOF'
# 🔒 Directory Excluded for Security

This directory was automatically excluded from the container mount because it may contain sensitive information.

This is a security feature to prevent accidental exposure of sensitive data to AI assistants.

## To include this directory:
- Use `--disable-exclusions` flag to disable all exclusions
- Or add an override in `.nyiakeeper/exclusions.conf`:
    ```
    !dirname/          # keeps all directories named dirname
    !path/to/dirname/  # keeps only that exact path
    ```

---
*Nyia Keeper Mount Exclusions System*
EOF
    fi
}

# Classify a user exclusion pattern using gitignore-like semantics.
# Input:  raw line from exclusions.conf (already stripped of comments/whitespace)
# Output: prints "strategy:is_dir:is_negation:cleaned_pattern"
#   strategy:  "basename" (match anywhere) or "root-anchored" (root-level only)
#   is_dir:    "true" if trailing / was present (directory-only)
#   is_negation: "true" if ! prefix was present (override/force-include)
#   cleaned_pattern: pattern with prefixes/suffixes stripped
#
# Classification rules (gitignore-compliant):
#   1. Strip ! prefix → negation flag
#   2. Strip trailing / → is_dir flag
#   3. **/ prefix → strip, strategy = "basename"
#   4. Leading / → strip, strategy = "root-anchored"
#   5. Contains / → strategy = "root-anchored"
#   6. No / → strategy = "basename"
#
# Note: wildcard * can cross path segments in find -path (known divergence from
# pure gitignore FNM_PATHNAME). Acceptable for exclusion use cases.
classify_user_pattern() {
    local raw="$1"
    local is_negation="false"
    local is_dir="false"
    local strategy="basename"

    # Step 1: Detect and strip ! prefix
    if [[ "$raw" == "!"* ]]; then
        is_negation="true"
        raw="${raw#!}"
    fi

    # Step 2: Detect and strip trailing /
    if [[ "$raw" == */ ]]; then
        is_dir="true"
        raw="${raw%/}"
    fi

    # Step 3: **/ prefix → basename (explicit match-anywhere)
    if [[ "$raw" == "**/"* ]]; then
        raw="${raw#\*\*/}"
        strategy="basename"
        echo "${strategy}:${is_dir}:${is_negation}:${raw}"
        return 0
    fi

    # Step 4: Leading / → root-anchored (explicit)
    if [[ "$raw" == "/"* ]]; then
        raw="${raw#/}"
        strategy="root-anchored"
        echo "${strategy}:${is_dir}:${is_negation}:${raw}"
        return 0
    fi

    # Step 5: Contains / → root-anchored (implicit, gitignore convention)
    if [[ "$raw" == */* ]]; then
        strategy="root-anchored"
        echo "${strategy}:${is_dir}:${is_negation}:${raw}"
        return 0
    fi

    # Step 6: No / → basename (match anywhere)
    echo "${strategy}:${is_dir}:${is_negation}:${raw}"
}

# Get user-defined exclusion patterns from .nyiakeeper/exclusions.conf
get_user_exclusion_patterns() {
    local project_path="${1:-$(pwd)}"
    local exclusions_file="$project_path/.nyiakeeper/exclusions.conf"
    
    # If file doesn't exist, return nothing
    [[ -f "$exclusions_file" ]] || return 0
    
    # Read file line by line, skip comments and empty lines
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*! ]] && continue  # Override lines handled by get_user_override_patterns/dirs
        
        # Trim whitespace
        line=$(echo "$line" | xargs)
        [[ -z "$line" ]] && continue
        
        # If line ends with /, it's a directory pattern - skip it here
        [[ "$line" =~ /$ ]] && continue

        # Skip path patterns (containing /) — handled by get_user_exclusion_file_paths()
        [[ "$line" == */* ]] && continue

        # Output the pattern (basename only)
        echo "$line"
    done < "$exclusions_file"
}

# Get user-defined directory exclusion patterns
get_user_exclusion_dirs() {
    local project_path="${1:-$(pwd)}"
    local exclusions_file="$project_path/.nyiakeeper/exclusions.conf"
    
    # If file doesn't exist, return nothing
    [[ -f "$exclusions_file" ]] || return 0
    
    # Read file line by line, skip comments and empty lines
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*! ]] && continue  # Override lines handled by get_user_override_patterns/dirs
        
        # Trim whitespace
        line=$(echo "$line" | xargs)
        [[ -z "$line" ]] && continue
        
        # Only process lines ending with / (directory patterns)
        if [[ "$line" =~ /$ ]]; then
            local dir_name="${line%/}"
            # Skip path-based dir patterns (containing /) — handled by get_user_exclusion_dir_paths()
            [[ "$dir_name" == */* ]] && continue
            # Output basename dir pattern
            echo "$dir_name"
        fi
    done < "$exclusions_file"
}

# Get user-defined file exclusion patterns that contain path separators.
# These patterns require `find -path` instead of `find -name`.
# Examples: config/database.yml, config/*.yml, docs/internal/secrets.key
get_user_exclusion_file_paths() {
    local project_path="${1:-$(pwd)}"
    local exclusions_file="$project_path/.nyiakeeper/exclusions.conf"

    [[ -f "$exclusions_file" ]] || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*! ]] && continue
        line=$(echo "$line" | xargs)
        [[ -z "$line" ]] && continue
        # Skip directory patterns (trailing /)
        [[ "$line" =~ /$ ]] && continue
        # Only return patterns that contain a path separator
        [[ "$line" == */* ]] || continue
        echo "$line"
    done < "$exclusions_file"
}

# Get user-defined directory exclusion patterns that contain path separators.
# These patterns require `find -path` on `-type d` instead of `find -name`.
# Examples: internal-docs/secrets/, config/private/
# Strips trailing / for consistency with find -path.
get_user_exclusion_dir_paths() {
    local project_path="${1:-$(pwd)}"
    local exclusions_file="$project_path/.nyiakeeper/exclusions.conf"

    [[ -f "$exclusions_file" ]] || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*! ]] && continue
        line=$(echo "$line" | xargs)
        [[ -z "$line" ]] && continue
        # Only directory patterns (trailing /)
        [[ "$line" =~ /$ ]] || continue
        local dir_name="${line%/}"
        # Only return patterns that contain a path separator (after stripping trailing /)
        [[ "$dir_name" == */* ]] || continue
        echo "$dir_name"
    done < "$exclusions_file"
}

# Get user-defined override patterns (files) from .nyiakeeper/exclusions.conf
# Lines starting with ! negate an exclusion — the file stays visible to the container.
# !filename      = basename match (matches any path ending in that name)
# !path/to/file  = exact relative path match
get_user_override_patterns() {
    local project_path="${1:-$(pwd)}"
    local exclusions_file="$project_path/.nyiakeeper/exclusions.conf"

    [[ -f "$exclusions_file" ]] || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ ! "$line" =~ ^[[:space:]]*! ]] && continue  # Only ! lines
        line=$(echo "$line" | xargs)
        line="${line#!}"  # Strip leading !
        [[ -z "$line" ]] && continue
        [[ "$line" =~ /$ ]] && continue  # Skip dir overrides (handled separately)
        echo "$line"
    done < "$exclusions_file"
}

# Get user-defined override patterns (directories) from .nyiakeeper/exclusions.conf
# Lines starting with ! and ending with / negate a directory exclusion.
# !dirname/       = basename match (any directory with that name)
# !path/to/dir/   = exact relative path match
get_user_override_dirs() {
    local project_path="${1:-$(pwd)}"
    local exclusions_file="$project_path/.nyiakeeper/exclusions.conf"

    [[ -f "$exclusions_file" ]] || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ ! "$line" =~ ^[[:space:]]*! ]] && continue  # Only ! lines
        line=$(echo "$line" | xargs)
        line="${line#!}"  # Strip leading !
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ /$ ]]; then
            echo "${line%/}"  # Remove trailing slash for consistency
        fi
    done < "$exclusions_file"
}

# Get common sensitive file patterns
get_exclusion_patterns() {
    # Core secrets (but preserve .nyiakeeper/creds/ directory - assistants need those)
    # Exclude .env files at project root (security risk) but allow in subdirs
    echo ".env *.key *.pem *.pfx *.p12 *.ppk *secret* *password* id_rsa id_dsa id_ecdsa id_ed25519"
    # Dangerous .env variants anywhere in project
    echo ".env.* env.local .env.production .env.staging .env.development .env.test .env.backup"
    # Generic credentials (but not .nyiakeeper/creds/ directory)
    echo "credentials.json credentials.yaml credentials.xml credentials.txt auth.json"
    
    # === INFRASTRUCTURE AS CODE ===
    # Terraform
    echo "*.tfstate *.tfstate.* *.tfvars *.tfvars.json terraform.tfvars.* override.tf *_override.tf .terraformrc terraform.rc *.tfplan crash.log"
    # OpenTofu (Terraform fork)
    echo "*.tofu *.tofustate *.tofuvars"
    # Pulumi
    echo "Pulumi.*.yaml Pulumi.*.yml"
    # CloudFormation
    echo "*-parameters.json *-parameters.yaml"
    
    # === KUBERNETES & CONTAINER ORCHESTRATION ===
    # Kubernetes
    echo "kubeconfig *.kubeconfig *-kubeconfig.yaml *.kubeconfig.yml config.yaml"
    # Rancher/RKE
    echo "*.rkestate cluster.rkestate rancher-cluster.yml cluster.yml"
    # K3s
    echo "k3s.yaml"
    # OpenShift
    echo "*.kubeconfig.json"
    
    # === CONFIGURATION MANAGEMENT ===
    # Ansible
    echo "*.vault vault_pass.txt .vault_pass ansible.cfg hosts.ini hosts inventory inventory.ini inventory.yml group_vars/*/vault host_vars/*/vault"
    # Chef
    echo "*.pem knife.rb client.rb validation.pem encrypted_data_bag_secret"
    # Puppet
    echo "*.eyaml hieradata/**/*.eyaml"
    # SaltStack
    echo "master.pem minion.pem *.sls"
    
    # === CONTAINER & BUILD TOOLS ===
    # Docker
    echo ".dockercfg .docker/config.json docker-compose.override.yml docker-compose.prod.yml docker-compose.secrets.yml"
    # Podman
    echo "containers.conf auth.json"
    # Buildah
    echo ".buildah"
    
    # === PACKAGE MANAGERS & LANGUAGES ===
    # Node.js/NPM
    echo ".npmrc .yarnrc .yarnrc.yml"
    # Python
    echo ".pypirc pip.conf setup.cfg tox.ini .python-version"
    # Ruby
    echo ".gem/credentials config/database.yml config/secrets.yml config/credentials.yml.enc config/master.key"
    # Java/Maven/Gradle
    echo "*.p8 *.jks *.keystore *.truststore settings.xml gradle.properties"
    # Go
    echo ".netrc go.sum"
    # Rust
    echo ".cargo/credentials .cargo/config.toml"
    # PHP
    echo "auth.json .env.*.php .env.php"
    # .NET
    echo "appsettings.*.json appsettings.Production.json appsettings.Staging.json nuget.config"
    
    # === CI/CD ===
    # Jenkins
    echo "credentials.xml jenkins.yaml jenkins.yml"
    # GitHub Actions
    echo ".github/workflows/secrets.yml"
    # GitLab CI
    echo ".gitlab-ci-local-variables.yml"
    # CircleCI
    echo ".circleci/config.local.yml"
    # Travis CI
    echo ".travis.yml"
    # ArgoCD
    echo "argocd-*.yaml"
    # Tekton
    echo "tekton-*.yaml"
    
    # === CLOUD PROVIDERS ===
    # AWS
    echo "credentials aws_access_key_id aws_secret_access_key *.pem"
    # Google Cloud
    echo "service-account*.json *-service-account.json gcloud.json application_default_credentials.json"
    # Azure
    echo "*.publishsettings *.azureProfile"
    # DigitalOcean
    echo "doctl.config"
    # Heroku
    echo ".netrc"
    
    # === MONITORING & LOGGING ===
    # Datadog
    echo "datadog.yaml datadog.yml"
    # New Relic
    echo "newrelic.yml newrelic.ini"
    # Prometheus
    echo "prometheus.yml"
    # Grafana
    echo "grafana.ini"
    
    # === MESSAGE QUEUES & DATABASES ===
    # Databases
    echo ".pgpass .my.cnf database.yml db.conf ormconfig.json ormconfig.js"
    # Redis
    echo "redis.conf"
    # RabbitMQ
    echo "rabbitmq.conf"
    # Kafka
    echo "kafka.properties"
    
    # === SECURITY TOOLS ===
    # Vault
    echo "*.hcl vault.json .vault-token"
    # Certificates
    echo "*.crt *.csr *.ca-bundle ca.crt server.crt client.crt *.cer *.der"
    # SSH
    echo "known_hosts authorized_keys"
    # VPN
    echo "*.ovpn wireguard.conf *.wg vpn.conf openvpn.conf"
    # Git-crypt
    echo ".git-crypt/**"
    
    # === WEB SERVERS ===
    # Nginx
    echo "nginx.conf sites-enabled/* sites-available/*"
    # Apache
    echo ".htaccess .htpasswd httpd.conf"
    
    # === GENERAL STATE FILES ===
    echo "*.state *.rkestate *.tfstate *.backup *.bak"
    
    # === LICENSES & MISC ===
    echo "*.license license.key license.txt"
    
    # === USER-DEFINED PATTERNS ===
    # Add patterns from .nyiakeeper/exclusions.conf
    get_user_exclusion_patterns "${1:-$(pwd)}"
}

# Get sensitive directory patterns  
get_exclusion_dirs() {
    # === CLOUD PROVIDERS === (but NOT .nyiakeeper/creds/ - assistants need that)
    echo ".aws .gcloud .azure .digitalocean .linode .vultr"
    
    # === KUBERNETES & ORCHESTRATION ===
    echo ".kube .minikube .k3s .k0s .kind .rancher .openshift .okd"
    
    # === CONTAINER TOOLS ===
    echo ".docker .podman .buildah .containerd"
    
    # === CONFIGURATION MANAGEMENT ===
    echo ".ansible .chef .puppet .salt .vagrant"
    
    # === INFRASTRUCTURE AS CODE ===
    echo ".terraform .terragrunt .pulumi .cdktf"
    
    # === CI/CD ===
    echo ".jenkins .circleci .buildkite .drone"

    # === PACKAGE MANAGERS ===
    echo ".npm .yarn .pnpm .cargo .gem .pypi .nuget .m2 .ivy2 .sbt .gradle"

    # === SECURITY & CERTIFICATES ===
    echo ".ssh .gnupg .gpg .git-crypt"

    # === MONITORING ===
    echo ".datadog .newrelic .dynatrace"

    # === CLOUD FUNCTIONS ===
    echo ".serverless .netlify .vercel .amplify"

    # === ORCHESTRATION TOOLS ===
    echo ".helm .kustomize .skaffold .tilt .garden"

    # === SERVICE MESH ===
    echo ".istio .linkerd .consul"

    # === DATABASES ===
    echo ".mysql .postgresql .mongodb .redis .elasticsearch"

    # === MESSAGE QUEUES ===
    echo ".kafka .rabbitmq .nats"

    # === DEVELOPMENT TOOLS ===
    echo ".vscode-server"

    # === BACKUP & STATE ===
    echo ".backup .bak"

    # === INFRASTRUCTURE ===
    echo ".packer .kitchen .inspec"
    
    # === USER-DEFINED DIRECTORIES ===
    # Add directory patterns from .nyiakeeper/exclusions.conf
    get_user_exclusion_dirs "${1:-$(pwd)}"
}

# Bare-word directory patterns that are only safe near the project root.
# These match common security dir names but also match legitimate package
# names inside dependency trees (e.g., npm "private", "consul", "state").
# Scanned at depth 2 only (project root + 1 level) to avoid false positives.
# Note: "private" and bare "consul" removed — too many false positives.
get_shallow_exclusion_dirs() {
    # Security & certificates (bare-word variants)
    echo "vault certs certificates ssl tls pki"
    # Backup & state (bare-word variants)
    echo "backups backup state states"
    # Generic secrets (bare-word variants)
    echo "secrets credentials keys"
}

# Slash-containing directory patterns that need find -path instead of -name.
# find -name only matches the final component, so ".github/secrets" never matches.
# These use -path "*/$pattern" to match correctly.
get_exclusion_path_patterns() {
    echo ".github/secrets .gitlab/secrets .devcontainer/secrets .codespaces/secrets"
}

# Global array for volume arguments
declare -a VOLUME_ARGS

# Global cache for nyiakeeper home (avoid calling get_nyiakeeper_home for every file)
_NYIA_HOME_CACHE=""

# Check if path is a Nyia Keeper system path that should not be excluded
is_nyiakeeper_system_path() {
    local file_path="$1"
    local project_path="$2"

    # Get Nyia Keeper home (cached to avoid repeated calls)
    if [[ -z "$_NYIA_HOME_CACHE" ]]; then
        # Use platform-aware function if available, otherwise fall back to default
        if declare -f get_nyiakeeper_home >/dev/null 2>&1; then
            _NYIA_HOME_CACHE="${NYIAKEEPER_HOME:-$(get_nyiakeeper_home)}"
        else
            _NYIA_HOME_CACHE="${NYIAKEEPER_HOME:-$HOME/.config/nyiakeeper}"
        fi
    fi
    local nyia_home="$_NYIA_HOME_CACHE"
    
    # If the project IS the Nyia Keeper home, check for system subdirs
    if [[ "$project_path" == "$nyia_home" ]] || [[ "$(realpath "$project_path")" == "$(realpath "$nyia_home")" ]]; then
        # Check if file is in protected Nyia Keeper directories
        case "$file_path" in
            claude/*|codex/*|gemini/*|opencode/*|data/*|config/*|bin/*|lib/*|docker/*)
                return 0  # True - this is a system path
                ;;
        esac
    fi
    
    return 1  # False - not a system path
}

# Check if path is under any excluded directory
# Usage: is_path_under_excluded_dir "rel/path/to/file" "${excluded_dirs[@]}"
is_path_under_excluded_dir() {
    local file_path="$1"
    shift
    local -a dirs=("$@")

    for dir in "${dirs[@]}"; do
        [[ -z "$dir" ]] && continue
        # Check if file_path starts with dir/
        if [[ "$file_path" == "$dir/"* ]]; then
            return 0  # True - file is under this directory
        fi
    done
    return 1  # False - not under any excluded directory
}

# Check if a directory exclusion pattern is a package-manager cache dir
# These get writable tmpfs mounts instead of read-only placeholders,
# so the container can use them (npm cache, cargo fetch, etc.) without
# leaking data to the host
is_package_manager_cache_pattern() {
    case "$1" in
        .npm|.yarn|.pnpm|.cargo|.gem|.pypi|.nuget|.m2|.ivy2|.sbt|.gradle)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# Check if a relative path is overridden by a user !pattern in exclusions.conf
# Two match modes:
# - Basename match: override has no slash → matches basename of rel_path
# - Exact path match: override contains slash → must match rel_path exactly
# Returns 0 (true) if overridden, 1 (false) otherwise
is_path_overridden() {
    local rel_path="$1"
    shift
    local -a overrides=("$@")
    local base
    base=$(basename "$rel_path")

    for override in "${overrides[@]}"; do
        [[ -z "$override" ]] && continue
        # Use classifier to determine anchoring strategy for this override
        local classified
        classified=$(classify_user_pattern "!$override")
        local strategy="${classified%%:*}"

        if [[ "$strategy" == "root-anchored" ]]; then
            # Root-anchored override: match against relative path from project root
            # The cleaned pattern is after the last : in classification output
            local cleaned="${classified##*:}"
            # Use glob matching for wildcards
            # shellcheck disable=SC2254
            if [[ "$rel_path" == $cleaned ]]; then
                return 0
            fi
        else
            # Basename override: match against basename only
            # shellcheck disable=SC2254
            if [[ "$base" == $override ]]; then
                return 0
            fi
        fi
    done
    return 1
}

# Main function: populate volume arguments array with exclusions
create_volume_args() {
    local project_path="$1"
    local container_path="${2:-/workspace}"
    
    print_verbose "create_volume_args called with: $project_path -> $container_path"
    print_verbose "ENABLE_MOUNT_EXCLUSIONS=$ENABLE_MOUNT_EXCLUSIONS"
    
    # Clear the global array
    VOLUME_ARGS=()
    
    # Check if disabled
    if [[ "$ENABLE_MOUNT_EXCLUSIONS" != "true" ]]; then
        VOLUME_ARGS=("-v" "$project_path:$container_path:rw")
        print_verbose "Mount exclusions disabled, returning simple mount"
        return 0
    fi
    
    # Setup explanation files
    setup_explanation_files
    
    # Start with base mount
    VOLUME_ARGS=("-v" "$project_path:$container_path:rw")
    print_verbose "Base mount added, checking for exclusions..."
    
    # Try to use cached exclusion lists if available
    local cache_file="$project_path/.nyiakeeper/.excluded-files.cache"
    local config_file="$project_path/.nyiakeeper/exclusions.conf"
    
    # Check if cache is valid using the correct validation function
    if declare -f is_exclusions_cache_valid >/dev/null 2>&1 && is_exclusions_cache_valid "$project_path"; then
        print_verbose "Cache is valid, using cached exclusions"

        # Load user override patterns for cache path too
        local -a cache_file_overrides=()
        local -a cache_dir_overrides=()
        while IFS= read -r ov; do [[ -n "$ov" ]] && cache_file_overrides+=("$ov"); done < <(get_user_override_patterns "$project_path")
        while IFS= read -r ov; do [[ -n "$ov" ]] && cache_dir_overrides+=("$ov"); done < <(get_user_override_dirs "$project_path")

        # Read cached lists
        local excluded_files_str=""
        local excluded_dirs_str=""
        while IFS='=' read -r key value; do
            case "$key" in
                excluded_files) excluded_files_str="$value" ;;
                excluded_dirs) excluded_dirs_str="$value" ;;
            esac
        done < "$cache_file"

        # First: parse and mount excluded directories (MUST be before files!)
        local -a excluded_dir_array=()
        if [[ -n "$excluded_dirs_str" ]]; then
            IFS=',' read -ra excluded_dir_array <<< "$excluded_dirs_str"
            for rel_path in "${excluded_dir_array[@]}"; do
                if [[ -n "$rel_path" ]]; then
                    # Skip if another excluded dir is an ancestor
                    # (prevents nested ro mount conflicts — Docker can't create mountpoints inside ro mounts)
                    if is_path_under_excluded_dir "$rel_path" "${excluded_dir_array[@]}"; then
                        print_verbose "Skipping directory (parent already excluded, cached): $rel_path"
                        continue
                    fi
                    # Skip if user has overridden this directory
                    if [[ ${#cache_dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${cache_dir_overrides[@]}"; then
                        print_verbose "Override: keeping directory visible (cached): $rel_path"
                        continue
                    fi
                    local dir_basename
                    dir_basename=$(basename "$rel_path")
                    if is_package_manager_cache_pattern "$dir_basename"; then
                        VOLUME_ARGS+=("--mount" "type=tmpfs,destination=$container_path/$rel_path,tmpfs-mode=1777")
                        print_verbose "Excluding directory (cached, writable tmpfs): $rel_path"
                    else
                        VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_path/$rel_path:ro")
                        print_verbose "Excluding directory (cached): $rel_path"
                    fi
                fi
            done
        fi

        # Second: process files, but skip if under excluded directory
        if [[ -n "$excluded_files_str" ]]; then
            IFS=',' read -ra cached_files <<< "$excluded_files_str"
            for rel_path in "${cached_files[@]}"; do
                [[ -z "$rel_path" ]] && continue
                # Skip if file is under an excluded directory
                if is_path_under_excluded_dir "$rel_path" "${excluded_dir_array[@]}"; then
                    print_verbose "Skipping file (parent dir excluded): $rel_path"
                    continue
                fi
                # Skip if user has overridden this file
                if [[ ${#cache_file_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${cache_file_overrides[@]}"; then
                    print_verbose "Override: keeping file visible (cached): $rel_path"
                    continue
                fi
                VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-file.txt:$container_path/$rel_path:ro")
                print_verbose "Excluding file (cached): $rel_path"
            done
        fi
    else
        print_verbose "Cache invalid or missing, scanning filesystem"
        # Cache invalid or doesn't exist - scan filesystem
        local max_depth="${EXCLUSION_MAX_DEPTH:-5}"

        # Load user override patterns (!pattern in exclusions.conf)
        local -a file_overrides=()
        local -a dir_overrides=()
        while IFS= read -r ov; do [[ -n "$ov" ]] && file_overrides+=("$ov"); done < <(get_user_override_patterns "$project_path")
        while IFS= read -r ov; do [[ -n "$ov" ]] && dir_overrides+=("$ov"); done < <(get_user_override_dirs "$project_path")

        # First: scan and collect excluded directories (MUST be before files!)
        local -a scanned_excluded_dirs=()
        local dir_patterns=$(get_exclusion_dirs "$project_path")
        print_verbose "Directory exclusion patterns: $dir_patterns"

        # Build combined find expression for all directory patterns (single find call)
        local case_flag=$(get_find_case_args "$project_path")
        local -a dir_find_expr=()
        while IFS=' ' read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ ${#dir_find_expr[@]} -gt 0 ]] && dir_find_expr+=("-o")
            dir_find_expr+=("$case_flag" "$pattern")
        done < <(echo "$dir_patterns" | tr ' ' '\n')

        if [[ ${#dir_find_expr[@]} -gt 0 ]]; then
            while IFS= read -r -d '' match; do
                local rel_path="${match#$project_path/}"

                # Skip if already under an excluded parent directory
                # (prevents nested ro mount conflicts — Docker can't create mountpoints inside ro mounts)
                if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                    print_verbose "Skipping directory (parent already excluded): $rel_path"
                    continue
                fi

                # Skip if this is a Nyia Keeper system directory
                if is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                    print_verbose "Skipping Nyia Keeper system directory: $rel_path"
                    continue
                fi

                # Skip if user has overridden this directory
                if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                    print_verbose "Override: keeping directory visible: $rel_path"
                    continue
                fi

                scanned_excluded_dirs+=("$rel_path")
                # Package-manager cache dirs get writable tmpfs (container can use them)
                # Security-sensitive dirs get read-only placeholder
                # Check matched dir basename since we no longer track per-pattern
                local dir_basename
                dir_basename=$(basename "$rel_path")
                if is_package_manager_cache_pattern "$dir_basename"; then
                    VOLUME_ARGS+=("--mount" "type=tmpfs,destination=$container_path/$rel_path,tmpfs-mode=1777")
                    print_verbose "Excluding directory (writable tmpfs): $rel_path"
                else
                    VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_path/$rel_path:ro")
                    print_verbose "Excluding directory: $rel_path"
                fi
            done < <(find "$project_path" -maxdepth "$max_depth" \
                \( -name node_modules -o -name vendor -o -name site-packages \
                   -o -name __pycache__ -o -name .venv -o -name venv \
                   -o -name target \) -prune \
                -o -type d \( "${dir_find_expr[@]}" \) -print0 2>/dev/null)
        fi

        # Shallow scan: bare-word patterns at depth 2 only (project root + 1 level)
        # These match common security dir names but also match legitimate packages,
        # so we limit depth to avoid false positives inside src/, lib/, etc.
        local shallow_patterns=$(get_shallow_exclusion_dirs)
        if [[ -n "$shallow_patterns" ]]; then
            print_verbose "Shallow exclusion patterns (depth 2): $shallow_patterns"
            # Build combined find expression for all shallow patterns (single find call)
            local -a shallow_find_expr=()
            while IFS=' ' read -r pattern; do
                [[ -z "$pattern" ]] && continue
                [[ ${#shallow_find_expr[@]} -gt 0 ]] && shallow_find_expr+=("-o")
                shallow_find_expr+=("$case_flag" "$pattern")
            done < <(echo "$shallow_patterns" | tr ' ' '\n')

            if [[ ${#shallow_find_expr[@]} -gt 0 ]]; then
                while IFS= read -r -d '' match; do
                    local rel_path="${match#$project_path/}"
                    # Skip if already under an excluded parent directory
                    # (prevents nested ro mount conflicts — Docker can't create mountpoints inside ro mounts)
                    if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                        print_verbose "Skipping directory (parent already excluded): $rel_path"
                        continue
                    fi
                    if is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                        print_verbose "Skipping Nyia Keeper system directory: $rel_path"
                        continue
                    fi
                    if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                        print_verbose "Override: keeping directory visible: $rel_path"
                        continue
                    fi
                    scanned_excluded_dirs+=("$rel_path")
                    VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_path/$rel_path:ro")
                    print_verbose "Excluding directory (shallow): $rel_path"
                done < <(find "$project_path" -maxdepth 2 -type d \( "${shallow_find_expr[@]}" \) -print0 2>/dev/null)
            fi
        fi

        # Path-based scan: slash-containing patterns that need find -path
        # find -name only matches the final component, so ".github/secrets" needs -path
        local path_patterns=$(get_exclusion_path_patterns)
        if [[ -n "$path_patterns" ]]; then
            print_verbose "Path-based exclusion patterns: $path_patterns"
            # Build combined find expression for path-based patterns (single find call)
            local -a path_find_expr=()
            while IFS=' ' read -r pattern; do
                [[ -z "$pattern" ]] && continue
                [[ ${#path_find_expr[@]} -gt 0 ]] && path_find_expr+=("-o")
                path_find_expr+=("-path" "*/$pattern")
            done < <(echo "$path_patterns" | tr ' ' '\n')

            if [[ ${#path_find_expr[@]} -gt 0 ]]; then
                while IFS= read -r -d '' match; do
                    local rel_path="${match#$project_path/}"
                    # Skip if already under an excluded parent directory
                    if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                        print_verbose "Skipping directory (parent already excluded): $rel_path"
                        continue
                    fi
                    if is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                        continue
                    fi
                    if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                        print_verbose "Override: keeping directory visible: $rel_path"
                        continue
                    fi
                    scanned_excluded_dirs+=("$rel_path")
                    VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_path/$rel_path:ro")
                    print_verbose "Excluding directory (path): $rel_path"
                done < <(find "$project_path" -maxdepth "$max_depth" -type d \( "${path_find_expr[@]}" \) -print0 2>/dev/null)
            fi
        fi

        # User-defined directory path patterns (containing /, need find -path)
        # Root-anchored per gitignore semantics: match at project root only
        local user_dir_paths=$(get_user_exclusion_dir_paths "$project_path")
        if [[ -n "$user_dir_paths" ]]; then
            print_verbose "User directory path patterns (root-anchored): $user_dir_paths"
            local -a user_dir_path_expr=()
            while IFS= read -r pattern; do
                [[ -z "$pattern" ]] && continue
                [[ ${#user_dir_path_expr[@]} -gt 0 ]] && user_dir_path_expr+=("-o")
                user_dir_path_expr+=("-path" "$project_path/$pattern")
            done <<< "$user_dir_paths"

            if [[ ${#user_dir_path_expr[@]} -gt 0 ]]; then
                while IFS= read -r -d '' match; do
                    local rel_path="${match#$project_path/}"
                    if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                        print_verbose "Skipping directory (parent already excluded): $rel_path"
                        continue
                    fi
                    if is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                        continue
                    fi
                    if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                        print_verbose "Override: keeping directory visible: $rel_path"
                        continue
                    fi
                    scanned_excluded_dirs+=("$rel_path")
                    VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_path/$rel_path:ro")
                    print_verbose "Excluding directory (user path): $rel_path"
                done < <(find "$project_path" -maxdepth "$max_depth" -type d \( "${user_dir_path_expr[@]}" \) -print0 2>/dev/null)
            fi
        fi

        # Dedup tracking for files — prevents duplicate mounts when user path patterns
        # overlap with built-in basename patterns (e.g. config/credentials.json + credentials.json)
        declare -A seen_excluded_files=()

        # Second: scan files, skip if under excluded directory
        local patterns=$(get_exclusion_patterns "$project_path")
        print_verbose "Exclusion patterns: $patterns"

        # Build combined find expression for all file patterns (single find call)
        local -a file_find_expr=()
        while IFS=' ' read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ ${#file_find_expr[@]} -gt 0 ]] && file_find_expr+=("-o")
            file_find_expr+=("$case_flag" "$pattern")
        done < <(echo "$patterns" | tr ' ' '\n')

        if [[ ${#file_find_expr[@]} -gt 0 ]]; then
            while IFS= read -r -d '' match; do
                local rel_path="${match#$project_path/}"

                # Skip if this is a Nyia Keeper system file
                if is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                    print_verbose "Skipping Nyia Keeper system file: $rel_path"
                    continue
                fi

                # Skip if file is under an excluded directory
                if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                    print_verbose "Skipping file (parent dir excluded): $rel_path"
                    continue
                fi

                # Skip if user has overridden this file
                if [[ ${#file_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${file_overrides[@]}"; then
                    print_verbose "Override: keeping file visible: $rel_path"
                    continue
                fi

                # Dedup: track to prevent duplicate mounts from overlapping user path patterns
                seen_excluded_files["$rel_path"]=1
                VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-file.txt:$container_path/$rel_path:ro")
                print_verbose "Excluding file: $rel_path"
            done < <(find "$project_path" -maxdepth "$max_depth" \
                \( -name node_modules -o -name vendor -o -name site-packages \
                   -o -name __pycache__ -o -name .venv -o -name venv \
                   -o -name target \) -prune \
                -o -type f \( "${file_find_expr[@]}" \) -print0 2>/dev/null)
        fi

        # User-defined file path patterns (containing /, need find -path)
        # Root-anchored per gitignore semantics: match at project root only
        local user_file_paths=$(get_user_exclusion_file_paths "$project_path")
        if [[ -n "$user_file_paths" ]]; then
            print_verbose "User file path patterns (root-anchored): $user_file_paths"
            local -a user_file_path_expr=()
            while IFS= read -r pattern; do
                [[ -z "$pattern" ]] && continue
                [[ ${#user_file_path_expr[@]} -gt 0 ]] && user_file_path_expr+=("-o")
                user_file_path_expr+=("-path" "$project_path/$pattern")
            done <<< "$user_file_paths"

            if [[ ${#user_file_path_expr[@]} -gt 0 ]]; then
                while IFS= read -r -d '' match; do
                    local rel_path="${match#$project_path/}"
                    if is_nyiakeeper_system_path "$rel_path" "$project_path"; then
                        continue
                    fi
                    if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                        print_verbose "Skipping file (parent dir excluded): $rel_path"
                        continue
                    fi
                    if [[ ${#file_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${file_overrides[@]}"; then
                        print_verbose "Override: keeping file visible: $rel_path"
                        continue
                    fi
                    # Dedup: skip if already excluded by basename pattern
                    if [[ -n "${seen_excluded_files[$rel_path]+x}" ]]; then
                        print_verbose "Skipping file (already excluded by basename): $rel_path"
                        continue
                    fi
                    seen_excluded_files["$rel_path"]=1
                    VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-file.txt:$container_path/$rel_path:ro")
                    print_verbose "Excluding file (user path): $rel_path"
                done < <(find "$project_path" -maxdepth "$max_depth" \
                    \( -name node_modules -o -name vendor -o -name site-packages \
                       -o -name __pycache__ -o -name .venv -o -name venv \
                       -o -name target \) -prune \
                    -o -type f \( "${user_file_path_expr[@]}" \) -print0 2>/dev/null)
            fi
        fi

        # KISS: Write cache for next time (simple approach)
        if declare -f write_exclusions_cache >/dev/null 2>&1; then
            # Build simple arrays from VOLUME_ARGS for caching
            declare -gA excluded_files excluded_dirs system_files system_dirs
            excluded_files=() excluded_dirs=() system_files=() system_dirs=()
            
            # Extract excluded files/dirs from volume arguments
            local i=0
            while [[ $i -lt ${#VOLUME_ARGS[@]} ]]; do
                if [[ "${VOLUME_ARGS[$i]}" == "-v" ]]; then
                    local mount_spec="${VOLUME_ARGS[$((i+1))]}"
                    # Parse: /tmp/nyia-excluded-file.txt:/workspace/path:ro
                    if [[ "$mount_spec" == "/tmp/nyia-excluded-file.txt:$container_path/"* ]]; then
                        local file_path="${mount_spec#*/tmp/nyia-excluded-file.txt:$container_path/}"
                        file_path="${file_path%:ro}"
                        [[ -n "$file_path" ]] && excluded_files["$file_path"]=1
                    elif [[ "$mount_spec" == "/tmp/nyia-excluded-dir:$container_path/"* ]]; then
                        local dir_path="${mount_spec#*/tmp/nyia-excluded-dir:$container_path/}"
                        dir_path="${dir_path%:ro}"
                        [[ -n "$dir_path" ]] && excluded_dirs["$dir_path"]=1
                    fi
                    ((i+=2))
                elif [[ "${VOLUME_ARGS[$i]}" == "--mount" ]]; then
                    local mount_spec="${VOLUME_ARGS[$((i+1))]}"
                    # Parse: type=tmpfs,destination=/workspace/.pnpm,tmpfs-mode=1777
                    if [[ "$mount_spec" == *"destination=$container_path/"* ]]; then
                        local dir_path="${mount_spec#*destination=$container_path/}"
                        dir_path="${dir_path%%,*}"  # Strip trailing options
                        [[ -n "$dir_path" ]] && excluded_dirs["$dir_path"]=1
                    fi
                    ((i+=2))
                else
                    ((i++))
                fi
            done
            
            # Write cache with results
            write_exclusions_cache "$project_path"
            print_verbose "Assistant exclusions cache updated"
        fi
    fi
}

# Backward compatibility wrapper
create_filtered_volume_args() {
    create_volume_args "$@"
}

# === WORKSPACE MODE SUPPORT ===

# Appends volume mounts for a repo WITHOUT clearing VOLUME_ARGS
# Unlike create_volume_args(), this ADDS to existing array
# Mirrors the full exclusion logic from create_volume_args():
#   Phase 1: Directory exclusions (get_exclusion_dirs)
#   Phase 2: Shallow-pattern directory scanning (maxdepth 2)
#   Phase 3: Path-based directory scanning (.github/secrets, etc.)
#   Phase 4: File exclusions (get_exclusion_patterns)
# All phases respect overrides, nesting dedup, and tmpfs routing.
# Usage: append_repo_volume_args "$repo_path" "$container_base_path" ["$mode"]
#   mode: "ro" or "rw" (default: "rw")
append_repo_volume_args() {
    local repo_path="$1"
    local container_base="$2"  # e.g., /project/ws-{hash}/repos
    local mount_mode="${3:-rw}"  # Access mode: ro or rw

    # Use hash suffix for collision prevention (Issue #10 - same basename repos)
    local repo_hash
    repo_hash=$(echo -n "$repo_path" | portable_sha256sum | cut -c1-8)
    local repo_name
    repo_name=$(basename "$repo_path")
    local container_subpath="${container_base}/${repo_name}-${repo_hash}"

    print_verbose "Appending repo mount: $repo_path -> $container_subpath"

    # Add base mount for this repo (does NOT clear VOLUME_ARGS)
    VOLUME_ARGS+=("-v" "$repo_path:$container_subpath:${mount_mode}")

    # Skip exclusion scanning if disabled (repo is still mounted above)
    if [[ "$ENABLE_MOUNT_EXCLUSIONS" != "true" ]]; then
        print_verbose "Mount exclusions disabled, skipping repo exclusion scanning"
        return 0
    fi

    # Ensure explanation placeholder files exist (idempotent)
    setup_explanation_files

    local max_depth="${EXCLUSION_MAX_DEPTH:-5}"

    # Load user override patterns from this repo's exclusions.conf
    local -a file_overrides=()
    local -a dir_overrides=()
    while IFS= read -r ov; do [[ -n "$ov" ]] && file_overrides+=("$ov"); done < <(get_user_override_patterns "$repo_path")
    while IFS= read -r ov; do [[ -n "$ov" ]] && dir_overrides+=("$ov"); done < <(get_user_override_dirs "$repo_path")

    # === Phase 1: Directory exclusions (get_exclusion_dirs) ===
    local -a scanned_excluded_dirs=()
    local dir_patterns
    dir_patterns=$(get_exclusion_dirs "$repo_path")
    print_verbose "Repo directory exclusion patterns: $dir_patterns"

    local case_flag
    case_flag=$(get_find_case_args "$repo_path")
    local -a dir_find_expr=()
    while IFS=' ' read -r pattern; do
        [[ -z "$pattern" ]] && continue
        [[ ${#dir_find_expr[@]} -gt 0 ]] && dir_find_expr+=("-o")
        dir_find_expr+=("$case_flag" "$pattern")
    done < <(echo "$dir_patterns" | tr ' ' '\n')

    if [[ ${#dir_find_expr[@]} -gt 0 ]]; then
        while IFS= read -r -d '' match; do
            local rel_path="${match#$repo_path/}"

            # Skip if already under an excluded parent directory
            if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                print_verbose "Skipping directory (parent already excluded) in repo: $rel_path"
                continue
            fi

            # Skip Nyia Keeper system directories
            if is_nyiakeeper_system_path "$rel_path" "$repo_path" 2>/dev/null; then
                print_verbose "Skipping Nyia Keeper system directory in repo: $rel_path"
                continue
            fi

            # Skip if user has overridden this directory
            if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                print_verbose "Override: keeping directory visible in repo: $rel_path"
                continue
            fi

            scanned_excluded_dirs+=("$rel_path")
            local dir_basename
            dir_basename=$(basename "$rel_path")
            if is_package_manager_cache_pattern "$dir_basename"; then
                VOLUME_ARGS+=("--mount" "type=tmpfs,destination=$container_subpath/$rel_path,tmpfs-mode=1777")
                print_verbose "Excluding directory (writable tmpfs) in repo: $rel_path"
            else
                VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_subpath/$rel_path:ro")
                print_verbose "Excluding directory in repo: $rel_path"
            fi
        done < <(find "$repo_path" -maxdepth "$max_depth" \
            \( -name node_modules -o -name vendor -o -name site-packages \
               -o -name __pycache__ -o -name .venv -o -name venv \
               -o -name target \) -prune \
            -o -type d \( "${dir_find_expr[@]}" \) -print0 2>/dev/null)
    fi

    # === Phase 2: Shallow-pattern directory scanning (maxdepth 2) ===
    local shallow_patterns
    shallow_patterns=$(get_shallow_exclusion_dirs)
    if [[ -n "$shallow_patterns" ]]; then
        print_verbose "Repo shallow exclusion patterns (depth 2): $shallow_patterns"
        local -a shallow_find_expr=()
        while IFS=' ' read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ ${#shallow_find_expr[@]} -gt 0 ]] && shallow_find_expr+=("-o")
            shallow_find_expr+=("$case_flag" "$pattern")
        done < <(echo "$shallow_patterns" | tr ' ' '\n')

        if [[ ${#shallow_find_expr[@]} -gt 0 ]]; then
            while IFS= read -r -d '' match; do
                local rel_path="${match#$repo_path/}"
                if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                    print_verbose "Skipping directory (parent already excluded) in repo: $rel_path"
                    continue
                fi
                if is_nyiakeeper_system_path "$rel_path" "$repo_path" 2>/dev/null; then
                    print_verbose "Skipping Nyia Keeper system directory in repo: $rel_path"
                    continue
                fi
                if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                    print_verbose "Override: keeping directory visible in repo: $rel_path"
                    continue
                fi
                scanned_excluded_dirs+=("$rel_path")
                VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_subpath/$rel_path:ro")
                print_verbose "Excluding directory (shallow) in repo: $rel_path"
            done < <(find "$repo_path" -maxdepth 2 -type d \( "${shallow_find_expr[@]}" \) -print0 2>/dev/null)
        fi
    fi

    # === Phase 3: Path-based directory scanning (.github/secrets, etc.) ===
    local path_patterns
    path_patterns=$(get_exclusion_path_patterns)
    if [[ -n "$path_patterns" ]]; then
        print_verbose "Repo path-based exclusion patterns: $path_patterns"
        local -a path_find_expr=()
        while IFS=' ' read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ ${#path_find_expr[@]} -gt 0 ]] && path_find_expr+=("-o")
            path_find_expr+=("-path" "*/$pattern")
        done < <(echo "$path_patterns" | tr ' ' '\n')

        if [[ ${#path_find_expr[@]} -gt 0 ]]; then
            while IFS= read -r -d '' match; do
                local rel_path="${match#$repo_path/}"
                if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                    print_verbose "Skipping directory (parent already excluded) in repo: $rel_path"
                    continue
                fi
                if is_nyiakeeper_system_path "$rel_path" "$repo_path" 2>/dev/null; then
                    continue
                fi
                if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                    print_verbose "Override: keeping directory visible in repo: $rel_path"
                    continue
                fi
                scanned_excluded_dirs+=("$rel_path")
                VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_subpath/$rel_path:ro")
                print_verbose "Excluding directory (path) in repo: $rel_path"
            done < <(find "$repo_path" -maxdepth "$max_depth" -type d \( "${path_find_expr[@]}" \) -print0 2>/dev/null)
        fi
    fi

    # === Phase 3b: User-defined directory path patterns (containing /) ===
    # Root-anchored per gitignore semantics: match at repo root only
    local user_dir_paths
    user_dir_paths=$(get_user_exclusion_dir_paths "$repo_path")
    if [[ -n "$user_dir_paths" ]]; then
        print_verbose "Repo user directory path patterns (root-anchored): $user_dir_paths"
        local -a user_dir_path_expr=()
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ ${#user_dir_path_expr[@]} -gt 0 ]] && user_dir_path_expr+=("-o")
            user_dir_path_expr+=("-path" "$repo_path/$pattern")
        done <<< "$user_dir_paths"

        if [[ ${#user_dir_path_expr[@]} -gt 0 ]]; then
            while IFS= read -r -d '' match; do
                local rel_path="${match#$repo_path/}"
                if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                    print_verbose "Skipping directory (parent already excluded) in repo: $rel_path"
                    continue
                fi
                if is_nyiakeeper_system_path "$rel_path" "$repo_path" 2>/dev/null; then
                    continue
                fi
                if [[ ${#dir_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${dir_overrides[@]}"; then
                    print_verbose "Override: keeping directory visible in repo: $rel_path"
                    continue
                fi
                scanned_excluded_dirs+=("$rel_path")
                VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-dir:$container_subpath/$rel_path:ro")
                print_verbose "Excluding directory (user path) in repo: $rel_path"
            done < <(find "$repo_path" -maxdepth "$max_depth" -type d \( "${user_dir_path_expr[@]}" \) -print0 2>/dev/null)
        fi
    fi

    # Dedup tracking for files in workspace mode
    declare -A seen_excluded_files=()

    # === Phase 4: File exclusions (get_exclusion_patterns) ===
    # Uses the full built-in + user-defined pattern set, same as create_volume_args()
    local patterns
    patterns=$(get_exclusion_patterns "$repo_path")
    print_verbose "Repo file exclusion patterns: $patterns"

    local -a file_find_expr=()
    while IFS=' ' read -r pattern; do
        [[ -z "$pattern" ]] && continue
        [[ ${#file_find_expr[@]} -gt 0 ]] && file_find_expr+=("-o")
        file_find_expr+=("$case_flag" "$pattern")
    done < <(echo "$patterns" | tr ' ' '\n')

    if [[ ${#file_find_expr[@]} -gt 0 ]]; then
        while IFS= read -r -d '' match; do
            local rel_path="${match#$repo_path/}"

            # Skip Nyia Keeper system files
            if is_nyiakeeper_system_path "$rel_path" "$repo_path" 2>/dev/null; then
                print_verbose "Skipping Nyia Keeper system file in repo: $rel_path"
                continue
            fi

            # Skip if file is under an excluded directory
            if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                print_verbose "Skipping file (parent dir excluded) in repo: $rel_path"
                continue
            fi

            # Skip if user has overridden this file
            if [[ ${#file_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${file_overrides[@]}"; then
                print_verbose "Override: keeping file visible in repo: $rel_path"
                continue
            fi

            seen_excluded_files["$rel_path"]=1
            VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-file.txt:$container_subpath/$rel_path:ro")
            print_verbose "Excluding file in repo: $rel_path"
        done < <(find "$repo_path" -maxdepth "$max_depth" \
            \( -name node_modules -o -name vendor -o -name site-packages \
               -o -name __pycache__ -o -name .venv -o -name venv \
               -o -name target \) -prune \
            -o -type f \( "${file_find_expr[@]}" \) -print0 2>/dev/null)
    fi

    # === Phase 4b: User-defined file path patterns (containing /) ===
    # Root-anchored per gitignore semantics: match at repo root only
    local user_file_paths
    user_file_paths=$(get_user_exclusion_file_paths "$repo_path")
    if [[ -n "$user_file_paths" ]]; then
        print_verbose "Repo user file path patterns (root-anchored): $user_file_paths"
        local -a user_file_path_expr=()
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ ${#user_file_path_expr[@]} -gt 0 ]] && user_file_path_expr+=("-o")
            user_file_path_expr+=("-path" "$repo_path/$pattern")
        done <<< "$user_file_paths"

        if [[ ${#user_file_path_expr[@]} -gt 0 ]]; then
            while IFS= read -r -d '' match; do
                local rel_path="${match#$repo_path/}"
                if is_nyiakeeper_system_path "$rel_path" "$repo_path" 2>/dev/null; then
                    continue
                fi
                if is_path_under_excluded_dir "$rel_path" "${scanned_excluded_dirs[@]}"; then
                    print_verbose "Skipping file (parent dir excluded) in repo: $rel_path"
                    continue
                fi
                if [[ ${#file_overrides[@]} -gt 0 ]] && is_path_overridden "$rel_path" "${file_overrides[@]}"; then
                    print_verbose "Override: keeping file visible in repo: $rel_path"
                    continue
                fi
                if [[ -n "${seen_excluded_files[$rel_path]+x}" ]]; then
                    print_verbose "Skipping file (already excluded by basename) in repo: $rel_path"
                    continue
                fi
                seen_excluded_files["$rel_path"]=1
                VOLUME_ARGS+=("-v" "/tmp/nyia-excluded-file.txt:$container_subpath/$rel_path:ro")
                print_verbose "Excluding file (user path) in repo: $rel_path"
            done < <(find "$repo_path" -maxdepth "$max_depth" \
                \( -name node_modules -o -name vendor -o -name site-packages \
                   -o -name __pycache__ -o -name .venv -o -name venv \
                   -o -name target \) -prune \
                -o -type f \( "${user_file_path_expr[@]}" \) -print0 2>/dev/null)
        fi
    fi
}