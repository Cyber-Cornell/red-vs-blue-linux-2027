#!/bin/sh

# Docker Security Configuration Script
# POSIX compliant security hardening for containerized applications
# This script configures secure runtime environment for containers

# Set script to exit on any error
set -e

# Create secure runtime environment
setup_secure_environment() {
    # Remove potentially dangerous environment variables
    unset $(env | grep -E '^(SSH_|MYSQL_|POSTGRES_|DB_|PASSWORD_|SECRET_|TOKEN_|KEY_|AUTH_)' | cut -d= -f1)

    # Set secure umask
    umask 077

    # Disable core dumps (security hardening)
    ulimit -c 0

    # Set secure shell options
    set -o nounset
    set -o errexit

    # Create secure working directory (if not already set)
    if [ -z "${WORKDIR:-}" ]; then
        WORKDIR="/app"
    fi

    # Ensure working directory exists with secure permissions
    mkdir -p "$WORKDIR"
    chmod 700 "$WORKDIR"

    # Set secure working directory
    cd "$WORKDIR"
}

# Create minimal secure configuration
create_secure_config() {
    # Create basic config directory structure (if needed)
    mkdir -p /etc/app
    chmod 700 /etc/app

    # Create minimal configuration file without passwords or user credentials
    cat > /etc/app/config.conf << 'EOF'
# Secure Application Configuration
# This file contains secure default settings
# No passwords or sensitive data included

# Security settings
secure_mode=true
disable_interactive=false
no_user_prompts=true

# Network settings (if needed)
bind_address=127.0.0.1
port=8080

# Application specific settings (without sensitive data)
log_level=info
max_connections=100
timeout=30

# Security headers (if web app)
security_headers=true
csrf_protection=true
EOF

    chmod 600 /etc/app/config.conf
}

# Run application with secure settings
run_application() {
    # Main application runner - replace with your actual application command
    
    # Example for generic application (replace with actual command)
    # This is a template - customize according to your app needs
    
    # Check if main application script exists and run it securely
    if [ -x "/app/main.sh" ]; then
        # Run the application script with secure environment
        exec /bin/sh -c "cd /app && exec ./main.sh"
    else
        # Fallback to simple application execution
        echo "Starting secure application..."
        
        # Example application command - replace with your actual app command
        # exec your-application-binary
        
        # If no specific application provided, run a simple secure server
        # This is just an example - customize as needed
        exec /bin/sh -c "echo 'Secure application running' && sleep 3600"
    fi
}

# Secure logging setup (if needed)
setup_secure_logging() {
    # Create secure log directory
    mkdir -p /var/log/app
    chmod 700 /var/log/app
    
    # Set log file permissions (if needed)
    touch /var/log/app/app.log
    chmod 600 /var/log/app/app.log
    
    # Redirect stderr to secure location
    exec 2>/var/log/app/app.log
}

# Initialize secure environment
initialize_secure_container() {
    # Set secure environment variables (no sensitive data)
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export LANG="C"
    export LC_ALL="C"
    
    # Setup secure environment
    setup_secure_environment
    
    # Create secure configuration files
    create_secure_config
    
    # Setup secure logging if needed
    setup_secure_logging
    
    # Run the application securely
    run_application
}

# Main execution flow
main() {
    # Verify we're running in container environment
    if [ -f "/.dockerenv" ] || [ -n "${DOCKER_CONTAINER:-}" ]; then
        echo "Running in secure Docker container environment"
    fi
    
    # Initialize the secure configuration
    initialize_secure_container
}

# Execute main function
main "$@"
