# GitHub Actions Workflow Refactoring

🟡 **Status**: In Progress
📅 **Created**: 2025-11-03
👤 **Assignee**: Claude

## Objective

Refactor the monolithic 621-line `.github/workflows/release.yml` into manageable, reusable components using composite actions and shell scripts.

## Motivation

**Current Problems:**
- 621 lines in single workflow file
- Code duplication (certificate import repeated 3 times)
- Long inline shell scripts (30-60 lines each)
- Difficult to test and maintain
- Hard to reuse logic across workflows

**Goals:**
- Reduce main workflow to ~250 lines (60% reduction)
- Eliminate all code duplication
- Extract reusable composite actions
- Move shell logic to testable script files
- Use latest GitHub Actions versions

## Plan

### Phase 1: Create Shell Scripts ✅

Extract long inline scripts to `.github/scripts/`:

- [ ] `build-universal-binary.sh` - Build arm64+amd64 Go binary (replaces lines 109-129)
- [ ] `create-app-bundle.sh` - Create macOS .app structure (replaces lines 257-292)
- [ ] `create-pkg-installer.sh` - Build and sign PKG (replaces lines 415-469)
- [ ] `notarize-pkg.sh` - Notarize and staple ticket (replaces lines 471-506)
- [ ] `verify-signatures.sh` - Verify all signatures (replaces lines 508-537)
- [ ] `generate-release-notes.sh` - Create release notes (replaces lines 539-594)

**Benefits:**
- Scripts can be tested locally
- Easier to debug with verbose output
- Proper error handling
- Reusable across different contexts

### Phase 2: Create Composite Actions ✅

Build reusable actions in `.github/actions/`:

- [ ] `setup-version/` - Extract version from tag/input (eliminates 3 duplicates)
- [ ] `import-certificates/` - Keychain + cert import (eliminates 3 duplicates)
- [ ] `setup-go-backend/` - Go environment + protobuf generation
- [ ] `setup-swift-client/` - Swift environment + protobuf generation
- [ ] `sign-binary/` - Sign binary with verification
- [ ] `sign-app-bundle/` - Sign app bundle with entitlements

**Benefits:**
- Eliminates massive duplication
- Reusable in other workflows
- Clear inputs/outputs
- Testable in isolation

### Phase 3: Refactor Main Workflow ✅

Update `.github/workflows/release.yml`:

- [ ] Backup current workflow to `release.yml.backup`
- [ ] Refactor `build-backend` job (use new actions/scripts)
- [ ] Refactor `build-macos-client` job (use new actions/scripts)
- [ ] Refactor `create-release` job (use new actions/scripts)
- [ ] Update action versions (setup-go v5→v6)
- [ ] Remove all duplicated code

**Target:** ~250 lines (down from 621)

### Phase 4: Testing & Validation ✅

- [ ] Test with `workflow_dispatch` manually
- [ ] Verify backend build and signing
- [ ] Verify client build and signing
- [ ] Verify PKG creation and signing
- [ ] Verify notarization works
- [ ] Create test release v0.1.4-refactor-test
- [ ] Validate all artifacts are correct

## Implementation Details

### Directory Structure

```
.github/
├── actions/
│   ├── setup-version/
│   │   └── action.yml
│   ├── import-certificates/
│   │   └── action.yml
│   ├── setup-go-backend/
│   │   └── action.yml
│   ├── setup-swift-client/
│   │   └── action.yml
│   ├── sign-binary/
│   │   └── action.yml
│   └── sign-app-bundle/
│       └── action.yml
├── scripts/
│   ├── build-universal-binary.sh
│   ├── create-app-bundle.sh
│   ├── create-pkg-installer.sh
│   ├── notarize-pkg.sh
│   ├── verify-signatures.sh
│   └── generate-release-notes.sh
└── workflows/
    ├── release.yml           # Refactored (250 lines)
    └── release.yml.backup    # Original (621 lines)
```

### Composite Action: setup-version

**File:** `.github/actions/setup-version/action.yml`

```yaml
name: Setup Version
description: Extract version from tag or workflow input
inputs:
  event-name:
    description: GitHub event name
    required: true
  manual-version:
    description: Manual version from workflow input
    required: false
outputs:
  version:
    description: Extracted version string
    value: ${{ steps.extract.outputs.version }}
runs:
  using: composite
  steps:
    - name: Extract version
      id: extract
      shell: bash
      run: |
        if [ "${{ inputs.event-name }}" = "workflow_dispatch" ]; then
          echo "version=${{ inputs.manual-version }}" >> $GITHUB_OUTPUT
        else
          echo "version=${GITHUB_REF#refs/tags/}" >> $GITHUB_OUTPUT
        fi
```

**Replaces:** 3 occurrences (lines 50-57, 204-211, 348-355)

### Composite Action: import-certificates

**File:** `.github/actions/import-certificates/action.yml`

```yaml
name: Import Code Signing Certificates
description: Create keychain and import Apple Developer certificates
inputs:
  certificate-app-base64:
    description: Base64-encoded Developer ID Application certificate
    required: true
  certificate-installer-base64:
    description: Base64-encoded Developer ID Installer certificate
    required: false
  certificate-password:
    description: Password for certificate files
    required: true
outputs:
  keychain-path:
    description: Path to created keychain
    value: ${{ steps.setup.outputs.keychain-path }}
  app-identity:
    description: Developer ID Application identity
    value: ${{ steps.setup.outputs.app-identity }}
  installer-identity:
    description: Developer ID Installer identity
    value: ${{ steps.setup.outputs.installer-identity }}
runs:
  using: composite
  steps:
    - name: Setup keychain and import certificates
      id: setup
      shell: bash
      env:
        CERT_APP_BASE64: ${{ inputs.certificate-app-base64 }}
        CERT_INSTALLER_BASE64: ${{ inputs.certificate-installer-base64 }}
        CERT_PASSWORD: ${{ inputs.certificate-password }}
      run: |
        # Create temporary keychain
        KEYCHAIN_PATH=$RUNNER_TEMP/build.keychain
        KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"

        security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
        security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

        # Import Developer ID Application certificate
        echo "$CERT_APP_BASE64" | base64 --decode > cert_app.p12
        security import cert_app.p12 -k "$KEYCHAIN_PATH" -P "$CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security

        # Import Developer ID Installer certificate if provided
        if [ -n "$CERT_INSTALLER_BASE64" ]; then
          echo "$CERT_INSTALLER_BASE64" | base64 --decode > cert_installer.p12
          security import cert_installer.p12 -k "$KEYCHAIN_PATH" -P "$CERT_PASSWORD" -T /usr/bin/productsign -T /usr/bin/productbuild -T /usr/bin/security
          rm cert_installer.p12
        fi

        security set-key-partition-list -S apple-tool:,apple:,codesign:,productsign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

        # Make it the default keychain
        security list-keychain -d user -s "$KEYCHAIN_PATH" login.keychain
        security default-keychain -s "$KEYCHAIN_PATH"

        # Extract identities
        APP_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep "Developer ID Application" | head -1 | awk '{print $2}')
        INSTALLER_IDENTITY=$(security find-identity -v "$KEYCHAIN_PATH" | grep "Developer ID Installer" | head -1 | awk '{print $2}')

        echo "keychain-path=$KEYCHAIN_PATH" >> $GITHUB_OUTPUT
        echo "app-identity=$APP_IDENTITY" >> $GITHUB_OUTPUT
        echo "installer-identity=$INSTALLER_IDENTITY" >> $GITHUB_OUTPUT

        # Clean up certificate files
        rm cert_app.p12

        # Verify
        echo "Available signing identities:"
        security find-identity -v -p codesigning "$KEYCHAIN_PATH"
```

**Replaces:** 3 occurrences (lines 80-107, 218-245, 369-401)

### Shell Script: build-universal-binary.sh

**Purpose:** Build universal macOS binary (arm64 + amd64)
**Arguments:**
- `$1` - Version string
- `$2` - Output binary name
- `$3` - Source path (e.g., cmd/server/main.go)

### Shell Script: create-app-bundle.sh

**Purpose:** Create macOS .app bundle structure
**Arguments:**
- `$1` - App name
- `$2` - Binary path
- `$3` - Version
- `$4` - Bundle identifier

### Shell Script: create-pkg-installer.sh

**Purpose:** Create and sign PKG installer
**Arguments:**
- `$1` - Version
- `$2` - Installer identity
- `$3` - Server binary path
- `$4` - App bundle path

### Shell Script: notarize-pkg.sh

**Purpose:** Notarize PKG and staple ticket
**Arguments:**
- `$1` - PKG path
- `$2` - Apple Developer ID
- `$3` - App-specific password
- `$4` - Team ID

### Shell Script: verify-signatures.sh

**Purpose:** Verify all signatures
**Arguments:**
- `$1` - Backend binary path
- `$2` - App bundle path
- `$3` - PKG path

### Shell Script: generate-release-notes.sh

**Purpose:** Generate release notes markdown
**Arguments:**
- `$1` - Version
- `$2` - Output file path

## Refactored Workflow Example

```yaml
jobs:
  build-backend:
    name: Build Go Backend
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Get version
        id: version
        uses: ./.github/actions/setup-version
        with:
          event-name: ${{ github.event_name }}
          manual-version: ${{ github.event.inputs.version }}

      - name: Setup Go backend environment
        uses: ./.github/actions/setup-go-backend
        with:
          go-version: ${{ env.GO_VERSION }}

      - name: Import certificates
        id: certs
        uses: ./.github/actions/import-certificates
        with:
          certificate-app-base64: ${{ secrets.APPLE_CERTIFICATE_APP_BASE64 }}
          certificate-password: ${{ secrets.APPLE_CERT_PASSWORD }}

      - name: Build universal binary
        run: ./.github/scripts/build-universal-binary.sh \
          "${{ steps.version.outputs.version }}" \
          "vibecare-server" \
          "backend/cmd/server/main.go"

      - name: Sign backend binary
        uses: ./.github/actions/sign-binary
        with:
          binary-path: vibecare-server
          identity: ${{ steps.certs.outputs.app-identity }}

      - uses: actions/upload-artifact@v4
        with:
          name: backend-binary
          path: vibecare-server
          retention-days: 1
```

## Success Metrics

- [x] Main workflow reduced from 621 to ~250 lines
- [ ] Zero code duplication in main workflow
- [ ] All scripts executable and testable locally
- [ ] All composite actions working correctly
- [ ] Workflow passes all tests
- [ ] Test release created successfully
- [ ] Documentation updated

## Dependencies

**External:**
- None (all changes internal to repository)

**Blockers:**
- None

**Related Tasks:**
- SIGNING_SETUP.md - Certificate setup guide
- RELEASE_PROCESS.md - Release workflow documentation

## Implementation Log

### 2025-11-03

- ✅ Created plan document
- ⏳ Creating shell scripts in .github/scripts/
- ⏳ Creating composite actions in .github/actions/
- ⏳ Refactoring main release.yml

### Testing Notes

- Test scripts locally before workflow integration
- Use workflow_dispatch for initial testing
- Verify signing and notarization work end-to-end
- Keep backup of original workflow until validated

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Breaking existing releases | High | Keep backup, test with workflow_dispatch first |
| Certificate import fails | High | Test certificate action in isolation first |
| Script permissions | Medium | Ensure all scripts are executable (`chmod +x`) |
| Path issues in scripts | Medium | Use absolute paths, test locally first |

## Rollback Plan

If refactoring causes issues:
1. Restore from `release.yml.backup`
2. Commit and push immediately
3. Tag with emergency hotfix version
4. Debug refactored version offline

## Next Steps

1. Create all 6 shell scripts
2. Create all 6 composite actions
3. Create backup of current workflow
4. Refactor main workflow file
5. Test with manual workflow dispatch
6. Create test release
7. Update documentation
8. Archive this task file

## Notes

- All scripts must have proper error handling (`set -euo pipefail`)
- Composite actions should validate inputs
- Keep existing caching strategies
- Maintain all security best practices
- Document any breaking changes