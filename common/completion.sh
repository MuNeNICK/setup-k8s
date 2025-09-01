#!/bin/bash

# Shell completion setup for Kubernetes tools

# Detect user's shell
detect_user_shell() {
    local user_shell=""
    
    # Check SHELL environment variable first
    if [ -n "$SHELL" ]; then
        user_shell=$(basename "$SHELL")
    fi
    
    # Check /etc/passwd for the user's default shell
    if [ -z "$user_shell" ] && [ -n "$SUDO_USER" ]; then
        user_shell=$(getent passwd "$SUDO_USER" | cut -d: -f7 | xargs basename)
    elif [ -z "$user_shell" ]; then
        user_shell=$(getent passwd "$USER" | cut -d: -f7 | xargs basename)
    fi
    
    # Default to bash if detection fails
    if [ -z "$user_shell" ]; then
        user_shell="bash"
    fi
    
    echo "$user_shell"
}

# Setup kubectl completion
setup_kubectl_completion() {
    if ! command -v kubectl &> /dev/null; then
        echo "kubectl not found, skipping completion setup"
        return 1
    fi
    
    local shell="$1"
    echo "Setting up kubectl completion for $shell..."
    
    case "$shell" in
        bash)
            # System-wide bash completion
            if [ -d /etc/bash_completion.d ]; then
                kubectl completion bash > /etc/bash_completion.d/kubectl
                echo "kubectl bash completion installed to /etc/bash_completion.d/"
            fi
            
            # User-specific bash completion (for non-root user if run with sudo)
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.bashrc" ]; then
                    if ! grep -q "kubectl completion bash" "$user_home/.bashrc"; then
                        echo "" >> "$user_home/.bashrc"
                        echo "# kubectl completion" >> "$user_home/.bashrc"
                        echo "source <(kubectl completion bash)" >> "$user_home/.bashrc"
                        echo "alias k=kubectl" >> "$user_home/.bashrc"
                        echo "complete -o default -F __start_kubectl k" >> "$user_home/.bashrc"
                        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.bashrc"
                        echo "kubectl bash completion added to $user_home/.bashrc"
                    fi
                fi
            fi
            ;;
            
        zsh)
            # System-wide zsh completion
            if [ -d /usr/share/zsh/site-functions ] || [ -d /usr/local/share/zsh/site-functions ]; then
                local zsh_dir=""
                [ -d /usr/local/share/zsh/site-functions ] && zsh_dir="/usr/local/share/zsh/site-functions"
                [ -d /usr/share/zsh/site-functions ] && zsh_dir="/usr/share/zsh/site-functions"
                
                if [ -n "$zsh_dir" ]; then
                    kubectl completion zsh > "${zsh_dir}/_kubectl"
                    echo "kubectl zsh completion installed to ${zsh_dir}/"
                fi
            fi
            
            # User-specific zsh completion
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.zshrc" ]; then
                    if ! grep -q "kubectl completion zsh" "$user_home/.zshrc"; then
                        echo "" >> "$user_home/.zshrc"
                        echo "# kubectl completion" >> "$user_home/.zshrc"
                        echo "source <(kubectl completion zsh)" >> "$user_home/.zshrc"
                        echo "alias k=kubectl" >> "$user_home/.zshrc"
                        echo "compdef k=kubectl" >> "$user_home/.zshrc"
                        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.zshrc"
                        echo "kubectl zsh completion added to $user_home/.zshrc"
                    fi
                fi
            fi
            ;;
            
        fish)
            # User-specific fish completion
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                local fish_dir="$user_home/.config/fish/completions"
                
                if [ ! -d "$fish_dir" ]; then
                    mkdir -p "$fish_dir"
                    chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.config"
                fi
                
                kubectl completion fish > "$fish_dir/kubectl.fish"
                chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$fish_dir/kubectl.fish"
                echo "kubectl fish completion installed to $fish_dir/"
                
                # Add alias if config.fish exists
                if [ -f "$user_home/.config/fish/config.fish" ]; then
                    if ! grep -q "alias k kubectl" "$user_home/.config/fish/config.fish"; then
                        echo "" >> "$user_home/.config/fish/config.fish"
                        echo "# kubectl alias" >> "$user_home/.config/fish/config.fish"
                        echo "alias k kubectl" >> "$user_home/.config/fish/config.fish"
                        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.config/fish/config.fish"
                    fi
                fi
            fi
            ;;
            
        *)
            echo "Unsupported shell: $shell"
            return 1
            ;;
    esac
    
    return 0
}

# Setup kubeadm completion
setup_kubeadm_completion() {
    if ! command -v kubeadm &> /dev/null; then
        echo "kubeadm not found, skipping completion setup"
        return 1
    fi
    
    local shell="$1"
    echo "Setting up kubeadm completion for $shell..."
    
    case "$shell" in
        bash)
            if [ -d /etc/bash_completion.d ]; then
                kubeadm completion bash > /etc/bash_completion.d/kubeadm
                echo "kubeadm bash completion installed to /etc/bash_completion.d/"
            fi
            
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.bashrc" ]; then
                    if ! grep -q "kubeadm completion bash" "$user_home/.bashrc"; then
                        echo "" >> "$user_home/.bashrc"
                        echo "# kubeadm completion" >> "$user_home/.bashrc"
                        echo "source <(kubeadm completion bash)" >> "$user_home/.bashrc"
                        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.bashrc"
                        echo "kubeadm bash completion added to $user_home/.bashrc"
                    fi
                fi
            fi
            ;;
            
        zsh)
            if [ -d /usr/share/zsh/site-functions ] || [ -d /usr/local/share/zsh/site-functions ]; then
                local zsh_dir=""
                [ -d /usr/local/share/zsh/site-functions ] && zsh_dir="/usr/local/share/zsh/site-functions"
                [ -d /usr/share/zsh/site-functions ] && zsh_dir="/usr/share/zsh/site-functions"
                
                if [ -n "$zsh_dir" ]; then
                    kubeadm completion zsh > "${zsh_dir}/_kubeadm"
                    echo "kubeadm zsh completion installed to ${zsh_dir}/"
                fi
            fi
            
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.zshrc" ]; then
                    if ! grep -q "kubeadm completion zsh" "$user_home/.zshrc"; then
                        echo "" >> "$user_home/.zshrc"
                        echo "# kubeadm completion" >> "$user_home/.zshrc"
                        echo "source <(kubeadm completion zsh)" >> "$user_home/.zshrc"
                        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.zshrc"
                        echo "kubeadm zsh completion added to $user_home/.zshrc"
                    fi
                fi
            fi
            ;;
            
        fish)
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                local fish_dir="$user_home/.config/fish/completions"
                
                if [ ! -d "$fish_dir" ]; then
                    mkdir -p "$fish_dir"
                    chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.config"
                fi
                
                kubeadm completion fish > "$fish_dir/kubeadm.fish"
                chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$fish_dir/kubeadm.fish"
                echo "kubeadm fish completion installed to $fish_dir/"
            fi
            ;;
            
        *)
            echo "Unsupported shell: $shell"
            return 1
            ;;
    esac
    
    return 0
}

# Setup crictl completion
setup_crictl_completion() {
    if ! command -v crictl &> /dev/null; then
        echo "crictl not found, skipping completion setup"
        return 1
    fi
    
    local shell="$1"
    echo "Setting up crictl completion for $shell..."
    
    case "$shell" in
        bash)
            if [ -d /etc/bash_completion.d ]; then
                crictl completion bash > /etc/bash_completion.d/crictl 2>/dev/null || {
                    echo "crictl does not support bash completion"
                    return 1
                }
                echo "crictl bash completion installed to /etc/bash_completion.d/"
            fi
            
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.bashrc" ]; then
                    if ! grep -q "crictl completion" "$user_home/.bashrc"; then
                        if crictl completion bash &>/dev/null; then
                            echo "" >> "$user_home/.bashrc"
                            echo "# crictl completion" >> "$user_home/.bashrc"
                            echo "source <(crictl completion bash 2>/dev/null)" >> "$user_home/.bashrc"
                            chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.bashrc"
                            echo "crictl bash completion added to $user_home/.bashrc"
                        fi
                    fi
                fi
            fi
            ;;
            
        zsh)
            if [ -d /usr/share/zsh/site-functions ] || [ -d /usr/local/share/zsh/site-functions ]; then
                local zsh_dir=""
                [ -d /usr/local/share/zsh/site-functions ] && zsh_dir="/usr/local/share/zsh/site-functions"
                [ -d /usr/share/zsh/site-functions ] && zsh_dir="/usr/share/zsh/site-functions"
                
                if [ -n "$zsh_dir" ]; then
                    crictl completion zsh > "${zsh_dir}/_crictl" 2>/dev/null || {
                        echo "crictl does not support zsh completion"
                        return 1
                    }
                    echo "crictl zsh completion installed to ${zsh_dir}/"
                fi
            fi
            
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.zshrc" ]; then
                    if ! grep -q "crictl completion" "$user_home/.zshrc"; then
                        if crictl completion zsh &>/dev/null; then
                            echo "" >> "$user_home/.zshrc"
                            echo "# crictl completion" >> "$user_home/.zshrc"
                            echo "source <(crictl completion zsh 2>/dev/null)" >> "$user_home/.zshrc"
                            chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.zshrc"
                            echo "crictl zsh completion added to $user_home/.zshrc"
                        fi
                    fi
                fi
            fi
            ;;
            
        fish)
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                local fish_dir="$user_home/.config/fish/completions"
                
                if [ ! -d "$fish_dir" ]; then
                    mkdir -p "$fish_dir"
                    chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.config"
                fi
                
                crictl completion fish > "$fish_dir/crictl.fish" 2>/dev/null || {
                    echo "crictl does not support fish completion"
                    return 1
                }
                chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$fish_dir/crictl.fish"
                echo "crictl fish completion installed to $fish_dir/"
            fi
            ;;
            
        *)
            echo "Unsupported shell: $shell"
            return 1
            ;;
    esac
    
    return 0
}

# Setup helm completion (if helm is installed)
setup_helm_completion() {
    local shell="$1"
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        echo "Helm not found, skipping helm completion setup"
        return 1
    fi
    
    echo "Setting up helm completion for $shell..."
    
    case "$shell" in
        bash)
            if [ -d /etc/bash_completion.d ]; then
                helm completion bash > /etc/bash_completion.d/helm
                echo "helm bash completion installed to /etc/bash_completion.d/"
            fi
            
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.bashrc" ]; then
                    if ! grep -q "helm completion bash" "$user_home/.bashrc"; then
                        echo "" >> "$user_home/.bashrc"
                        echo "# helm completion" >> "$user_home/.bashrc"
                        echo "source <(helm completion bash)" >> "$user_home/.bashrc"
                        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.bashrc"
                        echo "helm bash completion added to $user_home/.bashrc"
                    fi
                fi
            fi
            ;;
            
        zsh)
            if [ -d /usr/share/zsh/site-functions ] || [ -d /usr/local/share/zsh/site-functions ]; then
                local zsh_dir=""
                [ -d /usr/local/share/zsh/site-functions ] && zsh_dir="/usr/local/share/zsh/site-functions"
                [ -d /usr/share/zsh/site-functions ] && zsh_dir="/usr/share/zsh/site-functions"
                
                if [ -n "$zsh_dir" ]; then
                    helm completion zsh > "${zsh_dir}/_helm"
                    echo "helm zsh completion installed to ${zsh_dir}/"
                fi
            fi
            
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.zshrc" ]; then
                    if ! grep -q "helm completion zsh" "$user_home/.zshrc"; then
                        echo "" >> "$user_home/.zshrc"
                        echo "# helm completion" >> "$user_home/.zshrc"
                        echo "source <(helm completion zsh)" >> "$user_home/.zshrc"
                        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.zshrc"
                        echo "helm zsh completion added to $user_home/.zshrc"
                    fi
                fi
            fi
            ;;
            
        fish)
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                local fish_dir="$user_home/.config/fish/completions"
                
                if [ ! -d "$fish_dir" ]; then
                    mkdir -p "$fish_dir"
                    chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$user_home/.config"
                fi
                
                helm completion fish > "$fish_dir/helm.fish"
                chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$fish_dir/helm.fish"
                echo "helm fish completion installed to $fish_dir/"
            fi
            ;;
            
        *)
            echo "Unsupported shell: $shell"
            return 1
            ;;
    esac
    
    return 0
}

# Main function to setup all completions
setup_kubernetes_completions() {
    echo "Setting up Kubernetes shell completions..."
    
    # Detect shell(s) to configure
    local shells_to_configure=()
    
    if [ "$COMPLETION_SHELLS" = "auto" ]; then
        # Auto-detect the user's shell
        local detected_shell=$(detect_user_shell)
        shells_to_configure+=("$detected_shell")
        echo "Auto-detected shell: $detected_shell"
    else
        # Use specified shells
        IFS=',' read -ra shells_to_configure <<< "$COMPLETION_SHELLS"
    fi
    
    # Setup completions for each shell
    for shell in "${shells_to_configure[@]}"; do
        shell=$(echo "$shell" | tr -d ' ')  # Remove any spaces
        
        echo "Configuring completions for $shell..."
        
        # Setup kubectl completion
        setup_kubectl_completion "$shell"
        
        # Setup kubeadm completion
        setup_kubeadm_completion "$shell"
        
        # Setup crictl completion (may not be available for all shells)
        setup_crictl_completion "$shell" || true
        
        # Setup helm completion if helm is available
        setup_helm_completion "$shell" || true
    done
    
    echo "Shell completion setup completed!"
    
    # Provide instructions for activation
    echo ""
    echo "To activate completions:"
    echo "  - For bash: source ~/.bashrc or start a new terminal"
    echo "  - For zsh: source ~/.zshrc or start a new terminal"
    echo "  - For fish: completions are immediately available"
    echo ""
    echo "Useful aliases have been configured:"
    echo "  - 'k' for kubectl"
    
    return 0
}

# Function to be called from setup script
setup_k8s_shell_completion() {
    if [ "$ENABLE_COMPLETION" = true ]; then
        setup_kubernetes_completions
    else
        echo "Shell completion setup skipped (disabled by configuration)"
    fi
}

# Cleanup functions

# Remove kubectl completion
cleanup_kubectl_completion() {
    echo "Removing kubectl completions..."
    
    # Remove system-wide bash completion
    rm -f /etc/bash_completion.d/kubectl
    
    # Remove system-wide zsh completion
    rm -f /usr/share/zsh/site-functions/_kubectl
    rm -f /usr/local/share/zsh/site-functions/_kubectl
    
    # Remove from user configs
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home="/home/$SUDO_USER"
        
        # Clean bashrc
        if [ -f "$user_home/.bashrc" ]; then
            sed -i '/# kubectl completion/,+3d' "$user_home/.bashrc" 2>/dev/null || true
        fi
        
        # Clean zshrc
        if [ -f "$user_home/.zshrc" ]; then
            sed -i '/# kubectl completion/,+3d' "$user_home/.zshrc" 2>/dev/null || true
        fi
        
        # Clean fish completions
        rm -f "$user_home/.config/fish/completions/kubectl.fish"
        
        # Remove kubectl alias
        if [ -f "$user_home/.bashrc" ]; then
            sed -i '/alias k=kubectl/d' "$user_home/.bashrc" 2>/dev/null || true
            sed -i '/complete -o default -F __start_kubectl k/d' "$user_home/.bashrc" 2>/dev/null || true
        fi
        if [ -f "$user_home/.zshrc" ]; then
            sed -i '/alias k=kubectl/d' "$user_home/.zshrc" 2>/dev/null || true
            sed -i '/compdef k=kubectl/d' "$user_home/.zshrc" 2>/dev/null || true
        fi
        if [ -f "$user_home/.config/fish/config.fish" ]; then
            sed -i '/# kubectl alias/,+1d' "$user_home/.config/fish/config.fish" 2>/dev/null || true
        fi
    fi
    
    echo "kubectl completions removed"
}

# Remove kubeadm completion
cleanup_kubeadm_completion() {
    echo "Removing kubeadm completions..."
    
    # Remove system-wide bash completion
    rm -f /etc/bash_completion.d/kubeadm
    
    # Remove system-wide zsh completion
    rm -f /usr/share/zsh/site-functions/_kubeadm
    rm -f /usr/local/share/zsh/site-functions/_kubeadm
    
    # Remove from user configs
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home="/home/$SUDO_USER"
        
        # Clean bashrc
        if [ -f "$user_home/.bashrc" ]; then
            sed -i '/# kubeadm completion/,+1d' "$user_home/.bashrc" 2>/dev/null || true
        fi
        
        # Clean zshrc
        if [ -f "$user_home/.zshrc" ]; then
            sed -i '/# kubeadm completion/,+1d' "$user_home/.zshrc" 2>/dev/null || true
        fi
        
        # Clean fish completions
        rm -f "$user_home/.config/fish/completions/kubeadm.fish"
    fi
    
    echo "kubeadm completions removed"
}

# Remove crictl completion
cleanup_crictl_completion() {
    echo "Removing crictl completions..."
    
    # Remove system-wide bash completion
    rm -f /etc/bash_completion.d/crictl
    
    # Remove system-wide zsh completion
    rm -f /usr/share/zsh/site-functions/_crictl
    rm -f /usr/local/share/zsh/site-functions/_crictl
    
    # Remove from user configs
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home="/home/$SUDO_USER"
        
        # Clean bashrc
        if [ -f "$user_home/.bashrc" ]; then
            sed -i '/# crictl completion/,+1d' "$user_home/.bashrc" 2>/dev/null || true
        fi
        
        # Clean zshrc
        if [ -f "$user_home/.zshrc" ]; then
            sed -i '/# crictl completion/,+1d' "$user_home/.zshrc" 2>/dev/null || true
        fi
        
        # Clean fish completions
        rm -f "$user_home/.config/fish/completions/crictl.fish"
    fi
    
    echo "crictl completions removed"
}

# Remove helm completion
cleanup_helm_completion() {
    echo "Removing helm completions..."
    
    # Remove system-wide bash completion
    rm -f /etc/bash_completion.d/helm
    
    # Remove system-wide zsh completion
    rm -f /usr/share/zsh/site-functions/_helm
    rm -f /usr/local/share/zsh/site-functions/_helm
    
    # Remove from user configs
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home="/home/$SUDO_USER"
        
        # Clean bashrc
        if [ -f "$user_home/.bashrc" ]; then
            sed -i '/# helm completion/,+1d' "$user_home/.bashrc" 2>/dev/null || true
        fi
        
        # Clean zshrc
        if [ -f "$user_home/.zshrc" ]; then
            sed -i '/# helm completion/,+1d' "$user_home/.zshrc" 2>/dev/null || true
        fi
        
        # Clean fish completions
        rm -f "$user_home/.config/fish/completions/helm.fish"
    fi
    
    echo "helm completions removed"
}

# Main cleanup function for all Kubernetes completions
cleanup_kubernetes_completions() {
    echo "Cleaning up Kubernetes shell completions..."
    
    cleanup_kubectl_completion
    cleanup_kubeadm_completion
    cleanup_crictl_completion
    cleanup_helm_completion
    
    echo "Shell completion cleanup completed!"
}