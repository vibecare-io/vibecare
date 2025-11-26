# Remove Email Requirement from Profile Creation

**Status**: 🔵 In Progress
**Started**: 2025-11-05
**Goal**: Make email field optional - users can create profiles with just a name

## Context
User wants to simplify profile creation by removing the mandatory email field. Email should become optional but still validated when provided.

## Plan

### Backend Changes
- [ ] Modify validation layer to accept empty emails
- [ ] Update profile service to handle optional email
- [ ] Update storage layer for optional email
- [ ] Handle duplicate email check for non-empty emails only

### Frontend Changes
- [ ] Make Swift Profile model email optional
- [ ] Update ProfileService for optional email
- [ ] Update AppState createProfile signature
- [ ] Modify CreateProfileView UI validation
- [ ] Update SettingsDetail to handle optional email display

### Code Generation
- [ ] Regenerate protobuf stubs

### Testing
- [ ] Test profile creation with name only
- [ ] Test profile creation with name and email
- [ ] Verify email validation when provided
- [ ] Check duplicate email detection

## Implementation Log

### Phase 1: Backend Foundation (Completed)
- Modified `backend/internal/validation/validator.go:67-84` - Made ValidateEmail accept empty strings
- Updated `backend/internal/api/profile_service.go:32-41` - Added conditional email duplicate check
- Updated `backend/internal/storage/profile.go:44-64,239-261` - Handle NULL emails in database
- Added COALESCE in SQL queries to convert NULL to empty string

### Phase 2: Swift Client (Completed)
- Regenerated protobuf stubs with `just proto-gen`
- Modified `clients/macos-swift/VibeCare/vibecare/Models/Profile.swift:6,15` - Made email optional (String?)
- Updated `clients/macos-swift/VibeCare/vibecare/Services/ProfileService.swift:57,64,123,275,287` - Handle optional email
- Updated `clients/macos-swift/VibeCare/vibecare/ViewModels/AppState.swift:100` - Accept optional email parameter
- Modified `clients/macos-swift/VibeCare/vibecare/Views/PlaceholderViews.swift:96,110,116` - Made email field optional
- Updated `clients/macos-swift/VibeCare/vibecare/Views/Settings/SettingsDetail.swift:153-157,203-207` - Display email conditionally

### Phase 3: Error Handling Improvements (Completed)
- Added loading state and error display to CreateProfileView
- Updated AppState.createProfile() to return Result<Profile, Error>
- Integrated StatusBarManager for success/error messages
- Show actual gRPC error messages to users instead of generic errors
- Form stays open on error so users can retry

## Dependencies
- None identified

## Deferred Items
- None yet

## Notes for Handoff
- Email field in database already allows NULL (no NOT NULL constraint)
- Proto3 files don't have explicit required keyword, so protobuf already supports optional email
