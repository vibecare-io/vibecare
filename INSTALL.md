# VibeCare Installation Guide

Complete guide for installing and running VibeCare on macOS.

## System Requirements

- **macOS:** 15.0 (Sequoia) or later
- **Architecture:** Apple Silicon (M1/M2/M3/M4) or Intel
- **Disk Space:** ~100 MB

## Installation Options

### Option 1: PKG Installer (Recommended)

The easiest way to install VibeCare with automatic setup.

1. **Download the PKG**
   ```bash
   # Download from GitHub Releases
   curl -LO https://github.com/vibecare-io/vibecare/releases/latest/download/VibeCare-v1.0.0.pkg
   ```

2. **Verify checksum** (optional but recommended)
   ```bash
   curl -LO https://github.com/vibecare-io/vibecare/releases/latest/download/VibeCare-v1.0.0.pkg.sha256
   shasum -a 256 -c VibeCare-v1.0.0.pkg.sha256
   ```

3. **Install**
   ```bash
   # Double-click the PKG file, or install via command line:
   sudo installer -pkg VibeCare-v1.0.0.pkg -target /
   ```

4. **Verify installation**
   ```bash
   # Check backend is running
   curl http://localhost:8080/status

   # View logs
   tail -f ~/Library/Logs/VibeCare/server.log
   ```

5. **Launch the macOS client**
   - Open VibeCare from Applications folder
   - Or use Spotlight: `Cmd+Space`, type "VibeCare"

**What gets installed:**
- `/usr/local/bin/vibecare-server` - Backend server binary
- `/Applications/VibeCare.app` - macOS client application
- `~/Library/LaunchAgents/io.vibecare.server.plist` - Auto-start configuration
- `~/.vibecare/vibecare.db` - SQLite database
- `~/Library/Logs/VibeCare/` - Log files

---

### Option 2: Homebrew (For developers)

Install via Homebrew for easier updates and management.

1. **Add the tap** (if using a custom tap)
   ```bash
   brew tap vibecare-io/vibecare
   ```

2. **Install VibeCare**
   ```bash
   brew install vibecare
   ```

3. **Start the backend service**
   ```bash
   brew services start vibecare
   ```

4. **Run the macOS client**
   ```bash
   vibecare-client
   ```

**Homebrew locations:**
- Backend: `/opt/homebrew/bin/vibecare-server` (Apple Silicon) or `/usr/local/bin/vibecare-server` (Intel)
- Client: `/opt/homebrew/bin/vibecare-client`
- Data: `/opt/homebrew/var/vibecare/`
- Logs: `/opt/homebrew/var/log/vibecare/`

---

### Option 3: Build from Source

For developers who want to build from source.

#### Prerequisites
```bash
# Install dependencies
brew install go swift protobuf just

# Or check what you need
just check
```

#### Build and install
```bash
# Clone repository
git clone https://github.com/vibecare-io/vibecare.git
cd vibecare

# Setup development environment
just setup

# Build backend
just build

# Build Swift client
just swift-build

# Run backend
just run

# In another terminal, run client
just swift-run
```

#### Create distribution package
```bash
# Build release artifacts
./scripts/build-release.sh

# Create PKG installer
./scripts/create-pkg.sh

# Artifacts will be in build/ directory
```

---

## Post-Installation

### Accessing VibeCare

**Web Dashboard:**
```bash
open http://localhost:8080/status
```

**macOS Client:**
- Launch from Applications folder
- Client connects to `localhost:50051` (gRPC)

### Managing the Backend Service

**Check status:**
```bash
launchctl list | grep vibecare
```

**View logs:**
```bash
# Real-time logs
tail -f ~/Library/Logs/VibeCare/server.log
tail -f ~/Library/Logs/VibeCare/server-error.log

# Or if installed via Homebrew
tail -f /opt/homebrew/var/log/vibecare/server.log
```

**Stop backend:**
```bash
launchctl unload ~/Library/LaunchAgents/io.vibecare.server.plist

# Or with Homebrew
brew services stop vibecare
```

**Start backend:**
```bash
launchctl load ~/Library/LaunchAgents/io.vibecare.server.plist

# Or with Homebrew
brew services start vibecare
```

**Restart backend:**
```bash
launchctl unload ~/Library/LaunchAgents/io.vibecare.server.plist
launchctl load ~/Library/LaunchAgents/io.vibecare.server.plist

# Or with Homebrew
brew services restart vibecare
```

---

## Configuration

### Backend Configuration

The backend accepts these flags (modify LaunchAgent plist if needed):

```bash
vibecare-server \
  --port 50051 \           # gRPC port
  --web-port 8080 \        # Web dashboard port
  --db ~/.vibecare/vibecare.db \  # Database path
  --enable-tracing         # Enable OpenTelemetry tracing
```

**Edit LaunchAgent:**
```bash
nano ~/Library/LaunchAgents/io.vibecare.server.plist

# After editing, reload:
launchctl unload ~/Library/LaunchAgents/io.vibecare.server.plist
launchctl load ~/Library/LaunchAgents/io.vibecare.server.plist
```

### Database Location

**PKG Installation:**
- `~/.vibecare/vibecare.db`

**Homebrew Installation:**
- `/opt/homebrew/var/vibecare/vibecare.db`

**Backup database:**
```bash
cp ~/.vibecare/vibecare.db ~/.vibecare/vibecare.db.backup
```

---

## Troubleshooting

### Backend won't start

1. **Check logs:**
   ```bash
   tail -n 50 ~/Library/Logs/VibeCare/server-error.log
   ```

2. **Port conflict:**
   ```bash
   # Check if ports are in use
   lsof -i :50051
   lsof -i :8080
   ```

3. **Manually start backend:**
   ```bash
   /usr/local/bin/vibecare-server --db ~/.vibecare/vibecare.db
   ```

### Client can't connect

1. **Verify backend is running:**
   ```bash
   curl http://localhost:8080/status
   ```

2. **Check gRPC endpoint:**
   ```bash
   # Install grpcurl if needed
   brew install grpcurl

   # Test gRPC
   grpcurl -plaintext localhost:50051 list
   ```

### Database issues

1. **Reset database:**
   ```bash
   # Backup first!
   cp ~/.vibecare/vibecare.db ~/.vibecare/vibecare.db.backup

   # Remove and restart (migrations will recreate)
   rm ~/.vibecare/vibecare.db
   launchctl unload ~/Library/LaunchAgents/io.vibecare.server.plist
   launchctl load ~/Library/LaunchAgents/io.vibecare.server.plist
   ```

2. **Inspect database:**
   ```bash
   # Install litecli if needed
   brew install litecli

   # Open database
   litecli ~/.vibecare/vibecare.db
   ```

---

## Uninstallation

### PKG Installation

```bash
# Stop and remove LaunchAgent
launchctl unload ~/Library/LaunchAgents/io.vibecare.server.plist
rm ~/Library/LaunchAgents/io.vibecare.server.plist

# Remove binaries
sudo rm /usr/local/bin/vibecare-server
sudo rm -rf /Applications/VibeCare.app

# Remove data (optional - deletes your schedules!)
rm -rf ~/.vibecare
rm -rf ~/Library/Logs/VibeCare
```

### Homebrew Installation

```bash
# Stop service
brew services stop vibecare

# Uninstall
brew uninstall vibecare

# Remove data (optional)
rm -rf ~/Library/LaunchAgents/io.vibecare.server.plist
```

---

## Updating

### PKG Installation

1. Download new PKG from releases
2. Install (will replace old version)
3. Backend will restart automatically

### Homebrew Installation

```bash
brew update
brew upgrade vibecare
brew services restart vibecare
```

---

## Support

- **Issues:** https://github.com/vibecare-io/vibecare/issues
- **Discussions:** https://github.com/vibecare-io/vibecare/discussions
- **Documentation:** https://github.com/vibecare-io/vibecare/wiki

---

## Next Steps

After installation:

1. **Open web dashboard:** http://localhost:8080/status
2. **Create your first profile** using the macOS client
3. **Set up routines** and schedules
4. **Explore the API** using grpcurl or the web interface

Enjoy VibeCare! 🎉
