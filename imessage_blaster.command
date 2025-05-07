#!/bin/bash

# Set text colors for better readability - using tput which is more compatible
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)
BOLD=$(tput bold)
NC=$(tput sgr0) # No Color/Reset

# Make sure colors work in Terminal.app
export CLICOLOR=1
export FORCE_COLOR=1

echo "${GREEN}=== Checking required dependencies ===${NC}"

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "${RED}Error: git is not installed${NC}"
    echo "${YELLOW}To install git, you need to install Xcode Command Line Tools.${NC}"
    echo "Would you like to install the Xcode Command Line Tools now? (y/n)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo "Installing Xcode Command Line Tools..."
        xcode-select --install
        echo "${YELLOW}After installation completes, please run this script again.${NC}"
    else
        echo "${YELLOW}Please install git and run this script again.${NC}"
        echo "You can install it by running 'xcode-select --install' in Terminal."
    fi
    exit 1
fi
echo "${GREEN}✓ git is installed${NC}"

# Check if ruby is installed
if ! command -v ruby &> /dev/null; then
    echo "${RED}Error: ruby is not installed${NC}"
    echo "${YELLOW}We need to install Ruby using Homebrew.${NC}"
    
    # Check if Homebrew is installed
    if ! command -v brew &> /dev/null; then
        echo "${YELLOW}Homebrew is not installed. We need to install it first.${NC}"
        echo "Would you like to install Homebrew now? (y/n)"
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            echo "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            
            # Add Homebrew to PATH for this session
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
            
            echo "${GREEN}Homebrew installed successfully.${NC}"
        else
            echo "${YELLOW}Please install Homebrew and then Ruby, then run this script again.${NC}"
            echo "You can install Homebrew by running this command in Terminal:"
            echo "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 1
        fi
    fi
    
    # Now install Ruby with Homebrew
    echo "${YELLOW}Installing Ruby using Homebrew...${NC}"
    echo "This may take a few minutes..."
    brew install ruby
    
    if ! command -v ruby &> /dev/null; then
        echo "${RED}Ruby installation failed.${NC}"
        echo "${YELLOW}Please try installing Ruby manually:${NC}"
        echo "1. Open Terminal"
        echo "2. Run: brew install ruby"
        echo "3. Run this script again once Ruby is installed"
        exit 1
    fi
    
    echo "${GREEN}Ruby installed successfully.${NC}"
fi
echo "${GREEN}✓ ruby is installed${NC}"

# Check if iMessage database exists and is accessible
IMESSAGE_DB="$HOME/Library/Messages/chat.db"
if [ ! -f "$IMESSAGE_DB" ]; then
    echo "${RED}Error: iMessage database not found at expected location ($IMESSAGE_DB)${NC}"
    echo "${YELLOW}This tool requires access to your iMessage database.${NC}"
    exit 1
fi

if [ ! -r "$IMESSAGE_DB" ]; then
    echo "${RED}Error: Cannot read the iMessage database.${NC}"
    echo "${YELLOW}You need to grant 'Full Disk Access' to Terminal:${NC}"
    echo "1. Open System Preferences/Settings"
    echo "2. Go to Privacy & Security > Full Disk Access"
    echo "3. Click the lock icon to make changes"
    echo "4. Add Terminal to the list of allowed apps"
    
    # Ask if they want to open Security preferences now
    echo "Would you like to open Privacy & Security settings now? (y/n)"
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    fi
    exit 1
fi
echo "${GREEN}✓ iMessage database is accessible${NC}"

echo "${GREEN}All dependencies are satisfied!${NC}"

# Change to the Documents directory
cd ~/Documents

# Check if the repository already exists
if [ -d "imessage-blaster" ]; then
    echo "${GREEN}Repository already exists. Updating...${NC}"
    cd imessage-blaster
    git pull
else
    echo "${GREEN}Cloning repository...${NC}"
    git clone https://github.com/christiangenco/imessage-blaster.git
    cd imessage-blaster
fi

# Run the Ruby script
echo "${GREEN}Running main.rb...${NC}"
ruby main.rb