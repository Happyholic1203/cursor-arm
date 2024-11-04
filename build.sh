#!/usr/bin/env bash
set -euo pipefail

# Configuration
# CURSOR_VERSION="0.42.2"
CURSOR_VERSION="latest"
# VSCODE_VERSION="1.93.1"
VSCODE_VERSION="latest"
SUPPORTED_SYSTEMS=("aarch64-linux" "armv7l-linux" "x86_64-linux")

# Helper functions
download_file() {
    local url="$1"
    local output="$2"
    if [ -f "$output" ]; then
        echo "File already exists: $output"
    else
        if command -v curl &> /dev/null; then
            curl -L "$url" -o "$output"
        else
            wget -O "$output" "$url"
        fi
    fi
}

extract_archive() {
    local archive="$1"
    local target="$2"
    
    case "$archive" in
        *.tar.gz|*.tgz)
            tar xzf "$archive" -C "$target"
            ;;
        *.zip)
            unzip "$archive" -d "$target"
            ;;
    esac
}

copy_cursor_files() {
    local cursor_root="$1"
    local target_root="$2"

    # Copy Cursor-specific resources
    cp -R "${cursor_root}/resources/app/out" "${target_root}/resources/app/"
    cp -R "${cursor_root}/resources/app/"*.json "${target_root}/resources/app/"
    cp -R "${cursor_root}/resources/app/extensions/cursor-"* "${target_root}/resources/app/extensions/"
    rm -rf "${target_root}/resources/app/node_modules"{,.asar}
    cp -R "${cursor_root}/resources/app/node_modules.asar" "${target_root}/resources/app/"
    rm -rf "${target_root}/resources/app/resources"
    cp -R "${cursor_root}/resources/app/resources" "${target_root}/resources/app/"
}

build_cursor() {
    local system="$1"
    local build_dir="build"
    local download_dir="downloads"
    
    mkdir -p "$build_dir" "$download_dir"

    # Download Cursor AppImage
    if [ "$CURSOR_VERSION" = "latest" ]; then
        local cursor_url="https://downloader.cursor.sh/linux/appImage/x64"
    else
        local cursor_url="https://dl.todesktop.com/230313mzl4w4u92/versions/${CURSOR_VERSION}/linux/appImage/x64"
    fi
    local cursor_appimage="${download_dir}/cursor.AppImage"
    echo "Downloading Cursor..."
    download_file "$cursor_url" "$cursor_appimage"

    # Extract AppImage
    local cursor_extract_dir="${build_dir}/cursor-extract"
    rm -rf "$cursor_extract_dir"
    mkdir -p "$cursor_extract_dir"
    7z -o"$cursor_extract_dir" x "$cursor_appimage"

    # Download and extract VS Code for the target system
    case "$system" in
        "aarch64-linux")
            if [ "$VSCODE_VERSION" = "latest" ]; then
                local vscode_url="https://code.visualstudio.com/sha/download?build=stable&os=linux-arm64"
            else
                local vscode_url="https://update.code.visualstudio.com/${VSCODE_VERSION}/linux-arm64/stable"
            fi
            local target_name="linux-arm64"
            ;;
        "armv7l-linux")
            if [ "$VSCODE_VERSION" = "latest" ]; then
                local vscode_url="https://code.visualstudio.com/sha/download?build=stable&os=linux-arm32"
            else
                local vscode_url="https://update.code.visualstudio.com/${VSCODE_VERSION}/linux-armhf/stable"
            fi
            local target_name="linux-arm32"
            ;;
        *)
            echo "Unsupported system: $system"
            exit 1
            ;;
    esac

    local vscode_archive="${download_dir}/vscode-${target_name}.tar.gz"
    local vscode_extract_dir="${build_dir}/vscode-${target_name}"
    
    echo "Downloading VS Code for ${target_name}..."
    download_file "$vscode_url" "$vscode_archive"
    
    mkdir -p "$vscode_extract_dir"
    echo "Extracting VS Code..."
    extract_archive "$vscode_archive" "$vscode_extract_dir"

    # Build Cursor package
    local cursor_build_dir="${build_dir}/cursor-${target_name}"
    mkdir -p "$cursor_build_dir"
    
    echo "Building Cursor package..."
    cp -R "$vscode_extract_dir"/*/* "$cursor_build_dir/"
    copy_cursor_files "${cursor_extract_dir}" "$cursor_build_dir"

    # Copy additional resources
    cp "${cursor_extract_dir}/cursor.png" "$cursor_build_dir/"
    cp "${cursor_extract_dir}/cursor.desktop" "$cursor_build_dir/"
    cp -R "${cursor_extract_dir}/resources/todesktop"* "$cursor_build_dir/resources/"

    # Platform-specific adjustments for Linux
    cp -R "${cursor_extract_dir}/usr" "$cursor_build_dir/"
    cp "${cursor_extract_dir}/AppRun" "$cursor_build_dir/"
    chmod +x "$cursor_build_dir/AppRun"
    cp "${cursor_extract_dir}/.DirIcon" "$cursor_build_dir/"

    # Rename binaries
    if [ -f "$cursor_build_dir/code" ]; then
        mv "$cursor_build_dir/code" "$cursor_build_dir/cursor"
    fi
    if [ -f "$cursor_build_dir/bin/code" ]; then
        mv "$cursor_build_dir/bin/code" "$cursor_build_dir/bin/cursor"
    fi
    if [ -f "$cursor_build_dir/bin/codium" ]; then
        mv "$cursor_build_dir/bin/codium" "$cursor_build_dir/bin/cursor"
    fi

    # Create distribution archives
    echo "Creating distribution archives..."
    local dist_dir="dist"
    mkdir -p "$dist_dir"
    
    # Create tar.gz
    tar -czf "${dist_dir}/cursor_${CURSOR_VERSION}_${target_name}.tar.gz" -C "$cursor_build_dir" .
    
    # Create AppImage
    if ! command -v appimagetool &> /dev/null; then
        echo "appimagetool not found, downloading..."
        local appimage_tool_url
        case "$system" in
            aarch64-linux)
                appimage_tool_arch="aarch64";;
            x86_64-linux)
                appimage_tool_arch="x86_64";;
            i686-linux)
                appimage_tool_arch="i686";;
            armv7l-linux)
                appimage_tool_arch="armhf";;
        esac
        wget "https://github.com/AppImage/AppImageKit/releases/download/13/appimagetool-${appimage_tool_arch}.AppImage" -O "${download_dir}/appimagetool"
        chmod +x "${download_dir}/appimagetool"
        export PATH="${download_dir}:$PATH"
    fi

    local arch="arm_aarch64"
    [ "$system" = "armv7l-linux" ] && arch="arm"
    
    ARCH="$arch" appimagetool "$cursor_build_dir" "${dist_dir}/cursor_${CURSOR_VERSION}_${target_name}.AppImage"
    
    # Set correct interpreter
    local interpreter="/lib/ld-linux-aarch64.so.1"
    [ "$system" = "armv7l-linux" ] && interpreter="/lib/ld-linux.so.3"

    patchelf --set-interpreter "$interpreter" "${dist_dir}/cursor_${CURSOR_VERSION}_${target_name}.AppImage"
}

# Main script
main() {
    local system="${1:-}"
    
    if [ -z "$system" ]; then
        echo "Usage: $0 <system>"
        echo "Supported systems: ${SUPPORTED_SYSTEMS[*]}"
        exit 1
    fi
    
    if [[ ! " ${SUPPORTED_SYSTEMS[*]} " =~ " ${system} " ]]; then
        echo "Unsupported system: $system"
        echo "Supported systems: ${SUPPORTED_SYSTEMS[*]}"
        exit 1
    fi

    if ! command -v patchelf &> /dev/null; then
        echo "patchelf not found, please install it before running this script."
        exit 1
    fi

    if ! command -v 7z &> /dev/null; then
        echo "7z not found, please install it before running this script."
        exit 1
    fi
    
    build_cursor "$system"
    echo "Build complete! Check the 'dist' directory for the output files."
}

main "$@"
