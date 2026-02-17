#!/bin/bash

# Shell completion setup for Kubernetes tools

# Detect user's shell
detect_user_shell() {
    local user_shell=""

    # Check SHELL environment variable first
    if [ -n "${SHELL:-}" ]; then
        user_shell=$(basename "$SHELL")
    fi

    # Check /etc/passwd for the user's default shell
    if [ -z "$user_shell" ] && [ -n "${SUDO_USER:-}" ]; then
        user_shell=$(getent passwd "$SUDO_USER" | cut -d: -f7 | xargs basename)
    elif [ -z "$user_shell" ]; then
        user_shell=$(getent passwd "${USER:-root}" | cut -d: -f7 | xargs basename)
    fi

    # Default to bash if detection fails
    if [ -z "$user_shell" ]; then
        user_shell="bash"
    fi

    echo "$user_shell"
}

# Generic: setup tool completion for a given shell
# Usage: _setup_tool_completion <tool> <shell> [alias]
_setup_tool_completion() {
    local tool="$1"
    local shell_type="$2"
    local alias_name="${3:-}"

    if ! command -v "$tool" &> /dev/null; then
        echo "$tool not found, skipping completion setup"
        return 1
    fi

    echo "Setting up $tool completion for $shell_type..."

    case "$shell_type" in
        bash)
            # System-wide bash completion
            if [ -d /etc/bash_completion.d ]; then
                "$tool" completion bash > "/etc/bash_completion.d/$tool" 2>/dev/null || {
                    echo "$tool does not support bash completion"
                    return 1
                }
                echo "$tool bash completion installed to /etc/bash_completion.d/"
            fi

            # User-specific bash completion
            if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.bashrc" ]; then
                    if ! grep -q "$tool completion bash" "$user_home/.bashrc"; then
                        {
                            echo ""
                            echo "# $tool completion"
                            echo "source <($tool completion bash)"
                            if [ -n "$alias_name" ]; then
                                echo "alias ${alias_name}=${tool}"
                                echo "complete -o default -F __start_${tool} ${alias_name}"
                            fi
                        } >> "$user_home/.bashrc"
                        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.bashrc"
                        echo "$tool bash completion added to $user_home/.bashrc"
                    fi
                fi
            fi
            ;;

        zsh)
            # System-wide zsh completion
            local zsh_dir=""
            [ -d /usr/local/share/zsh/site-functions ] && zsh_dir="/usr/local/share/zsh/site-functions"
            [ -d /usr/share/zsh/site-functions ] && zsh_dir="/usr/share/zsh/site-functions"

            if [ -n "$zsh_dir" ]; then
                "$tool" completion zsh > "${zsh_dir}/_${tool}" 2>/dev/null || {
                    echo "$tool does not support zsh completion"
                    return 1
                }
                echo "$tool zsh completion installed to ${zsh_dir}/"
            fi

            # User-specific zsh completion
            if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                if [ -f "$user_home/.zshrc" ]; then
                    if ! grep -q "$tool completion zsh" "$user_home/.zshrc"; then
                        {
                            echo ""
                            echo "# $tool completion"
                            echo "source <($tool completion zsh)"
                            if [ -n "$alias_name" ]; then
                                echo "alias ${alias_name}=${tool}"
                                echo "compdef ${alias_name}=${tool}"
                            fi
                        } >> "$user_home/.zshrc"
                        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.zshrc"
                        echo "$tool zsh completion added to $user_home/.zshrc"
                    fi
                fi
            fi
            ;;

        fish)
            if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
                local user_home="/home/$SUDO_USER"
                local fish_dir="$user_home/.config/fish/completions"

                if [ ! -d "$fish_dir" ]; then
                    mkdir -p "$fish_dir"
                    chown -R "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.config"
                fi

                "$tool" completion fish > "$fish_dir/${tool}.fish" 2>/dev/null || {
                    echo "$tool does not support fish completion"
                    return 1
                }
                chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$fish_dir/${tool}.fish"
                echo "$tool fish completion installed to $fish_dir/"

                # Add alias if config.fish exists
                if [ -n "$alias_name" ] && [ -f "$user_home/.config/fish/config.fish" ]; then
                    if ! grep -q "alias ${alias_name} ${tool}" "$user_home/.config/fish/config.fish"; then
                        {
                            echo ""
                            echo "# $tool alias"
                            echo "alias ${alias_name} ${tool}"
                        } >> "$user_home/.config/fish/config.fish"
                        chown "${SUDO_USER}:$(id -gn "$SUDO_USER")" "$user_home/.config/fish/config.fish"
                    fi
                fi
            fi
            ;;

        *)
            echo "Unsupported shell: $shell_type"
            return 1
            ;;
    esac

    return 0
}

# Generic: cleanup tool completion
# Usage: _cleanup_tool_completion <tool> [alias]
_cleanup_tool_completion() {
    local tool="$1"
    local alias_name="${2:-}"

    echo "Removing $tool completions..."

    # Remove system-wide completions
    rm -f "/etc/bash_completion.d/$tool"
    rm -f "/usr/share/zsh/site-functions/_${tool}"
    rm -f "/usr/local/share/zsh/site-functions/_${tool}"

    # Remove from user configs
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home="/home/$SUDO_USER"

        # Clean bashrc
        if [ -f "$user_home/.bashrc" ]; then
            sed -i "/# ${tool} completion/,+1d" "$user_home/.bashrc" 2>/dev/null || true
            if [ -n "$alias_name" ]; then
                sed -i "/alias ${alias_name}=${tool}/d" "$user_home/.bashrc" 2>/dev/null || true
                sed -i "/complete -o default -F __start_${tool} ${alias_name}/d" "$user_home/.bashrc" 2>/dev/null || true
            fi
        fi

        # Clean zshrc
        if [ -f "$user_home/.zshrc" ]; then
            sed -i "/# ${tool} completion/,+1d" "$user_home/.zshrc" 2>/dev/null || true
            if [ -n "$alias_name" ]; then
                sed -i "/alias ${alias_name}=${tool}/d" "$user_home/.zshrc" 2>/dev/null || true
                sed -i "/compdef ${alias_name}=${tool}/d" "$user_home/.zshrc" 2>/dev/null || true
            fi
        fi

        # Clean fish completions
        rm -f "$user_home/.config/fish/completions/${tool}.fish"
        if [ -n "$alias_name" ] && [ -f "$user_home/.config/fish/config.fish" ]; then
            sed -i "/# ${tool} alias/,+1d" "$user_home/.config/fish/config.fish" 2>/dev/null || true
        fi
    fi

    echo "$tool completions removed"
}

# Public wrappers
setup_kubectl_completion()  { _setup_tool_completion kubectl  "$1" k; }
setup_kubeadm_completion()  { _setup_tool_completion kubeadm  "$1"; }
setup_crictl_completion()   { _setup_tool_completion crictl   "$1"; }
setup_helm_completion()     { _setup_tool_completion helm     "$1"; }

cleanup_kubectl_completion()  { _cleanup_tool_completion kubectl  k; }
cleanup_kubeadm_completion()  { _cleanup_tool_completion kubeadm; }
cleanup_crictl_completion()   { _cleanup_tool_completion crictl; }
cleanup_helm_completion()     { _cleanup_tool_completion helm; }

# Main function to setup all completions
setup_kubernetes_completions() {
    echo "Setting up Kubernetes shell completions..."

    # Detect shell(s) to configure
    local shells_to_configure=()

    if [ "$COMPLETION_SHELLS" = "auto" ]; then
        local detected_shell
        detected_shell=$(detect_user_shell)
        shells_to_configure+=("$detected_shell")
        echo "Auto-detected shell: $detected_shell"
    else
        IFS=',' read -ra shells_to_configure <<< "$COMPLETION_SHELLS"
    fi

    for shell_type in "${shells_to_configure[@]}"; do
        shell_type=$(echo "$shell_type" | tr -d ' ')
        echo "Configuring completions for $shell_type..."
        setup_kubectl_completion "$shell_type"
        setup_kubeadm_completion "$shell_type"
        setup_crictl_completion "$shell_type" || true
        setup_helm_completion "$shell_type" || true
    done

    echo "Shell completion setup completed!"
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

# Main cleanup function for all Kubernetes completions
cleanup_kubernetes_completions() {
    echo "Cleaning up Kubernetes shell completions..."
    cleanup_kubectl_completion
    cleanup_kubeadm_completion
    cleanup_crictl_completion
    cleanup_helm_completion
    echo "Shell completion cleanup completed!"
}
